
CREATE OR REPLACE FUNCTION public.tc_evaluate_logistics_promise(p_demand_id uuid, p_routing_attempt_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_attempt uuid;
  v_result text;
  v_structural boolean;
  v_current boolean;
  v_no_trip boolean;
  v_hops integer;
  v_committed integer;
  v_state text;
  v_reason text;
  v_eval uuid;
  v_private_final boolean := false;
  v_last_mile_committed boolean := false;
begin
  if p_routing_attempt_id is null then
    select a.id,a.result_code,a.structural_reachable,a.current_executable,a.no_trip_now,a.hop_count
      into v_attempt,v_result,v_structural,v_current,v_no_trip,v_hops
    from public.logistics_routing_attempts a
    where a.demand_id=p_demand_id
    order by a.attempt_seq desc
    limit 1;
  else
    select a.id,a.result_code,a.structural_reachable,a.current_executable,a.no_trip_now,a.hop_count
      into v_attempt,v_result,v_structural,v_current,v_no_trip,v_hops
    from public.logistics_routing_attempts a
    where a.id=p_routing_attempt_id
      and a.demand_id=p_demand_id;
  end if;

  if v_attempt is null then
    raise exception using errcode='P0001', message='TC_ROUTING_ATTEMPT_NOT_FOUND';
  end if;

  select count(*) into v_committed
  from public.logistics_routing_hops h
  join public.logistics_routing_commitments c
    on c.routing_hop_id=h.id
   and c.routing_attempt_id=h.routing_attempt_id
  join public.logistics_capacity_reservations r
    on r.id=c.capacity_reservation_id
  where h.routing_attempt_id=v_attempt
    and r.state in ('CONFIRMED','CONSUMED');

  select exists(
    select 1
    from public.logistics_private_destination_adapters a
    where a.demand_id=p_demand_id
  ) into v_private_final;

  if v_private_final then
    select exists(
      select 1
      from public.logistics_last_mile_task_demands td
      join public.logistics_last_mile_assignments a
        on a.task_id=td.task_id
       and a.state='ACTIVE'
      join public.logistics_rsg_capacity_reservations r
        on r.id=a.capacity_reservation_id
       and r.state in ('CONFIRMED','CONSUMED')
      where td.demand_id=p_demand_id
    ) into v_last_mile_committed;
  end if;

  if v_result='STRUCTURAL_UNREACHABLE' then
    v_state := 'UNREACHABLE';
    v_reason := 'STRUCTURAL_UNREACHABLE';
  elsif v_result='ADAPTER_REQUIRED' then
    v_state := 'ADAPTER_REQUIRED';
    v_reason := 'ENDPOINT_ADAPTER_REQUIRED';
  elsif v_result='LOOP_DETECTED' then
    v_state := 'ROUTING_EXCEPTION';
    v_reason := 'LOOP_DETECTED';
  elsif v_result='ALREADY_AT_DESTINATION' then
    v_structural := true;
    v_current := true;
    v_no_trip := false;
    if v_private_final then
      v_state := case
        when v_last_mile_committed then 'END_TO_END_COMMITTED'
        else 'NETWORK_COMMITTED_LAST_MILE_PENDING'
      end;
    else
      v_state := 'ALREADY_AT_DESTINATION';
    end if;
  elsif v_current and v_hops > 0 and v_committed=v_hops then
    if v_private_final and not v_last_mile_committed then
      v_state := 'NETWORK_COMMITTED_LAST_MILE_PENDING';
      v_reason := 'LAST_MILE_NOT_COMMITTED';
    else
      v_state := 'END_TO_END_COMMITTED';
    end if;
  elsif v_current then
    v_state := 'CURRENT_EXECUTABLE';
  else
    v_state := 'STRUCTURAL_ONLY';
    v_reason := 'NO_TRIP_NOW';
  end if;

  insert into public.logistics_promise_evaluations(
    demand_id,routing_attempt_id,promise_state,
    structural_reachable,current_executable,end_to_end_committed,no_trip_now,
    reason_code,detail
  ) values(
    p_demand_id,v_attempt,v_state,
    v_structural,v_current,
    (v_state='END_TO_END_COMMITTED'),
    v_no_trip,
    v_reason,
    jsonb_build_object(
      'hop_count',v_hops,
      'committed_hop_count',v_committed,
      'routing_result',v_result,
      'private_final_destination',v_private_final,
      'last_mile_committed',v_last_mile_committed
    )
  ) returning id into v_eval;

  return v_eval;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.tc_materialize_committed_route(p_routing_attempt_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_attempt public.logistics_routing_attempts%rowtype;
  v_demand public.logistics_demands%rowtype;
  v_plan uuid;
  v_existing_plan uuid;
  v_hop public.logistics_routing_hops%rowtype;
  v_match public.logistics_matches%rowtype;
  v_reservation public.logistics_capacity_reservations%rowtype;
  v_movement uuid;
  v_expected_from timestamptz;
  v_expected_to timestamptz;
  v_manifest uuid;
  v_trip uuid;
  v_hop_count integer;
  v_ready_count integer;
  v_eval uuid;
  v_promise text;
begin
  select p.id into v_existing_plan
  from public.logistics_execution_plans p
  where p.routing_attempt_id=p_routing_attempt_id;

  if v_existing_plan is not null then
    return v_existing_plan;
  end if;

  select * into v_attempt
  from public.logistics_routing_attempts a
  where a.id=p_routing_attempt_id
  for update;

  if v_attempt.id is null then
    raise exception using errcode='P0001', message='TC_ROUTING_ATTEMPT_NOT_FOUND';
  end if;

  select * into v_demand
  from public.logistics_demands d
  where d.id=v_attempt.demand_id
  for update;

  select count(*) into v_hop_count
  from public.logistics_routing_hops h
  where h.routing_attempt_id=v_attempt.id;

  select count(*) into v_ready_count
  from public.logistics_routing_hops h
  join public.logistics_matches m
    on m.routing_hop_id=h.id
   and m.routing_attempt_id=h.routing_attempt_id
   and m.state='ACCEPTED'
  join public.logistics_capacity_reservations r
    on r.id=m.capacity_reservation_id
   and r.state in ('CONFIRMED','CONSUMED')
  join public.logistics_routing_commitments c
    on c.routing_attempt_id=h.routing_attempt_id
   and c.routing_hop_id=h.id
   and c.capacity_reservation_id=r.id
  where h.routing_attempt_id=v_attempt.id;

  if v_hop_count < 1 or v_ready_count <> v_hop_count then
    raise exception using errcode='P0001', message='TC_EXECUTION_ROUTE_NOT_FULLY_COMMITTED';
  end if;

  v_eval := public.tc_evaluate_logistics_promise(v_demand.id,v_attempt.id);

  select p.promise_state into v_promise
  from public.logistics_promise_evaluations p
  where p.id=v_eval;

  if v_promise not in (
    'END_TO_END_COMMITTED',
    'NETWORK_COMMITTED_LAST_MILE_PENDING'
  ) then
    raise exception using errcode='P0001', message='TC_EXECUTION_PROMISE_NOT_COMMITTED';
  end if;

  insert into public.logistics_execution_plans(
    routing_attempt_id,demand_id,state
  ) values(
    v_attempt.id,v_demand.id,'ACTIVE'
  ) returning id into v_plan;

  update public.logistics_private_destination_adapters
     set state='NETWORK_IN_PROGRESS',
         updated_at=now()
   where demand_id=v_demand.id
     and state='PLANNED';

  for v_hop in
    select *
    from public.logistics_routing_hops h
    where h.routing_attempt_id=v_attempt.id
    order by h.hop_sequence
  loop
    select * into v_match
    from public.logistics_matches m
    where m.routing_hop_id=v_hop.id
      and m.routing_attempt_id=v_attempt.id
      and m.state='ACCEPTED';

    select * into v_reservation
    from public.logistics_capacity_reservations r
    where r.id=v_match.capacity_reservation_id;

    if v_match.id is null
       or v_reservation.id is null
       or v_reservation.state not in ('CONFIRMED','CONSUMED') then
      raise exception using errcode='P0001', message='TC_EXECUTION_ACCEPTED_MATCH_INVALID';
    end if;

    -- Serialize movement creation for this real TRIP.
    perform 1
    from public.logistics_trips t
    where t.id=v_match.trip_id
    for update;

    select m.id into v_movement
    from public.movements m
    where m.logistics_trip_id=v_match.trip_id
      and m.logistics_edge_id=v_hop.edge_id
      and m.origin_operational_location_id=v_hop.origin_operational_location_id
      and m.destination_operational_location_id=v_hop.destination_operational_location_id
      and m.board_stop_sequence=v_match.board_stop_sequence
      and m.alight_stop_sequence=v_match.alight_stop_sequence
      and m.state in ('PLANNED','ASSIGNED','READY')
    order by m.created_at,m.id
    limit 1
    for update;

    select
      coalesce(s1.planned_departure_at,s1.planned_arrival_at,t.planned_departure_at),
      coalesce(s2.planned_arrival_at,s2.planned_departure_at,t.planned_arrival_at)
    into v_expected_from,v_expected_to
    from public.logistics_trips t
    join public.logistics_trip_stops s1
      on s1.trip_id=t.id
     and s1.stop_sequence=v_match.board_stop_sequence
    join public.logistics_trip_stops s2
      on s2.trip_id=t.id
     and s2.stop_sequence=v_match.alight_stop_sequence
    where t.id=v_match.trip_id;

    if v_movement is null then
      insert into public.movements(
        movement_type,state,sequence_number,
        expected_from_at,expected_to_at,
        logistics_trip_id,
        origin_operational_location_id,destination_operational_location_id,
        logistics_edge_id,board_stop_sequence,alight_stop_sequence
      ) values(
        'NODE_TO_NODE','PLANNED',v_hop.hop_sequence,
        v_expected_from,v_expected_to,
        v_match.trip_id,
        v_hop.origin_operational_location_id,
        v_hop.destination_operational_location_id,
        v_hop.edge_id,
        v_match.board_stop_sequence,
        v_match.alight_stop_sequence
      ) returning id into v_movement;
    end if;

    insert into public.movement_packages(movement_id,package_id)
    select v_movement,dp.package_id
    from public.logistics_demand_packages dp
    where dp.demand_id=v_demand.id
    on conflict do nothing;

    insert into public.logistics_movement_demands(
      movement_id,demand_id,capacity_reservation_id
    ) values(
      v_movement,v_demand.id,v_reservation.id
    )
    on conflict do nothing;

    insert into public.logistics_hop_executions(
      execution_plan_id,routing_hop_id,match_id,
      capacity_reservation_id,movement_id
    ) values(
      v_plan,v_hop.id,v_match.id,
      v_reservation.id,v_movement
    );
  end loop;

  for v_trip in
    select distinct m.trip_id
    from public.logistics_matches m
    where m.routing_attempt_id=v_attempt.id
      and m.state='ACCEPTED'
  loop
    v_manifest := public.tc_rebuild_trip_manifest_snapshot(
      v_trip,
      'LOAD_PLAN',
      null
    );

    insert into public.logistics_execution_manifests(
      execution_plan_id,trip_id,manifest_id
    ) values(
      v_plan,v_trip,v_manifest
    );
  end loop;

  return v_plan;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.tc_reconcile_execution_plan_completion(p_execution_plan_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_plan public.logistics_execution_plans%rowtype;
  v_effective_count integer;
  v_completed_count integer;
  v_new_state text;
  v_private_adapter uuid;
  v_demand_state text;
begin
  select * into v_plan
  from public.logistics_execution_plans ep
  where ep.id=p_execution_plan_id
  for update;

  if v_plan.id is null then
    raise exception using errcode='P0001', message='TC_EXECUTION_PLAN_NOT_FOUND';
  end if;

  select count(*) into v_effective_count
  from public.logistics_hop_executions he
  where he.execution_plan_id=v_plan.id
    and not exists(
      select 1 from public.logistics_hop_executions nx
      where nx.supersedes_hop_execution_id=he.id
    );

  select count(*) into v_completed_count
  from public.logistics_hop_executions he
  join public.movements m on m.id=he.movement_id
  where he.execution_plan_id=v_plan.id
    and not exists(
      select 1 from public.logistics_hop_executions nx
      where nx.supersedes_hop_execution_id=he.id
    )
    and m.state='COMPLETED';

  if v_effective_count>0 and v_completed_count=v_effective_count then
    update public.logistics_execution_plans
       set state='COMPLETED',updated_at=now()
     where id=v_plan.id
       and state<>'CANCELLED';

    select a.id into v_private_adapter
    from public.logistics_private_destination_adapters a
    where a.demand_id=v_plan.demand_id;

    if v_private_adapter is not null then
      update public.logistics_private_destination_adapters
         set state='AWAITING_LAST_MILE',
             updated_at=now()
       where id=v_private_adapter
         and state not in ('COMPLETED','RECOVERY');

      update public.logistics_demands
         set state='AWAITING_LAST_MILE',
             version=version+1,
             updated_at=now()
       where id=v_plan.demand_id
         and state not in ('DELIVERED','CANCELLED');

      v_demand_state:='AWAITING_LAST_MILE';
    else
      update public.logistics_demands
         set state='DELIVERED',
             version=version+1,
             updated_at=now()
       where id=v_plan.demand_id
         and state not in ('DELIVERED','CANCELLED');

      v_demand_state:='DELIVERED';
    end if;

    v_new_state:='COMPLETED';
  else
    update public.logistics_execution_plans
       set state='ACTIVE',updated_at=now()
     where id=v_plan.id
       and state<>'CANCELLED';

    if exists(
      select 1
      from public.logistics_hop_executions he
      join public.movements m on m.id=he.movement_id
      where he.execution_plan_id=v_plan.id
        and not exists(
          select 1 from public.logistics_hop_executions nx
          where nx.supersedes_hop_execution_id=he.id
        )
        and m.state in ('IN_TRANSIT','ARRIVED','TRANSFER_PENDING','COMPLETED')
    ) then
      update public.logistics_demands
         set state='IN_TRANSIT',version=version+1,updated_at=now()
       where id=v_plan.demand_id
         and state not in ('DELIVERED','CANCELLED','ROUTING_EXCEPTION');
    end if;

    v_new_state:='ACTIVE';
  end if;

  return jsonb_build_object(
    'execution_plan_id',v_plan.id,
    'plan_state',v_new_state,
    'effective_hop_count',v_effective_count,
    'completed_hop_count',v_completed_count,
    'demand_state',coalesce(v_demand_state,(
      select d.state from public.logistics_demands d where d.id=v_plan.demand_id
    ))
  );
end;
$function$
;

revoke all on function public.tc_evaluate_logistics_promise(uuid,uuid)
  from public,anon,authenticated;
revoke all on function public.tc_materialize_committed_route(uuid)
  from public,anon,authenticated;
revoke all on function public.tc_reconcile_execution_plan_completion(uuid)
  from public,anon,authenticated;

grant execute on function public.tc_evaluate_logistics_promise(uuid,uuid)
  to service_role;
grant execute on function public.tc_materialize_committed_route(uuid)
  to service_role;
grant execute on function public.tc_reconcile_execution_plan_completion(uuid)
  to service_role;

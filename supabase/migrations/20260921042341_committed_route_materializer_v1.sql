
create or replace function public.tc_materialize_committed_route(
  p_routing_attempt_id uuid
)
returns uuid
language plpgsql
set search_path = ''
as $$
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

  if v_promise <> 'END_TO_END_COMMITTED' then
    raise exception using errcode='P0001', message='TC_EXECUTION_PROMISE_NOT_COMMITTED';
  end if;

  insert into public.logistics_execution_plans(
    routing_attempt_id,demand_id,state
  ) values(
    v_attempt.id,v_demand.id,'ACTIVE'
  ) returning id into v_plan;

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
$$;

revoke all on function public.tc_materialize_committed_route(uuid)
  from public,anon,authenticated;
grant execute on function public.tc_materialize_committed_route(uuid)
  to service_role;

comment on function public.tc_materialize_committed_route(uuid) is
'Idempotently turns an END_TO_END_COMMITTED routing attempt into planned execution artifacts. Compatible demands reuse an existing PLANNED/ASSIGNED/READY MOV on the same TRIP/EDGE/segment, enabling consolidation without merging PKG/LGD identity.';

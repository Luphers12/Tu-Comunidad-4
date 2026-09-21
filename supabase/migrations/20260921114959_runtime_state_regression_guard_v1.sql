
CREATE OR REPLACE FUNCTION public.tc_commit_routing_attempt(p_routing_attempt_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_attempt public.logistics_routing_attempts%rowtype;
  v_demand public.logistics_demands%rowtype;
  v_hop_count integer;
  v_accepted_count integer;
  v_committed_count integer;
  v_eval uuid;
begin
  select * into v_attempt
  from public.logistics_routing_attempts a
  where a.id=p_routing_attempt_id;

  if v_attempt.id is null then
    raise exception using errcode='P0001', message='TC_ROUTING_ATTEMPT_NOT_FOUND';
  end if;

  if not v_attempt.structural_reachable
     or v_attempt.result_code not in ('CURRENT_EXECUTABLE','NO_TRIP_NOW') then
    raise exception using errcode='P0001', message='TC_ROUTING_ATTEMPT_NOT_COMMITTABLE';
  end if;

  select * into v_demand
  from public.logistics_demands d
  where d.id=v_attempt.demand_id
  for update;

  select count(*) into v_hop_count
  from public.logistics_routing_hops h
  where h.routing_attempt_id=v_attempt.id;

  select count(distinct m.routing_hop_id)
    into v_accepted_count
  from public.logistics_matches m
  where m.routing_attempt_id=v_attempt.id
    and m.state='ACCEPTED'
    and m.commitment_mode='ACCEPTANCE_REQUIRED'
    and m.capacity_reservation_id is not null;

  select count(distinct c.routing_hop_id)
    into v_committed_count
  from public.logistics_routing_commitments c
  join public.logistics_capacity_reservations r
    on r.id=c.capacity_reservation_id
  where c.routing_attempt_id=v_attempt.id
    and r.state in ('CONFIRMED','CONSUMED');

  if v_hop_count < 1
     or v_accepted_count <> v_hop_count
     or v_committed_count <> v_hop_count then
    raise exception using errcode='P0001', message='TC_ROUTING_HOP_ACCEPTANCE_REQUIRED';
  end if;

  if v_demand.state in (
    'CREATED',
    'READY_FOR_ROUTING',
    'ROUTING',
    'PARTIALLY_ASSIGNED',
    'ROUTING_EXCEPTION'
  ) then
    update public.logistics_demands
       set state='ASSIGNED',
           routing_exception_code=null,
           routing_exception_detail=null,
           version=version+1,
           updated_at=now()
     where id=v_demand.id;

  elsif v_demand.state='ASSIGNED' then
    null;

  elsif v_demand.state in (
    'IN_TRANSIT',
    'AWAITING_LAST_MILE',
    'LAST_MILE_ASSIGNED',
    'DELIVERED',
    'CANCELLED'
  ) then
    -- Stale/replayed network acceptance must never regress lifecycle state.
    null;

  else
    raise exception using errcode='P0001', message='TC_ROUTING_DEMAND_STATE_UNSUPPORTED';
  end if;

  v_eval := public.tc_evaluate_logistics_promise(
    v_demand.id,
    v_attempt.id
  );

  return v_eval;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.tc_process_logistics_runtime_event(p_outbox_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_job public.logistics_runtime_outbox%rowtype;
  v_demand public.logistics_demands%rowtype;
  v_trip public.logistics_trips%rowtype;
  v_match public.logistics_matches%rowtype;
  v_match_demand public.logistics_demands%rowtype;
  v_run public.logistics_movement_reconciliation_runs%rowtype;
  v_attempt uuid;
  v_plan uuid;
  v_refresh jsonb;
  v_eval uuid;
  v_hop_count integer;
  v_accepted_count integer;
  v_commitment_count integer;
  v_he public.logistics_hop_executions%rowtype;
  v_old_he public.logistics_hop_executions%rowtype;
  v_case uuid;
  v_case_key text;
  v_count integer := 0;
  v_results jsonb := '[]'::jsonb;
  v_last_mile jsonb;
  v_attempt_result text;
  v_rec record;
begin
  select * into v_job
  from public.logistics_runtime_outbox o
  where o.id=p_outbox_id
  for update;

  if v_job.id is null then
    raise exception using errcode='P0001', message='TC_RUNTIME_OUTBOX_NOT_FOUND';
  end if;

  if v_job.event_type='DEMAND_ROUTABLE' then
    select * into v_demand
    from public.logistics_demands d
    where d.id=v_job.demand_id;

    if v_demand.id is null then
      return jsonb_build_object('status','IGNORED','reason','DEMAND_NOT_FOUND');
    end if;

    if v_demand.state not in ('READY_FOR_ROUTING','ROUTING','PARTIALLY_ASSIGNED') then
      return jsonb_build_object(
        'status','IGNORED_STALE',
        'demand_state',v_demand.state
      );
    end if;

    select ep.id,ep.routing_attempt_id
      into v_plan,v_attempt
    from public.logistics_execution_plans ep
    where ep.demand_id=v_demand.id
      and ep.state='ACTIVE'
    order by ep.created_at desc,ep.id desc
    limit 1;

    if v_attempt is null then
      v_attempt:=public.tc_resolve_logistics_demand(v_demand.id,'NORMAL',8);
    end if;

    select a.result_code into v_attempt_result
    from public.logistics_routing_attempts a
    where a.id=v_attempt;

    if v_attempt_result='ALREADY_AT_DESTINATION'
       and exists(
         select 1
         from public.logistics_private_destination_adapters a
         where a.demand_id=v_demand.id
       ) then
      update public.logistics_private_destination_adapters
         set state='AWAITING_LAST_MILE',
             updated_at=now()
       where demand_id=v_demand.id
         and state not in ('COMPLETED','RECOVERY');

      update public.logistics_demands
         set state='AWAITING_LAST_MILE',
             version=version+1,
             updated_at=now()
       where id=v_demand.id
         and state not in ('DELIVERED','CANCELLED');

      v_eval:=public.tc_evaluate_logistics_promise(v_demand.id,v_attempt);

      return jsonb_build_object(
        'status','AT_LAST_MILE_ORIGIN',
        'event_type',v_job.event_type,
        'demand_id',v_demand.id,
        'routing_attempt_id',v_attempt,
        'promise_evaluation_id',v_eval
      );
    end if;

    v_refresh:=public.tc_refresh_logistics_matches(v_attempt);
    v_eval:=public.tc_evaluate_logistics_promise(v_demand.id,v_attempt);

    return jsonb_build_object(
      'status','PROCESSED',
      'event_type',v_job.event_type,
      'demand_id',v_demand.id,
      'routing_attempt_id',v_attempt,
      'execution_plan_id',v_plan,
      'match_refresh',v_refresh,
      'promise_evaluation_id',v_eval
    );

  elsif v_job.event_type='TRIP_AVAILABLE' then
    select * into v_trip
    from public.logistics_trips t
    where t.id=v_job.trip_id;

    if v_trip.id is null then
      return jsonb_build_object('status','IGNORED','reason','TRIP_NOT_FOUND');
    end if;

    if v_trip.state not in ('PUBLISHED','ACCEPTING') then
      return jsonb_build_object(
        'status','IGNORED_STALE',
        'trip_state',v_trip.state
      );
    end if;

    for v_rec in
      with latest as (
        select distinct on (a.demand_id)
          a.id,a.demand_id,a.result_code,a.attempted_at,a.created_at
        from public.logistics_routing_attempts a
        order by a.demand_id,a.attempt_seq desc
      )
      select
        l.id as routing_attempt_id,
        l.demand_id,
        l.result_code
      from latest l
      join public.logistics_demands d on d.id=l.demand_id
      where d.state in ('READY_FOR_ROUTING','ROUTING','PARTIALLY_ASSIGNED')
        and exists(
          select 1
          from public.logistics_routing_hops h
          join public.logistics_trip_stops s1
            on s1.trip_id=v_trip.id
           and s1.operational_location_id=h.origin_operational_location_id
          join public.logistics_trip_stops s2
            on s2.trip_id=v_trip.id
           and s2.operational_location_id=h.destination_operational_location_id
           and s2.stop_sequence>s1.stop_sequence
          where h.routing_attempt_id=l.id
        )
    loop
      if v_rec.result_code='NO_TRIP_NOW' then
        v_attempt:=public.tc_resolve_logistics_demand(v_rec.demand_id,'NORMAL',8);
      else
        v_attempt:=v_rec.routing_attempt_id;
      end if;

      v_refresh:=public.tc_refresh_logistics_matches(v_attempt);
      v_eval:=public.tc_evaluate_logistics_promise(v_rec.demand_id,v_attempt);
      v_count:=v_count+1;

      v_results:=v_results||jsonb_build_array(
        jsonb_build_object(
          'demand_id',v_rec.demand_id,
          'routing_attempt_id',v_attempt,
          'previous_result_code',v_rec.result_code,
          'match_refresh',v_refresh,
          'promise_evaluation_id',v_eval
        )
      );
    end loop;

    return jsonb_build_object(
      'status','PROCESSED',
      'event_type',v_job.event_type,
      'trip_id',v_trip.id,
      'affected_demand_count',v_count,
      'results',v_results
    );

  elsif v_job.event_type='MATCH_ACCEPTED' then
    select * into v_match
    from public.logistics_matches m
    where m.id=v_job.match_id;

    if v_match.id is null then
      return jsonb_build_object('status','IGNORED','reason','MATCH_NOT_FOUND');
    end if;

    if v_match.state<>'ACCEPTED' then
      return jsonb_build_object(
        'status','IGNORED_STALE',
        'match_state',v_match.state
      );
    end if;

    select d.* into v_match_demand
    from public.logistics_routing_attempts a
    join public.logistics_demands d on d.id=a.demand_id
    where a.id=v_match.routing_attempt_id;

    if v_match_demand.id is null then
      return jsonb_build_object(
        'status','IGNORED',
        'reason','MATCH_DEMAND_NOT_FOUND'
      );
    end if;

    if v_match_demand.state in (
      'IN_TRANSIT',
      'AWAITING_LAST_MILE',
      'LAST_MILE_ASSIGNED',
      'DELIVERED',
      'CANCELLED'
    ) then
      return jsonb_build_object(
        'status','IGNORED_STALE',
        'reason','DEMAND_ALREADY_ADVANCED',
        'demand_state',v_match_demand.state,
        'match_id',v_match.id
      );
    end if;

    select count(*) into v_hop_count
    from public.logistics_routing_hops h
    where h.routing_attempt_id=v_match.routing_attempt_id;

    select count(distinct m.routing_hop_id)
      into v_accepted_count
    from public.logistics_matches m
    join public.logistics_capacity_reservations r
      on r.id=m.capacity_reservation_id
    where m.routing_attempt_id=v_match.routing_attempt_id
      and m.state='ACCEPTED'
      and r.state in ('CONFIRMED','CONSUMED');

    select count(distinct c.routing_hop_id)
      into v_commitment_count
    from public.logistics_routing_commitments c
    join public.logistics_capacity_reservations r
      on r.id=c.capacity_reservation_id
    where c.routing_attempt_id=v_match.routing_attempt_id
      and r.state in ('CONFIRMED','CONSUMED');

    if v_hop_count<1
       or v_accepted_count<>v_hop_count
       or v_commitment_count<>v_hop_count then
      return jsonb_build_object(
        'status','WAITING_FOR_ACCEPTANCES',
        'hop_count',v_hop_count,
        'accepted_hop_count',v_accepted_count,
        'committed_hop_count',v_commitment_count
      );
    end if;

    v_eval:=public.tc_commit_routing_attempt(v_match.routing_attempt_id);

    select ep.id into v_plan
    from public.logistics_execution_plans ep
    where ep.routing_attempt_id=v_match.routing_attempt_id
    order by ep.created_at desc,ep.id desc
    limit 1;

    if v_plan is null then
      v_plan:=public.tc_materialize_committed_route(v_match.routing_attempt_id);

      return jsonb_build_object(
        'status','MATERIALIZED',
        'routing_attempt_id',v_match.routing_attempt_id,
        'execution_plan_id',v_plan,
        'promise_evaluation_id',v_eval
      );
    end if;

    select he.* into v_he
    from public.logistics_hop_executions he
    where he.execution_plan_id=v_plan
      and he.routing_hop_id=v_match.routing_hop_id
      and not exists(
        select 1
        from public.logistics_hop_executions nx
        where nx.supersedes_hop_execution_id=he.id
      )
    order by he.created_at desc,he.id desc
    limit 1;

    if v_he.id is not null and v_he.match_id=v_match.id then
      return jsonb_build_object(
        'status','ALREADY_MATERIALIZED',
        'execution_plan_id',v_plan,
        'hop_execution_id',v_he.id,
        'movement_id',v_he.movement_id,
        'promise_evaluation_id',v_eval
      );
    end if;

    if v_he.id is not null
       and exists(
         select 1 from public.movements mv
         where mv.id=v_he.movement_id and mv.state='CANCELLED'
       ) then
      v_he.id:=public.tc_materialize_replacement_hop(
        v_plan,v_match.routing_hop_id,'RUNTIME_MATCH_ACCEPTED'
      );

      select * into v_he
      from public.logistics_hop_executions
      where id=v_he.id;

      return jsonb_build_object(
        'status','REPLACEMENT_MATERIALIZED',
        'execution_plan_id',v_plan,
        'hop_execution_id',v_he.id,
        'movement_id',v_he.movement_id,
        'promise_evaluation_id',v_eval
      );
    end if;

    return jsonb_build_object(
      'status','PLAN_ALREADY_EXISTS',
      'execution_plan_id',v_plan,
      'promise_evaluation_id',v_eval
    );

  elsif v_job.event_type='MOVEMENT_COMPLETED' then
    if not exists(
      select 1 from public.movements m
      where m.id=v_job.movement_id and m.state='COMPLETED'
    ) then
      return jsonb_build_object('status','IGNORED_STALE','reason','MOVEMENT_NOT_COMPLETED');
    end if;

    return jsonb_build_object(
      'status','PROCESSED',
      'event_type',v_job.event_type,
      'movement_id',v_job.movement_id,
      'continuation',public.tc_continue_execution_after_movement(v_job.movement_id)
    );

  elsif v_job.event_type='LAST_MILE_READY' then
    select * into v_demand
    from public.logistics_demands d
    where d.id=v_job.demand_id;

    if v_demand.id is null then
      return jsonb_build_object('status','IGNORED','reason','DEMAND_NOT_FOUND');
    end if;

    if v_demand.state not in ('AWAITING_LAST_MILE','LAST_MILE_ASSIGNED') then
      return jsonb_build_object(
        'status','IGNORED_STALE',
        'demand_state',v_demand.state
      );
    end if;

    v_last_mile:=public.tc_create_last_mile_task_for_demand(v_demand.id);

    return jsonb_build_object(
      'status','LAST_MILE_TASK_READY',
      'event_type',v_job.event_type,
      'demand_id',v_demand.id,
      'last_mile',v_last_mile
    );

  elsif v_job.event_type='ARRIVAL_MISMATCH' then
    select * into v_run
    from public.logistics_movement_reconciliation_runs r
    where r.id=v_job.reconciliation_run_id;

    if v_run.id is null then
      return jsonb_build_object('status','IGNORED','reason','RECONCILIATION_RUN_NOT_FOUND');
    end if;

    if v_run.status<>'MISMATCH' then
      return jsonb_build_object(
        'status','IGNORED_STALE',
        'reconciliation_status',v_run.status
      );
    end if;

    v_case_key:='ARRIVAL_MISMATCH:'||v_run.movement_id::text||':'||v_run.manifest_id::text;

    insert into public.logistics_recovery_cases(
      case_key,case_type,movement_id,manifest_id
    ) values(
      v_case_key,'ARRIVAL_MISMATCH',v_run.movement_id,v_run.manifest_id
    )
    on conflict (case_key) do nothing
    returning id into v_case;

    if v_case is null then
      select id into v_case
      from public.logistics_recovery_cases
      where case_key=v_case_key;
    else
      insert into public.logistics_recovery_events(
        recovery_case_id,event_type,reason_code,metadata
      ) values(
        v_case,'OPENED','ARRIVAL_MISMATCH_RUNTIME',
        jsonb_build_object(
          'reconciliation_run_id',v_run.id,
          'missing_count',v_run.missing_count,
          'unexpected_count',v_run.unexpected_count
        )
      );
    end if;

    return jsonb_build_object(
      'status','RECOVERY_OPEN',
      'recovery_case_id',v_case,
      'movement_id',v_run.movement_id,
      'reconciliation_run_id',v_run.id
    );
  end if;

  raise exception using errcode='P0001', message='TC_RUNTIME_EVENT_TYPE_UNHANDLED';
end;
$function$
;

revoke all on function public.tc_commit_routing_attempt(uuid)
  from public,anon,authenticated;
revoke all on function public.tc_process_logistics_runtime_event(uuid)
  from public,anon,authenticated;

grant execute on function public.tc_commit_routing_attempt(uuid)
  to service_role;
grant execute on function public.tc_process_logistics_runtime_event(uuid)
  to service_role;

comment on function public.tc_commit_routing_attempt(uuid) is
'Monotonic network commitment: accepted-route replay may move pre-execution demand to ASSIGNED, but can never regress IN_TRANSIT, AWAITING_LAST_MILE, LAST_MILE_ASSIGNED, DELIVERED or CANCELLED.';

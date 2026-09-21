
create or replace function public.tc_materialize_replacement_hop(
  p_execution_plan_id uuid,
  p_routing_hop_id uuid,
  p_reason_code text default 'RECANDIDATE'
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_plan public.logistics_execution_plans%rowtype;
  v_hop public.logistics_routing_hops%rowtype;
  v_match public.logistics_matches%rowtype;
  v_reservation public.logistics_capacity_reservations%rowtype;
  v_old_he public.logistics_hop_executions%rowtype;
  v_movement uuid;
  v_expected_from timestamptz;
  v_expected_to timestamptz;
  v_new_he uuid;
  v_manifest uuid;
  v_case uuid;
begin
  select * into v_plan
  from public.logistics_execution_plans ep
  where ep.id=p_execution_plan_id
  for update;

  if v_plan.id is null or v_plan.state<>'ACTIVE' then
    raise exception using errcode='P0001', message='TC_EXECUTION_PLAN_NOT_ACTIVE';
  end if;

  select * into v_hop
  from public.logistics_routing_hops h
  where h.id=p_routing_hop_id
    and h.routing_attempt_id=v_plan.routing_attempt_id;

  if v_hop.id is null then
    raise exception using errcode='P0001', message='TC_EXECUTION_HOP_NOT_IN_PLAN';
  end if;

  select he.* into v_old_he
  from public.logistics_hop_executions he
  where he.execution_plan_id=v_plan.id
    and he.routing_hop_id=v_hop.id
    and not exists(
      select 1 from public.logistics_hop_executions nx
      where nx.supersedes_hop_execution_id=he.id
    )
  order by he.created_at desc,he.id desc
  limit 1;

  if v_old_he.id is null then
    raise exception using errcode='P0001', message='TC_EXECUTION_HOP_HISTORY_REQUIRED';
  end if;

  if not exists(
    select 1 from public.movements m
    where m.id=v_old_he.movement_id and m.state='CANCELLED'
  ) then
    raise exception using errcode='P0001', message='TC_EXECUTION_OLD_MOVEMENT_NOT_CANCELLED';
  end if;

  select m.* into v_match
  from public.logistics_matches m
  join public.logistics_capacity_reservations r
    on r.id=m.capacity_reservation_id
  where m.routing_attempt_id=v_plan.routing_attempt_id
    and m.routing_hop_id=v_hop.id
    and m.state='ACCEPTED'
    and r.state in ('CONFIRMED','CONSUMED')
    and not exists(
      select 1
      from public.logistics_hop_executions he
      where he.match_id=m.id
    )
  order by m.responded_at desc,m.id desc
  limit 1;

  if v_match.id is null then
    raise exception using errcode='P0001', message='TC_EXECUTION_REPLACEMENT_ACCEPTED_MATCH_REQUIRED';
  end if;

  select * into v_reservation
  from public.logistics_capacity_reservations r
  where r.id=v_match.capacity_reservation_id;

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
    on s1.trip_id=t.id and s1.stop_sequence=v_match.board_stop_sequence
  join public.logistics_trip_stops s2
    on s2.trip_id=t.id and s2.stop_sequence=v_match.alight_stop_sequence
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
  where dp.demand_id=v_plan.demand_id
  on conflict do nothing;

  insert into public.logistics_movement_demands(
    movement_id,demand_id,capacity_reservation_id
  ) values(
    v_movement,v_plan.demand_id,v_reservation.id
  )
  on conflict do nothing;

  insert into public.logistics_hop_executions(
    execution_plan_id,routing_hop_id,match_id,
    capacity_reservation_id,movement_id,
    supersedes_hop_execution_id,replacement_reason
  ) values(
    v_plan.id,v_hop.id,v_match.id,
    v_reservation.id,v_movement,
    v_old_he.id,
    coalesce(nullif(btrim(coalesce(p_reason_code,'')),''),'RECANDIDATE')
  ) returning id into v_new_he;

  v_manifest:=public.tc_rebuild_trip_manifest_snapshot(
    v_match.trip_id,'RECOVERY',null
  );

  insert into public.logistics_execution_manifests(
    execution_plan_id,trip_id,manifest_id
  ) values(
    v_plan.id,v_match.trip_id,v_manifest
  )
  on conflict (execution_plan_id,trip_id) do nothing;

  select rc.id into v_case
  from public.logistics_recovery_cases rc
  where rc.movement_id=v_old_he.movement_id
    and rc.case_type='MATERIALIZED_CANDIDATE_FAILED'
  order by rc.created_at desc
  limit 1;

  if v_case is not null then
    insert into public.logistics_recovery_events(
      recovery_case_id,event_type,reason_code,metadata
    ) values(
      v_case,'REPLACEMENT_ACCEPTED',
      coalesce(nullif(btrim(coalesce(p_reason_code,'')),''),'RECANDIDATE'),
      jsonb_build_object(
        'old_hop_execution_id',v_old_he.id,
        'new_hop_execution_id',v_new_he,
        'new_match_id',v_match.id,
        'new_movement_id',v_movement,
        'manifest_id',v_manifest
      )
    );
  end if;

  return v_new_he;
end;
$$;

revoke all on function public.tc_materialize_replacement_hop(uuid,uuid,text)
  from public,anon,authenticated;
grant execute on function public.tc_materialize_replacement_hop(uuid,uuid,text)
  to service_role;

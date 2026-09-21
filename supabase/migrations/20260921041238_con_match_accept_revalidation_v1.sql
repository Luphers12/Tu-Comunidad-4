
create or replace function public.tc_respond_logistics_match(
  p_match_id uuid,
  p_driver_profile_id uuid,
  p_action text,
  p_reason_code text default null
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_action text := upper(btrim(coalesce(p_action,'')));
  v_match public.logistics_matches%rowtype;
  v_trip public.logistics_trips%rowtype;
  v_demand public.logistics_demands%rowtype;
  v_package_count integer;
  v_reservation uuid;
  v_commitment uuid;
  v_edge uuid;
  v_edge_state text;
  v_capacity public.logistics_trip_capacity%rowtype;
begin
  if v_action not in ('ACCEPT','REJECT') then
    raise exception using errcode='P0001', message='TC_MATCH_ACTION_INVALID';
  end if;

  select * into v_match
  from public.logistics_matches m
  where m.id=p_match_id
  for update;

  if v_match.id is null then
    raise exception using errcode='P0001', message='TC_MATCH_NOT_FOUND';
  end if;

  if v_match.candidate_kind <> 'TRIP'
     or v_match.commitment_mode <> 'ACCEPTANCE_REQUIRED' then
    raise exception using errcode='P0001', message='TC_MATCH_RESPONSE_MODE_INVALID';
  end if;

  select * into v_trip
  from public.logistics_trips t
  where t.id=v_match.trip_id;

  if v_trip.driver_profile_id is distinct from p_driver_profile_id then
    raise exception using errcode='P0001', message='TC_MATCH_DRIVER_FORBIDDEN';
  end if;

  if v_match.state='ACCEPTED' then
    return jsonb_build_object(
      'match_id',v_match.id,
      'state','ACCEPTED',
      'capacity_reservation_id',v_match.capacity_reservation_id,
      'idempotent',true
    );
  end if;

  if v_match.state <> 'OFFERED' then
    raise exception using errcode='P0001', message='TC_MATCH_ALREADY_RESOLVED';
  end if;

  if v_action='REJECT' then
    update public.logistics_matches
       set state='REJECTED',
           responded_at=now(),
           updated_at=now()
     where id=v_match.id;

    insert into public.logistics_match_events(
      match_id,event_type,actor_profile_id,reason_code
    ) values(
      v_match.id,'REJECTED',p_driver_profile_id,
      nullif(btrim(coalesce(p_reason_code,'')),'')
    );

    return jsonb_build_object(
      'match_id',v_match.id,
      'state','REJECTED',
      'capacity_reservation_id',null,
      'idempotent',false
    );
  end if;

  -- Full atomic revalidation before ACCEPT.
  if v_trip.state not in ('PUBLISHED','ACCEPTING') then
    raise exception using errcode='P0001', message='TC_MATCH_TRIP_NOT_ACCEPTING';
  end if;

  if not exists (
    select 1
    from public.profiles p
    where p.id=v_trip.driver_profile_id
      and p.profile_type='CON'
      and p.status='active'
  ) then
    raise exception using errcode='P0001', message='TC_MATCH_DRIVER_NOT_ACTIVE_CON';
  end if;

  if not exists (
    select 1
    from public.vehicles v
    where v.id=v_trip.vehicle_id
      and v.is_active
  ) then
    raise exception using errcode='P0001', message='TC_MATCH_VEHICLE_NOT_ACTIVE';
  end if;

  if not exists (
    select 1
    from public.driver_vehicle_authorizations a
    where a.driver_profile_id=v_trip.driver_profile_id
      and a.vehicle_id=v_trip.vehicle_id
      and a.is_active
      and a.valid_from <= v_trip.planned_departure_at
      and (a.valid_until is null or a.valid_until >= v_trip.planned_departure_at)
  ) then
    raise exception using errcode='P0001', message='TC_MATCH_DRIVER_VEHICLE_NOT_AUTHORIZED';
  end if;

  if not exists (
    select 1
    from public.logistics_trip_stops s1
    join public.logistics_trip_stops s2
      on s2.trip_id=s1.trip_id
     and s2.stop_sequence=v_match.alight_stop_sequence
    join public.logistics_routing_hops h
      on h.id=v_match.routing_hop_id
    where s1.trip_id=v_match.trip_id
      and s1.stop_sequence=v_match.board_stop_sequence
      and s1.operational_location_id=h.origin_operational_location_id
      and s2.operational_location_id=h.destination_operational_location_id
      and s2.stop_sequence>s1.stop_sequence
  ) then
    raise exception using errcode='P0001', message='TC_MATCH_DECLARED_POINTS_CHANGED';
  end if;

  select h.edge_id into v_edge
  from public.logistics_routing_hops h
  where h.id=v_match.routing_hop_id;

  select ese.state into v_edge_state
  from public.logistics_edge_state_events ese
  where ese.edge_id=v_edge
    and ese.effective_at <= now()
  order by ese.effective_at desc,ese.created_at desc,ese.id desc
  limit 1;

  if v_edge_state is distinct from 'OPEN' then
    raise exception using errcode='P0001', message='TC_MATCH_EDGE_NOT_OPEN';
  end if;

  select * into v_demand
  from public.logistics_demands d
  where d.id=v_match.demand_id
  for update;

  select * into v_capacity
  from public.logistics_trip_capacity c
  where c.trip_id=v_match.trip_id;

  if v_capacity.trip_id is null then
    raise exception using errcode='P0001', message='TC_MATCH_TRIP_CAPACITY_REQUIRED';
  end if;

  if v_demand.requires_cold_chain and not v_capacity.accepts_cold_chain then
    raise exception using errcode='P0001', message='TC_MATCH_REQUIREMENT_COLD_CHAIN';
  end if;

  if v_demand.requires_fragile_handling and not v_capacity.accepts_fragile then
    raise exception using errcode='P0001', message='TC_MATCH_REQUIREMENT_FRAGILE';
  end if;

  if v_demand.earliest_ready_at is not null
     and v_trip.planned_departure_at < v_demand.earliest_ready_at then
    raise exception using errcode='P0001', message='TC_MATCH_TIME_WINDOW_NOT_READY';
  end if;

  if v_demand.latest_delivery_at is not null
     and (
       v_trip.planned_arrival_at is null
       or v_trip.planned_arrival_at > v_demand.latest_delivery_at
     ) then
    raise exception using errcode='P0001', message='TC_MATCH_TIME_WINDOW_LATE';
  end if;

  if exists (
    select 1
    from public.logistics_demand_packages dp
    join public.packages p on p.id=dp.package_id
    join public.logistics_edges e on e.id=v_edge
    where dp.demand_id=v_demand.id
      and (
        (e.max_single_package_weight_kg is not null
          and p.weight_kg > e.max_single_package_weight_kg)
        or
        (e.max_single_package_volume_m3 is not null
          and p.volume_m3 > e.max_single_package_volume_m3)
      )
  ) then
    raise exception using errcode='P0001', message='TC_MATCH_PACKAGE_EDGE_REQUIREMENT_CONFLICT';
  end if;

  select count(*) into v_package_count
  from public.logistics_demand_packages dp
  where dp.demand_id=v_demand.id;

  if v_package_count < 1 then
    raise exception using errcode='P0001', message='TC_MATCH_DEMAND_HAS_NO_PACKAGES';
  end if;

  -- Reservation trigger revalidates segment capacity under lock.
  insert into public.logistics_capacity_reservations(
    trip_id,demand_id,board_stop_sequence,alight_stop_sequence,
    reserved_weight_kg,reserved_volume_m3,reserved_packages,
    state,idempotency_key
  ) values(
    v_match.trip_id,
    v_demand.id,
    v_match.board_stop_sequence,
    v_match.alight_stop_sequence,
    v_demand.total_weight_kg,
    v_demand.total_volume_m3,
    v_package_count,
    'CONFIRMED',
    'MATCH:'||v_match.public_id
  )
  returning id into v_reservation;

  insert into public.logistics_routing_commitments(
    routing_attempt_id,routing_hop_id,capacity_reservation_id
  ) values(
    v_match.routing_attempt_id,
    v_match.routing_hop_id,
    v_reservation
  )
  returning id into v_commitment;

  update public.logistics_matches
     set state='ACCEPTED',
         capacity_reservation_id=v_reservation,
         responded_at=now(),
         updated_at=now()
   where id=v_match.id;

  insert into public.logistics_match_events(
    match_id,event_type,actor_profile_id,reason_code,metadata
  ) values(
    v_match.id,'ACCEPTED',p_driver_profile_id,
    nullif(btrim(coalesce(p_reason_code,'')),''),
    jsonb_build_object(
      'capacity_reservation_id',v_reservation,
      'routing_commitment_id',v_commitment,
      'revalidated',true
    )
  );

  return jsonb_build_object(
    'match_id',v_match.id,
    'state','ACCEPTED',
    'capacity_reservation_id',v_reservation,
    'routing_commitment_id',v_commitment,
    'idempotent',false
  );
end;
$$;

revoke all on function public.tc_respond_logistics_match(uuid,uuid,text,text)
  from public,anon,authenticated;
grant execute on function public.tc_respond_logistics_match(uuid,uuid,text,text)
  to service_role;

comment on function public.tc_respond_logistics_match(uuid,uuid,text,text) is
'CON ACCEPT/REJECT. ACCEPT atomically revalidates active CON, active vehicle, driver-vehicle authorization, exact declared points, open edge, time/handling/package requirements and segment capacity before reservation + commitment.';

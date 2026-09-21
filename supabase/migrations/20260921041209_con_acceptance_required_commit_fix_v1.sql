
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

  if v_trip.state not in ('PUBLISHED','ACCEPTING') then
    raise exception using errcode='P0001', message='TC_MATCH_TRIP_NOT_ACCEPTING';
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

  select * into v_demand
  from public.logistics_demands d
  where d.id=v_match.demand_id
  for update;

  select count(*) into v_package_count
  from public.logistics_demand_packages dp
  where dp.demand_id=v_demand.id;

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
    match_id,event_type,actor_profile_id,reason_code,
    metadata
  ) values(
    v_match.id,'ACCEPTED',p_driver_profile_id,
    nullif(btrim(coalesce(p_reason_code,'')),''),
    jsonb_build_object(
      'capacity_reservation_id',v_reservation,
      'routing_commitment_id',v_commitment
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

create or replace function public.tc_commit_routing_attempt(
  p_routing_attempt_id uuid
)
returns uuid
language plpgsql
set search_path = ''
as $$
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

  update public.logistics_demands
     set state='ASSIGNED',
         routing_exception_code=null,
         routing_exception_detail=null,
         version=version+1,
         updated_at=now()
   where id=v_demand.id
     and state not in ('DELIVERED','CANCELLED');

  v_eval := public.tc_evaluate_logistics_promise(
    v_demand.id,
    v_attempt.id
  );

  return v_eval;
end;
$$;

revoke all on function public.tc_respond_logistics_match(uuid,uuid,text,text)
  from public,anon,authenticated;
revoke all on function public.tc_commit_routing_attempt(uuid)
  from public,anon,authenticated;

grant execute on function public.tc_respond_logistics_match(uuid,uuid,text,text)
  to service_role;
grant execute on function public.tc_commit_routing_attempt(uuid)
  to service_role;

comment on function public.tc_respond_logistics_match(uuid,uuid,text,text) is
'CON opportunity response. REJECT is voluntary and creates no reservation. ACCEPT revalidates the exact declared trip points and atomically creates segment capacity reservation + routing commitment.';
comment on function public.tc_commit_routing_attempt(uuid) is
'Finalizes a routing attempt only after every hop has a valid accepted candidate and confirmed/consumed capacity commitment. It never auto-assigns a human CON.';

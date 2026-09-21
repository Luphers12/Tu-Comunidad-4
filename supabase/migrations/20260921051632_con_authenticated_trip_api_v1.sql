
create or replace function public.tc_con_create_trip(
  p_con_public_id text,
  p_vehicle_public_id text,
  p_trip_reason text,
  p_stops jsonb,
  p_capacity jsonb,
  p_accepted_cargo jsonb default '{}'::jsonb,
  p_conditions jsonb default '{}'::jsonb,
  p_publish boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_con uuid;
  v_vehicle uuid;
  v_trip uuid;
  v_trip_public_id text;
  v_origin uuid;
  v_destination uuid;
  v_departure timestamptz;
  v_arrival timestamptz;
  v_return timestamptz;
  v_stop_count integer;
  v_start_count integer;
  v_end_count integer;
  v_resolved_count integer;
  v_weight numeric;
  v_volume numeric;
  v_packages integer;
  v_cold boolean;
  v_fragile boolean;
  v_bulky boolean;
  v_rural boolean;
  v_state text;
  v_version bigint;
begin
  v_con:=public.tc_require_my_con_profile(p_con_public_id);

  if nullif(btrim(coalesce(p_trip_reason,'')),'') is null then
    raise exception using errcode='P0001', message='TC_TRIP_REASON_REQUIRED';
  end if;

  if jsonb_typeof(p_stops)<>'array' then
    raise exception using errcode='P0001', message='TC_TRIP_STOPS_ARRAY_REQUIRED';
  end if;

  v_stop_count:=jsonb_array_length(p_stops);
  if v_stop_count<2 or v_stop_count>50 then
    raise exception using errcode='P0001', message='TC_TRIP_STOP_COUNT_INVALID';
  end if;

  if exists(
    select 1
    from jsonb_array_elements(p_stops) e(value)
    where jsonb_typeof(e.value)<>'object'
       or nullif(btrim(coalesce(e.value->>'node_public_id','')),'') is null
       or upper(btrim(coalesce(e.value->>'stop_kind',''))) not in ('START','WAYPOINT','END','RETURN')
  ) then
    raise exception using errcode='P0001', message='TC_TRIP_STOP_PAYLOAD_INVALID';
  end if;

  select count(*) filter(where upper(btrim(e.value->>'stop_kind'))='START'),
         count(*) filter(where upper(btrim(e.value->>'stop_kind'))='END')
    into v_start_count,v_end_count
  from jsonb_array_elements(p_stops) e(value);

  if v_start_count<>1
     or upper(btrim(p_stops->0->>'stop_kind'))<>'START'
     or v_end_count<>1 then
    raise exception using errcode='P0001', message='TC_TRIP_START_END_INVALID';
  end if;

  select v.id into v_vehicle
  from public.vehicles v
  join public.driver_vehicle_authorizations a
    on a.vehicle_id=v.id
   and a.driver_profile_id=v_con
  where v.public_id=upper(btrim(coalesce(p_vehicle_public_id,'')))
    and v.is_active
    and a.is_active;

  if v_vehicle is null then
    raise exception using errcode='P0001', message='TC_CON_VEHICLE_FORBIDDEN';
  end if;

  select count(*) into v_resolved_count
  from jsonb_array_elements(p_stops) e(value)
  join public.operational_locations o
    on o.public_id=upper(btrim(e.value->>'node_public_id'))
   and o.active
   and o.network_enabled;

  if v_resolved_count<>v_stop_count then
    raise exception using errcode='P0001', message='TC_TRIP_STOP_NOT_NETWORK_NODE';
  end if;

  select o.id,
         nullif(btrim(p_stops->0->>'planned_departure_at'),'')::timestamptz
    into v_origin,v_departure
  from public.operational_locations o
  where o.public_id=upper(btrim(p_stops->0->>'node_public_id'));

  select o.id,
         nullif(btrim(e.value->>'planned_arrival_at'),'')::timestamptz
    into v_destination,v_arrival
  from jsonb_array_elements(p_stops) e(value)
  join public.operational_locations o
    on o.public_id=upper(btrim(e.value->>'node_public_id'))
  where upper(btrim(e.value->>'stop_kind'))='END'
  limit 1;

  if v_departure is null then
    raise exception using errcode='P0001', message='TC_TRIP_START_DEPARTURE_REQUIRED';
  end if;

  select max(coalesce(
    nullif(btrim(e.value->>'planned_arrival_at'),'')::timestamptz,
    nullif(btrim(e.value->>'planned_departure_at'),'')::timestamptz
  ))
  into v_return
  from jsonb_array_elements(p_stops) e(value)
  where upper(btrim(e.value->>'stop_kind'))='RETURN';

  if jsonb_typeof(p_capacity)<>'object' then
    raise exception using errcode='P0001', message='TC_TRIP_CAPACITY_OBJECT_REQUIRED';
  end if;

  begin
    v_weight:=(p_capacity->>'free_weight_kg')::numeric;
    v_volume:=(p_capacity->>'free_volume_m3')::numeric;
    v_packages:=(p_capacity->>'free_packages')::integer;
    v_cold:=coalesce((p_capacity->>'accepts_cold_chain')::boolean,false);
    v_fragile:=coalesce((p_capacity->>'accepts_fragile')::boolean,false);
    v_bulky:=coalesce((p_capacity->>'accepts_bulky')::boolean,false);
    v_rural:=coalesce((p_capacity->>'accepts_rural_cargo')::boolean,false);
  exception when others then
    raise exception using errcode='P0001', message='TC_TRIP_CAPACITY_PAYLOAD_INVALID';
  end;

  if v_weight is null or v_volume is null or v_packages is null
     or v_weight<0 or v_volume<0 or v_packages<0 then
    raise exception using errcode='P0001', message='TC_TRIP_CAPACITY_PAYLOAD_INVALID';
  end if;

  insert into public.logistics_trips(
    driver_profile_id,vehicle_id,
    origin_operational_location_id,destination_operational_location_id,
    source_type,trip_reason,state,
    planned_departure_at,planned_arrival_at,return_expected_at,
    accepted_cargo,conditions
  ) values(
    v_con,v_vehicle,
    v_origin,v_destination,
    'DRIVER_DECLARED',btrim(p_trip_reason),'DRAFT',
    v_departure,v_arrival,v_return,
    coalesce(p_accepted_cargo,'{}'::jsonb),
    coalesce(p_conditions,'{}'::jsonb)
  )
  returning id,public_id into v_trip,v_trip_public_id;

  insert into public.logistics_trip_stops(
    trip_id,stop_sequence,operational_location_id,stop_kind,
    planned_arrival_at,planned_departure_at,note
  )
  select
    v_trip,
    e.ordinality::integer,
    o.id,
    upper(btrim(e.value->>'stop_kind')),
    nullif(btrim(e.value->>'planned_arrival_at'),'')::timestamptz,
    nullif(btrim(e.value->>'planned_departure_at'),'')::timestamptz,
    nullif(btrim(coalesce(e.value->>'note','')),'')
  from jsonb_array_elements(p_stops) with ordinality e(value,ordinality)
  join public.operational_locations o
    on o.public_id=upper(btrim(e.value->>'node_public_id'))
  order by e.ordinality;

  insert into public.logistics_trip_capacity(
    trip_id,declared_free_weight_kg,declared_free_volume_m3,declared_free_packages,
    accepts_cold_chain,accepts_fragile,accepts_bulky,accepts_rural_cargo
  ) values(
    v_trip,v_weight,v_volume,v_packages,
    v_cold,v_fragile,v_bulky,v_rural
  );

  if p_publish then
    update public.logistics_trips
       set state='PUBLISHED'
     where id=v_trip;
  end if;

  select state,version into v_state,v_version
  from public.logistics_trips
  where id=v_trip;

  return jsonb_build_object(
    'trip_public_id',v_trip_public_id,
    'state',v_state,
    'version',v_version,
    'stop_count',v_stop_count,
    'published',p_publish
  );
end;
$$;

create or replace function public.tc_con_cancel_trip(
  p_con_public_id text,
  p_trip_public_id text,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_con uuid;
  v_trip public.logistics_trips%rowtype;
  v_invalidated integer:=0;
begin
  v_con:=public.tc_require_my_con_profile(p_con_public_id);

  select * into v_trip
  from public.logistics_trips t
  where t.public_id=upper(btrim(coalesce(p_trip_public_id,'')))
    and t.driver_profile_id=v_con
  for update;

  if v_trip.id is null then
    raise exception using errcode='P0001', message='TC_CON_TRIP_NOT_FOUND';
  end if;

  if v_trip.state='CANCELLED' then
    return jsonb_build_object(
      'trip_public_id',v_trip.public_id,
      'state','CANCELLED',
      'idempotent',true
    );
  end if;

  if v_trip.state not in ('DRAFT','PUBLISHED','ACCEPTING') then
    raise exception using errcode='P0001', message='TC_CON_TRIP_ALREADY_STARTED';
  end if;

  if exists(
    select 1
    from public.logistics_matches m
    join public.logistics_capacity_reservations r on r.id=m.capacity_reservation_id
    where m.trip_id=v_trip.id
      and m.state='ACCEPTED'
      and r.state in ('HELD','CONFIRMED','CONSUMED')
  ) then
    raise exception using errcode='P0001', message='TC_CON_TRIP_HAS_ACCEPTED_LOADS';
  end if;

  with changed as (
    update public.logistics_matches
       set state='INVALIDATED',
           responded_at=coalesce(responded_at,now()),
           updated_at=now()
     where trip_id=v_trip.id
       and state='OFFERED'
     returning id
  )
  select count(*) into v_invalidated from changed;

  insert into public.logistics_match_events(
    match_id,event_type,reason_code,metadata
  )
  select
    m.id,'INVALIDATED','TRIP_CANCELLED_BY_CON',
    jsonb_build_object(
      'trip_public_id',v_trip.public_id,
      'reason',nullif(btrim(coalesce(p_reason,'')),'')
    )
  from public.logistics_matches m
  where m.trip_id=v_trip.id
    and m.state='INVALIDATED'
    and not exists(
      select 1 from public.logistics_match_events e
      where e.match_id=m.id
        and e.event_type='INVALIDATED'
        and e.reason_code='TRIP_CANCELLED_BY_CON'
    );

  update public.logistics_trips
     set state='CANCELLED'
   where id=v_trip.id;

  return jsonb_build_object(
    'trip_public_id',v_trip.public_id,
    'state','CANCELLED',
    'invalidated_offer_count',v_invalidated,
    'idempotent',false
  );
end;
$$;

create or replace function public.tc_con_list_my_trips(
  p_con_public_id text,
  p_state text default null,
  p_limit integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_con uuid;
  v_state text:=nullif(upper(btrim(coalesce(p_state,''))),'');
  v_result jsonb;
begin
  v_con:=public.tc_require_my_con_profile(p_con_public_id);

  if v_state is not null and v_state not in (
    'DRAFT','PUBLISHED','ACCEPTING','DEPARTED','COMPLETED','CANCELLED'
  ) then
    raise exception using errcode='P0001', message='TC_TRIP_STATE_FILTER_INVALID';
  end if;

  if p_limit<1 or p_limit>200 then
    raise exception using errcode='P0001', message='TC_LIMIT_INVALID';
  end if;

  select coalesce(jsonb_agg(x.obj order by x.departure desc,x.public_id),'[]'::jsonb)
  into v_result
  from (
    select
      t.planned_departure_at as departure,
      t.public_id,
      jsonb_build_object(
        'trip_public_id',t.public_id,
        'state',t.state,
        'trip_reason',t.trip_reason,
        'vehicle_public_id',v.public_id,
        'planned_departure_at',t.planned_departure_at,
        'planned_arrival_at',t.planned_arrival_at,
        'return_expected_at',t.return_expected_at,
        'published_at',t.published_at,
        'capacity',jsonb_build_object(
          'free_weight_kg',c.declared_free_weight_kg,
          'free_volume_m3',c.declared_free_volume_m3,
          'free_packages',c.declared_free_packages,
          'accepts_cold_chain',c.accepts_cold_chain,
          'accepts_fragile',c.accepts_fragile,
          'accepts_bulky',c.accepts_bulky,
          'accepts_rural_cargo',c.accepts_rural_cargo
        ),
        'stops',coalesce((
          select jsonb_agg(jsonb_build_object(
            'sequence',s.stop_sequence,
            'node_public_id',o.public_id,
            'node_name',o.name,
            'stop_kind',s.stop_kind,
            'planned_arrival_at',s.planned_arrival_at,
            'planned_departure_at',s.planned_departure_at,
            'note',s.note
          ) order by s.stop_sequence)
          from public.logistics_trip_stops s
          join public.operational_locations o on o.id=s.operational_location_id
          where s.trip_id=t.id
        ),'[]'::jsonb),
        'offered_opportunity_count',(
          select count(*) from public.logistics_matches m
          where m.trip_id=t.id and m.state='OFFERED'
        ),
        'accepted_load_count',(
          select count(*) from public.logistics_matches m
          where m.trip_id=t.id and m.state='ACCEPTED'
        )
      ) as obj
    from public.logistics_trips t
    join public.vehicles v on v.id=t.vehicle_id
    left join public.logistics_trip_capacity c on c.trip_id=t.id
    where t.driver_profile_id=v_con
      and (v_state is null or t.state=v_state)
    order by t.planned_departure_at desc,t.public_id
    limit p_limit
  ) x;

  return v_result;
end;
$$;

revoke all on function public.tc_con_create_trip(text,text,text,jsonb,jsonb,jsonb,jsonb,boolean)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_con_cancel_trip(text,text,text)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_con_list_my_trips(text,text,integer)
  from public,anon,authenticated,service_role;

grant execute on function public.tc_con_create_trip(text,text,text,jsonb,jsonb,jsonb,jsonb,boolean)
  to authenticated;
grant execute on function public.tc_con_cancel_trip(text,text,text)
  to authenticated;
grant execute on function public.tc_con_list_my_trips(text,text,integer)
  to authenticated;

comment on function public.tc_con_create_trip(text,text,text,jsonb,jsonb,jsonb,jsonb,boolean) is
'Authenticated CON trip declaration. Stops are exact ordered network points the real trip will pass; no detour/radius concept is accepted.';

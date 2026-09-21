
create or replace function public.tc_con_resolve_owned_profile(
  p_con_public_id text
)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_profile uuid;
begin
  if auth.uid() is null then
    raise exception using errcode='P0001', message='TC_UNAUTHENTICATED';
  end if;

  select pr.id into v_profile
  from public.profiles pr
  join public.persons per on per.id=pr.person_id
  where per.auth_user_id=auth.uid()
    and pr.public_id=upper(btrim(coalesce(p_con_public_id,'')))
    and pr.profile_type='CON'
    and pr.status='active'
  limit 1;

  if v_profile is null then
    raise exception using errcode='P0001', message='TC_CON_PROFILE_FORBIDDEN';
  end if;

  return v_profile;
end;
$$;

revoke all on function public.tc_con_resolve_owned_profile(text)
  from public,anon,authenticated,service_role;

create or replace function public.tc_con_save_trip(
  p_con_public_id text,
  p_vehicle_public_id text,
  p_trip_reason text,
  p_planned_departure_at timestamptz,
  p_stops jsonb,
  p_capacity jsonb,
  p_trip_public_id text default null,
  p_planned_arrival_at timestamptz default null,
  p_return_expected_at timestamptz default null,
  p_accepted_cargo jsonb default '{}'::jsonb,
  p_conditions jsonb default '{}'::jsonb,
  p_publish boolean default false
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
  v_trip_public text;
  v_stop_count integer;
  v_resolved_count integer;
  v_end_count integer;
  v_origin uuid;
  v_destination uuid;
  v_first_kind text;
  v_state text;
  v_rec record;
  v_capacity_weight numeric;
  v_capacity_volume numeric;
  v_capacity_packages integer;
  v_cold boolean;
  v_fragile boolean;
  v_bulky boolean;
  v_rural boolean;
begin
  v_con:=public.tc_con_resolve_owned_profile(p_con_public_id);

  if p_planned_departure_at is null
     or nullif(btrim(coalesce(p_trip_reason,'')),'') is null then
    raise exception using errcode='P0001', message='TC_CON_TRIP_INPUT_INVALID';
  end if;

  if p_stops is null
     or jsonb_typeof(p_stops)<>'array'
     or jsonb_array_length(p_stops)<2
     or jsonb_array_length(p_stops)>50 then
    raise exception using errcode='P0001', message='TC_CON_TRIP_STOPS_INVALID';
  end if;

  if p_capacity is null or jsonb_typeof(p_capacity)<>'object' then
    raise exception using errcode='P0001', message='TC_CON_TRIP_CAPACITY_INVALID';
  end if;

  select v.id into v_vehicle
  from public.vehicles v
  join public.driver_vehicle_authorizations a
    on a.vehicle_id=v.id
   and a.driver_profile_id=v_con
  where v.public_id=upper(btrim(coalesce(p_vehicle_public_id,'')))
    and v.is_active
    and a.is_active
    and a.valid_from<=p_planned_departure_at
    and (a.valid_until is null or a.valid_until>=p_planned_departure_at);

  if v_vehicle is null then
    raise exception using errcode='P0001', message='TC_CON_VEHICLE_NOT_AUTHORIZED';
  end if;

  v_stop_count:=jsonb_array_length(p_stops);

  select upper(btrim(e.value->>'kind'))
    into v_first_kind
  from jsonb_array_elements(p_stops) with ordinality e(value,ord)
  where e.ord=1;

  if v_first_kind<>'START' then
    raise exception using errcode='P0001', message='TC_CON_TRIP_FIRST_STOP_MUST_START';
  end if;

  select count(*) into v_end_count
  from jsonb_array_elements(p_stops) e(value)
  where upper(btrim(e.value->>'kind'))='END';

  if v_end_count<>1 then
    raise exception using errcode='P0001', message='TC_CON_TRIP_ONE_END_REQUIRED';
  end if;

  if exists(
    select 1
    from jsonb_array_elements(p_stops) e(value)
    where upper(btrim(coalesce(e.value->>'kind','')))
      not in ('START','WAYPOINT','END','RETURN')
       or nullif(btrim(coalesce(e.value->>'location_public_id','')),'') is null
  ) then
    raise exception using errcode='P0001', message='TC_CON_TRIP_STOP_SHAPE_INVALID';
  end if;

  select count(*) into v_resolved_count
  from jsonb_array_elements(p_stops) e(value)
  join public.operational_locations o
    on o.public_id=upper(btrim(e.value->>'location_public_id'))
   and o.active
   and o.network_enabled;

  if v_resolved_count<>v_stop_count then
    raise exception using errcode='P0001', message='TC_CON_TRIP_STOP_NOT_NETWORK_NODE';
  end if;

  select o.id into v_origin
  from jsonb_array_elements(p_stops) with ordinality e(value,ord)
  join public.operational_locations o
    on o.public_id=upper(btrim(e.value->>'location_public_id'))
  where e.ord=1;

  select o.id into v_destination
  from jsonb_array_elements(p_stops) e(value)
  join public.operational_locations o
    on o.public_id=upper(btrim(e.value->>'location_public_id'))
  where upper(btrim(e.value->>'kind'))='END';

  if v_origin is null or v_destination is null or v_origin=v_destination then
    raise exception using errcode='P0001', message='TC_CON_TRIP_ENDPOINTS_INVALID';
  end if;

  begin
    v_capacity_weight:=(p_capacity->>'free_weight_kg')::numeric;
    v_capacity_volume:=(p_capacity->>'free_volume_m3')::numeric;
    v_capacity_packages:=(p_capacity->>'free_packages')::integer;
    v_cold:=coalesce((p_capacity->>'accepts_cold_chain')::boolean,false);
    v_fragile:=coalesce((p_capacity->>'accepts_fragile')::boolean,false);
    v_bulky:=coalesce((p_capacity->>'accepts_bulky')::boolean,false);
    v_rural:=coalesce((p_capacity->>'accepts_rural_cargo')::boolean,false);
  exception
    when invalid_text_representation or numeric_value_out_of_range then
      raise exception using errcode='P0001', message='TC_CON_TRIP_CAPACITY_INVALID';
  end;

  if v_capacity_weight is null or v_capacity_weight<0
     or v_capacity_volume is null or v_capacity_volume<0
     or v_capacity_packages is null or v_capacity_packages<0 then
    raise exception using errcode='P0001', message='TC_CON_TRIP_CAPACITY_INVALID';
  end if;

  if nullif(btrim(coalesce(p_trip_public_id,'')),'') is null then
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
      p_planned_departure_at,p_planned_arrival_at,p_return_expected_at,
      coalesce(p_accepted_cargo,'{}'::jsonb),
      coalesce(p_conditions,'{}'::jsonb)
    )
    returning id,public_id into v_trip,v_trip_public;
  else
    select t.id,t.public_id,t.state
      into v_trip,v_trip_public,v_state
    from public.logistics_trips t
    where t.public_id=upper(btrim(p_trip_public_id))
      and t.driver_profile_id=v_con
    for update;

    if v_trip is null then
      raise exception using errcode='P0001', message='TC_CON_TRIP_NOT_FOUND';
    end if;

    if v_state<>'DRAFT' then
      raise exception using errcode='P0001', message='TC_CON_TRIP_PLAN_LOCKED';
    end if;

    update public.logistics_trips
       set vehicle_id=v_vehicle,
           origin_operational_location_id=v_origin,
           destination_operational_location_id=v_destination,
           trip_reason=btrim(p_trip_reason),
           planned_departure_at=p_planned_departure_at,
           planned_arrival_at=p_planned_arrival_at,
           return_expected_at=p_return_expected_at,
           accepted_cargo=coalesce(p_accepted_cargo,'{}'::jsonb),
           conditions=coalesce(p_conditions,'{}'::jsonb),
           updated_at=now()
     where id=v_trip;

    delete from public.logistics_trip_stops
    where trip_id=v_trip;
  end if;

  for v_rec in
    select
      e.ord::integer as seq,
      upper(btrim(e.value->>'kind')) as kind,
      o.id as location_id,
      case
        when e.value ? 'planned_arrival_at'
         and nullif(e.value->>'planned_arrival_at','') is not null
        then (e.value->>'planned_arrival_at')::timestamptz
        else null
      end as arrival_at,
      case
        when e.value ? 'planned_departure_at'
         and nullif(e.value->>'planned_departure_at','') is not null
        then (e.value->>'planned_departure_at')::timestamptz
        else null
      end as departure_at,
      nullif(btrim(coalesce(e.value->>'note','')),'') as note
    from jsonb_array_elements(p_stops) with ordinality e(value,ord)
    join public.operational_locations o
      on o.public_id=upper(btrim(e.value->>'location_public_id'))
    order by e.ord
  loop
    insert into public.logistics_trip_stops(
      trip_id,stop_sequence,operational_location_id,stop_kind,
      planned_arrival_at,planned_departure_at,note
    ) values(
      v_trip,v_rec.seq,v_rec.location_id,v_rec.kind,
      case
        when v_rec.seq=v_stop_count and v_rec.kind='END'
          then coalesce(v_rec.arrival_at,p_planned_arrival_at)
        else v_rec.arrival_at
      end,
      case
        when v_rec.seq=1
          then coalesce(v_rec.departure_at,p_planned_departure_at)
        else v_rec.departure_at
      end,
      v_rec.note
    );
  end loop;

  insert into public.logistics_trip_capacity(
    trip_id,declared_free_weight_kg,declared_free_volume_m3,declared_free_packages,
    accepts_cold_chain,accepts_fragile,accepts_bulky,accepts_rural_cargo
  ) values(
    v_trip,v_capacity_weight,v_capacity_volume,v_capacity_packages,
    v_cold,v_fragile,v_bulky,v_rural
  )
  on conflict (trip_id) do update
    set declared_free_weight_kg=excluded.declared_free_weight_kg,
        declared_free_volume_m3=excluded.declared_free_volume_m3,
        declared_free_packages=excluded.declared_free_packages,
        accepts_cold_chain=excluded.accepts_cold_chain,
        accepts_fragile=excluded.accepts_fragile,
        accepts_bulky=excluded.accepts_bulky,
        accepts_rural_cargo=excluded.accepts_rural_cargo,
        updated_at=now();

  if p_publish then
    update public.logistics_trips
       set state='PUBLISHED'
     where id=v_trip;
  end if;

  select state into v_state
  from public.logistics_trips
  where id=v_trip;

  return jsonb_build_object(
    'trip_public_id',v_trip_public,
    'state',v_state,
    'stop_count',v_stop_count,
    'published',p_publish
  );
exception
  when invalid_datetime_format or datetime_field_overflow then
    raise exception using errcode='P0001', message='TC_CON_TRIP_STOP_TIME_INVALID';
end;
$$;

create or replace function public.tc_con_set_trip_state(
  p_con_public_id text,
  p_trip_public_id text,
  p_action text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_con uuid;
  v_trip public.logistics_trips%rowtype;
  v_action text:=upper(btrim(coalesce(p_action,'')));
  v_invalidated integer:=0;
begin
  v_con:=public.tc_con_resolve_owned_profile(p_con_public_id);

  select * into v_trip
  from public.logistics_trips t
  where t.public_id=upper(btrim(coalesce(p_trip_public_id,'')))
    and t.driver_profile_id=v_con
  for update;

  if v_trip.id is null then
    raise exception using errcode='P0001', message='TC_CON_TRIP_NOT_FOUND';
  end if;

  if v_action='PUBLISH' then
    if v_trip.state<>'DRAFT' then
      raise exception using errcode='P0001', message='TC_CON_TRIP_STATE_ACTION_INVALID';
    end if;
    update public.logistics_trips set state='PUBLISHED' where id=v_trip.id;

  elsif v_action='OPEN' then
    if v_trip.state<>'PUBLISHED' then
      raise exception using errcode='P0001', message='TC_CON_TRIP_STATE_ACTION_INVALID';
    end if;
    update public.logistics_trips set state='ACCEPTING' where id=v_trip.id;

  elsif v_action='CANCEL' then
    if v_trip.state not in ('DRAFT','PUBLISHED','ACCEPTING') then
      raise exception using errcode='P0001', message='TC_CON_TRIP_STATE_ACTION_INVALID';
    end if;

    if exists(
      select 1
      from public.logistics_matches m
      join public.logistics_capacity_reservations r
        on r.id=m.capacity_reservation_id
      where m.trip_id=v_trip.id
        and m.state='ACCEPTED'
        and r.state in ('HELD','CONFIRMED','CONSUMED')
    ) then
      raise exception using errcode='P0001', message='TC_CON_TRIP_HAS_ACTIVE_COMMITMENTS_USE_RECOVERY';
    end if;

    with invalidated as (
      update public.logistics_matches m
         set state='INVALIDATED',
             responded_at=now(),
             updated_at=now()
       where m.trip_id=v_trip.id
         and m.state='OFFERED'
       returning m.id
    ),
    events as (
      insert into public.logistics_match_events(
        match_id,event_type,reason_code
      )
      select id,'INVALIDATED','TRIP_CANCELLED_BY_CON'
      from invalidated
      returning match_id
    )
    select count(*) into v_invalidated from events;

    update public.logistics_trips set state='CANCELLED' where id=v_trip.id;
  else
    raise exception using errcode='P0001', message='TC_CON_TRIP_ACTION_INVALID';
  end if;

  select * into v_trip
  from public.logistics_trips where id=v_trip.id;

  return jsonb_build_object(
    'trip_public_id',v_trip.public_id,
    'state',v_trip.state,
    'invalidated_offers',v_invalidated
  );
end;
$$;

create or replace function public.tc_con_respond_opportunity(
  p_con_public_id text,
  p_match_public_id text,
  p_action text,
  p_reason_code text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_con uuid;
  v_match uuid;
begin
  v_con:=public.tc_con_resolve_owned_profile(p_con_public_id);

  select m.id into v_match
  from public.logistics_matches m
  join public.logistics_trips t on t.id=m.trip_id
  where m.public_id=upper(btrim(coalesce(p_match_public_id,'')))
    and t.driver_profile_id=v_con;

  if v_match is null then
    raise exception using errcode='P0001', message='TC_CON_OPPORTUNITY_NOT_FOUND';
  end if;

  return public.tc_respond_logistics_match(
    v_match,v_con,p_action,p_reason_code
  );
end;
$$;

create or replace function public.tc_con_workspace(
  p_con_public_id text,
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
  v_profile_public text;
  v_limit integer;
  v_vehicles jsonb;
  v_nodes jsonb;
  v_trips jsonb;
  v_opportunities jsonb;
  v_assignments jsonb;
begin
  v_con:=public.tc_con_resolve_owned_profile(p_con_public_id);
  v_limit:=least(greatest(coalesce(p_limit,50),1),100);

  select public_id into v_profile_public
  from public.profiles where id=v_con;

  select coalesce(jsonb_agg(jsonb_build_object(
    'vehicle_public_id',v.public_id,
    'plate_number',v.plate_number,
    'transport_type',v.transport_type,
    'max_weight_kg',v.max_weight_kg,
    'max_volume_m3',v.max_volume_m3,
    'max_packages',v.max_packages,
    'supports_cold_chain',v.supports_cold_chain,
    'supports_fragile',v.supports_fragile,
    'supports_bulky',v.supports_bulky,
    'supports_rural_cargo',v.supports_rural_cargo,
    'valid_from',a.valid_from,
    'valid_until',a.valid_until
  ) order by v.public_id),'[]'::jsonb)
  into v_vehicles
  from public.driver_vehicle_authorizations a
  join public.vehicles v on v.id=a.vehicle_id
  where a.driver_profile_id=v_con
    and a.is_active
    and v.is_active;

  select coalesce(jsonb_agg(x.obj order by x.name,x.public_id),'[]'::jsonb)
  into v_nodes
  from (
    select
      o.name,
      o.public_id,
      jsonb_build_object(
        'location_public_id',o.public_id,
        'name',o.name,
        'purpose',o.purpose,
        'community_id',o.community_id,
        'verification_status',o.verification_status
      ) as obj
    from public.operational_locations o
    where o.active and o.network_enabled
    order by o.name,o.public_id
    limit 200
  ) x;

  select coalesce(jsonb_agg(x.obj order by x.departure_at desc,x.public_id),'[]'::jsonb)
  into v_trips
  from (
    select
      t.public_id,
      t.planned_departure_at as departure_at,
      jsonb_build_object(
        'trip_public_id',t.public_id,
        'state',t.state,
        'vehicle_public_id',v.public_id,
        'trip_reason',t.trip_reason,
        'planned_departure_at',t.planned_departure_at,
        'planned_arrival_at',t.planned_arrival_at,
        'return_expected_at',t.return_expected_at,
        'published_at',t.published_at,
        'accepted_cargo',t.accepted_cargo,
        'conditions',t.conditions,
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
            'stop_public_id',s.public_id,
            'sequence',s.stop_sequence,
            'kind',s.stop_kind,
            'location_public_id',ol.public_id,
            'location_name',ol.name,
            'planned_arrival_at',s.planned_arrival_at,
            'planned_departure_at',s.planned_departure_at,
            'note',s.note
          ) order by s.stop_sequence)
          from public.logistics_trip_stops s
          join public.operational_locations ol on ol.id=s.operational_location_id
          where s.trip_id=t.id
        ),'[]'::jsonb)
      ) as obj
    from public.logistics_trips t
    join public.vehicles v on v.id=t.vehicle_id
    left join public.logistics_trip_capacity c on c.trip_id=t.id
    where t.driver_profile_id=v_con
    order by t.planned_departure_at desc,t.created_at desc
    limit v_limit
  ) x;

  select coalesce(jsonb_agg(x.obj order by x.offered_at,x.match_public_id),'[]'::jsonb)
  into v_opportunities
  from (
    select
      m.public_id as match_public_id,
      m.offered_at,
      jsonb_build_object(
        'match_public_id',m.public_id,
        'trip_public_id',t.public_id,
        'demand_public_id',d.public_id,
        'state',m.state,
        'commitment_mode',m.commitment_mode,
        'origin',jsonb_build_object(
          'location_public_id',oo.public_id,
          'name',oo.name
        ),
        'destination',jsonb_build_object(
          'location_public_id',od.public_id,
          'name',od.name
        ),
        'board_stop_sequence',m.board_stop_sequence,
        'alight_stop_sequence',m.alight_stop_sequence,
        'package_count',s.package_count,
        'total_weight_kg',s.total_weight_kg,
        'total_volume_m3',s.total_volume_m3,
        'requires_cold_chain',s.requires_cold_chain,
        'requires_fragile_handling',s.requires_fragile_handling,
        'required_capability_codes',to_jsonb(s.required_capability_codes),
        'earliest_ready_at',s.earliest_ready_at,
        'latest_delivery_at',s.latest_delivery_at,
        'offered_at',m.offered_at
      ) as obj
    from public.logistics_matches m
    join public.logistics_trips t on t.id=m.trip_id
    join public.logistics_demands d on d.id=m.demand_id
    join public.logistics_match_requirement_snapshots s
      on s.id=m.requirement_snapshot_id
    join public.logistics_routing_hops h on h.id=m.routing_hop_id
    join public.operational_locations oo on oo.id=h.origin_operational_location_id
    join public.operational_locations od on od.id=h.destination_operational_location_id
    where t.driver_profile_id=v_con
      and m.state='OFFERED'
    order by m.offered_at,m.public_id
    limit v_limit
  ) x;

  select coalesce(jsonb_agg(x.obj order by x.accepted_at desc,x.match_public_id),'[]'::jsonb)
  into v_assignments
  from (
    select
      m.public_id as match_public_id,
      m.responded_at as accepted_at,
      jsonb_build_object(
        'match_public_id',m.public_id,
        'trip_public_id',t.public_id,
        'demand_public_id',d.public_id,
        'accepted_at',m.responded_at,
        'movement_public_id',mv.public_id,
        'movement_state',mv.state,
        'origin',jsonb_build_object(
          'location_public_id',oo.public_id,
          'name',oo.name
        ),
        'destination',jsonb_build_object(
          'location_public_id',od.public_id,
          'name',od.name
        ),
        'board_stop_sequence',m.board_stop_sequence,
        'alight_stop_sequence',m.alight_stop_sequence,
        'expected_from_at',mv.expected_from_at,
        'expected_to_at',mv.expected_to_at,
        'package_count',(
          select count(*)
          from public.logistics_demand_packages dp
          where dp.demand_id=m.demand_id
        ),
        'package_public_ids',coalesce((
          select jsonb_agg(p.public_id order by p.public_id)
          from public.logistics_demand_packages dp
          join public.packages p on p.id=dp.package_id
          where dp.demand_id=m.demand_id
        ),'[]'::jsonb),
        'departure_phase',coalesce((
          select jsonb_build_object(
            'total',count(*),
            'planned',count(*) filter(where ch.status='PLANNED'),
            'released',count(*) filter(where ch.status='RELEASED'),
            'received',count(*) filter(where ch.status='RECEIVED')
          )
          from public.logistics_movement_custody_phases ch
          where ch.movement_id=mv.id and ch.phase='DEPARTURE'
        ),jsonb_build_object('total',0,'planned',0,'released',0,'received',0)),
        'arrival_phase',coalesce((
          select jsonb_build_object(
            'total',count(*),
            'planned',count(*) filter(where ch.status='PLANNED'),
            'released',count(*) filter(where ch.status='RELEASED'),
            'received',count(*) filter(where ch.status='RECEIVED')
          )
          from public.logistics_movement_custody_phases ch
          where ch.movement_id=mv.id and ch.phase='ARRIVAL'
        ),jsonb_build_object('total',0,'planned',0,'released',0,'received',0))
      ) as obj
    from public.logistics_matches m
    join public.logistics_trips t on t.id=m.trip_id
    join public.logistics_demands d on d.id=m.demand_id
    join public.logistics_routing_hops h on h.id=m.routing_hop_id
    join public.operational_locations oo on oo.id=h.origin_operational_location_id
    join public.operational_locations od on od.id=h.destination_operational_location_id
    left join lateral (
      select he.movement_id
      from public.logistics_hop_executions he
      where he.match_id=m.id
        and not exists(
          select 1 from public.logistics_hop_executions nx
          where nx.supersedes_hop_execution_id=he.id
        )
      order by he.created_at desc,he.id desc
      limit 1
    ) hex on true
    left join public.movements mv on mv.id=hex.movement_id
    where t.driver_profile_id=v_con
      and m.state='ACCEPTED'
    order by m.responded_at desc,m.public_id
    limit v_limit
  ) x;

  return jsonb_build_object(
    'con_profile_public_id',v_profile_public,
    'privacy_contract',jsonb_build_object(
      'recipient_name_visible',false,
      'private_address_visible',false,
      'phone_visible',false,
      'accepted_assignment_exposes_pkg_ids',true
    ),
    'vehicles',v_vehicles,
    'network_nodes',v_nodes,
    'trips',v_trips,
    'opportunities',v_opportunities,
    'assignments',v_assignments
  );
end;
$$;

revoke all on function public.tc_con_save_trip(
  text,text,text,timestamptz,jsonb,jsonb,text,timestamptz,timestamptz,jsonb,jsonb,boolean
) from public,anon;

revoke all on function public.tc_con_set_trip_state(text,text,text)
  from public,anon;
revoke all on function public.tc_con_respond_opportunity(text,text,text,text)
  from public,anon;
revoke all on function public.tc_con_workspace(text,integer)
  from public,anon;

grant execute on function public.tc_con_save_trip(
  text,text,text,timestamptz,jsonb,jsonb,text,timestamptz,timestamptz,jsonb,jsonb,boolean
) to authenticated,service_role;

grant execute on function public.tc_con_set_trip_state(text,text,text)
  to authenticated,service_role;
grant execute on function public.tc_con_respond_opportunity(text,text,text,text)
  to authenticated,service_role;
grant execute on function public.tc_con_workspace(text,integer)
  to authenticated,service_role;

comment on function public.tc_con_workspace(text,integer) is
'Authenticated CON workspace. Returns own vehicles/trips, PII-free opportunities, and accepted assignments with PKG IDs only. Never returns recipient name, private address or phone.';

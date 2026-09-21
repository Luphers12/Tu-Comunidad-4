
create or replace function public.tc_prepare_canonical_movement_custody(
  p_movement_id uuid
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_movement public.movements%rowtype;
  v_origin_owner uuid;
  v_destination_owner uuid;
  v_driver uuid;
  v_count integer;
begin
  select * into v_movement
  from public.movements m
  where m.id=p_movement_id
  for update;

  if v_movement.id is null then
    raise exception using errcode='P0001', message='TC_MOVEMENT_NOT_FOUND';
  end if;

  if v_movement.movement_type<>'NODE_TO_NODE'
     or v_movement.logistics_trip_id is null
     or v_movement.origin_operational_location_id is null
     or v_movement.destination_operational_location_id is null then
    raise exception using errcode='P0001', message='TC_CANONICAL_CUSTODY_MOVEMENT_REQUIRED';
  end if;

  select o.owner_profile_id into v_origin_owner
  from public.operational_locations o
  where o.id=v_movement.origin_operational_location_id
    and o.active and o.network_enabled;

  select o.owner_profile_id into v_destination_owner
  from public.operational_locations o
  where o.id=v_movement.destination_operational_location_id
    and o.active and o.network_enabled;

  select t.driver_profile_id into v_driver
  from public.logistics_trips t
  where t.id=v_movement.logistics_trip_id;

  if v_origin_owner is null or v_destination_owner is null or v_driver is null then
    raise exception using errcode='P0001', message='TC_CANONICAL_CUSTODY_ACTORS_REQUIRED';
  end if;

  if not exists(select 1 from public.profiles p where p.id=v_origin_owner and p.status='active')
     or not exists(select 1 from public.profiles p where p.id=v_destination_owner and p.status='active')
     or not exists(select 1 from public.profiles p where p.id=v_driver and p.status='active' and p.profile_type='CON') then
    raise exception using errcode='P0001', message='TC_CANONICAL_CUSTODY_ACTOR_INACTIVE';
  end if;

  select count(*) into v_count
  from public.movement_packages mp
  where mp.movement_id=v_movement.id;

  if v_count<1 then
    raise exception using errcode='P0001', message='TC_MOVEMENT_HAS_NO_PACKAGES';
  end if;

  insert into public.logistics_movement_custody_phases(
    movement_id,package_id,phase,from_profile_id,to_profile_id,status
  )
  select v_movement.id,mp.package_id,'DEPARTURE',v_origin_owner,v_driver,'PLANNED'
  from public.movement_packages mp
  where mp.movement_id=v_movement.id
  on conflict (movement_id,package_id,phase) do nothing;

  insert into public.logistics_movement_custody_phases(
    movement_id,package_id,phase,from_profile_id,to_profile_id,status
  )
  select v_movement.id,mp.package_id,'ARRIVAL',v_driver,v_destination_owner,'PLANNED'
  from public.movement_packages mp
  where mp.movement_id=v_movement.id
  on conflict (movement_id,package_id,phase) do nothing;

  return jsonb_build_object(
    'movement_id',v_movement.id,
    'package_count',v_count,
    'origin_owner_profile_id',v_origin_owner,
    'driver_profile_id',v_driver,
    'destination_owner_profile_id',v_destination_owner
  );
end;
$$;

create or replace function public.tc_record_canonical_load_scan(
  p_movement_id uuid,
  p_package_id uuid,
  p_actor_profile_id uuid,
  p_idempotency_key text,
  p_occurred_at timestamptz default now()
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_movement public.movements%rowtype;
  v_phase public.logistics_movement_custody_phases%rowtype;
  v_event jsonb;
  v_event_id text;
  v_scan uuid;
  v_expected integer;
  v_loaded integer;
  v_new_state text;
  v_new_version bigint;
begin
  perform public.tc_prepare_canonical_movement_custody(p_movement_id);

  select * into v_movement
  from public.movements m
  where m.id=p_movement_id
  for update;

  if v_movement.state not in ('PLANNED','READY') then
    raise exception using errcode='P0001', message='TC_LOAD_SCAN_MOVEMENT_STATE_INVALID';
  end if;

  select * into v_phase
  from public.logistics_movement_custody_phases h
  where h.movement_id=p_movement_id
    and h.package_id=p_package_id
    and h.phase='DEPARTURE';

  if v_phase.id is null then
    raise exception using errcode='P0001', message='TC_PACKAGE_NOT_IN_MOVEMENT';
  end if;

  if v_phase.from_profile_id<>p_actor_profile_id then
    raise exception using errcode='P0001', message='TC_LOAD_SCAN_ACTOR_FORBIDDEN';
  end if;

  if not exists(
    select 1 from public.packages p
    where p.id=p_package_id
      and p.current_custodian_id=p_actor_profile_id
  ) then
    raise exception using errcode='P0001', message='TC_CUSTODY_MISMATCH';
  end if;

  v_event:=public.tc_begin_internal_logistics_event(
    p_idempotency_key,'CANONICAL_LOAD_SCAN',
    p_actor_profile_id,p_movement_id,p_occurred_at,
    jsonb_build_object('package_id',p_package_id)
  );
  v_event_id:=v_event->>'event_id';

  insert into public.logistics_scan_events(
    package_id,operational_location_id,scan_type,
    trip_id,movement_id,actor_profile_id,idempotency_key,
    metadata,occurred_at
  ) values(
    p_package_id,v_movement.origin_operational_location_id,'LOAD',
    v_movement.logistics_trip_id,p_movement_id,p_actor_profile_id,p_idempotency_key,
    jsonb_build_object('event_id',v_event_id,'canonical_phase','DEPARTURE'),
    p_occurred_at
  )
  on conflict (idempotency_key) where idempotency_key is not null
  do nothing
  returning id into v_scan;

  if v_scan is null then
    select s.id into v_scan
    from public.logistics_scan_events s
    where s.idempotency_key=p_idempotency_key;
  end if;

  select count(*) into v_expected
  from public.movement_packages mp
  where mp.movement_id=p_movement_id;

  select count(distinct s.package_id) into v_loaded
  from public.logistics_scan_events s
  join public.movement_packages mp
    on mp.movement_id=s.movement_id
   and mp.package_id=s.package_id
  where s.movement_id=p_movement_id
    and s.scan_type='LOAD';

  if v_loaded=v_expected and v_expected>0 and v_movement.state='PLANNED' then
    update public.movements
       set state='READY',version=version+1
     where id=p_movement_id
     returning state,version into v_new_state,v_new_version;
  else
    select state,version into v_new_state,v_new_version
    from public.movements where id=p_movement_id;
  end if;

  perform public.tc_finish_internal_logistics_event(
    v_event_id,v_new_state,v_new_version,
    jsonb_build_object(
      'scan_event_id',v_scan,
      'loaded_count',v_loaded,
      'expected_count',v_expected
    )
  );

  return jsonb_build_object(
    'scan_event_id',v_scan,
    'event_id',v_event_id,
    'loaded_count',v_loaded,
    'expected_count',v_expected,
    'movement_state',v_new_state,
    'movement_version',v_new_version
  );
end;
$$;

create or replace function public.tc_apply_canonical_departure_release(
  p_movement_id uuid,
  p_package_ids uuid[],
  p_actor_profile_id uuid,
  p_idempotency_key text,
  p_occurred_at timestamptz default now()
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_movement public.movements%rowtype;
  v_event jsonb;
  v_event_id text;
  v_requested integer;
  v_rec record;
  v_version bigint;
begin
  perform public.tc_prepare_canonical_movement_custody(p_movement_id);

  select * into v_movement
  from public.movements m
  where m.id=p_movement_id
  for update;

  if v_movement.state not in ('READY','TRANSFER_PENDING') then
    raise exception using errcode='P0001', message='TC_DEPARTURE_RELEASE_MOVEMENT_NOT_READY';
  end if;

  if p_package_ids is null or cardinality(p_package_ids)<1 then
    raise exception using errcode='P0001', message='TC_EMPTY_EVENT_PACKAGE_SET';
  end if;

  select count(distinct x) into v_requested from unnest(p_package_ids) x;

  if (
    select count(*)
    from public.logistics_movement_custody_phases h
    where h.movement_id=p_movement_id
      and h.phase='DEPARTURE'
      and h.package_id=any(p_package_ids)
      and h.from_profile_id=p_actor_profile_id
  )<>v_requested then
    raise exception using errcode='P0001', message='TC_DEPARTURE_RELEASE_ACTOR_OR_PACKAGE_MISMATCH';
  end if;

  v_event:=public.tc_begin_internal_logistics_event(
    p_idempotency_key,'CANONICAL_DEPARTURE_RELEASE',
    p_actor_profile_id,p_movement_id,p_occurred_at,
    jsonb_build_object('package_ids',to_jsonb(p_package_ids))
  );
  v_event_id:=v_event->>'event_id';

  for v_rec in
    select h.id,h.package_id,h.status,h.release_event_id,
           h.from_profile_id
    from public.logistics_movement_custody_phases h
    where h.movement_id=p_movement_id
      and h.phase='DEPARTURE'
      and h.package_id=any(p_package_ids)
    order by h.package_id
    for update
  loop
    if not exists(
      select 1 from public.packages p
      where p.id=v_rec.package_id
        and p.current_custodian_id=v_rec.from_profile_id
    ) then
      raise exception using errcode='P0001', message='TC_CUSTODY_MISMATCH';
    end if;

    if v_rec.status='PLANNED' then
      update public.logistics_movement_custody_phases
         set status='RELEASED',
             release_event_id=v_event_id,
             release_occurred_at=p_occurred_at,
             version=version+1
       where id=v_rec.id;
    elsif v_rec.status='RELEASED' and v_rec.release_event_id=v_event_id then
      null;
    else
      raise exception using errcode='P0001', message='TC_DEPARTURE_RELEASE_INVALID_PHASE_STATE';
    end if;
  end loop;

  if v_movement.state='READY' then
    update public.movements
       set state='TRANSFER_PENDING',version=version+1
     where id=p_movement_id
     returning version into v_version;
  else
    select version into v_version from public.movements where id=p_movement_id;
  end if;

  perform public.tc_finish_internal_logistics_event(
    v_event_id,'TRANSFER_PENDING',v_version,
    jsonb_build_object('phase','DEPARTURE','action','RELEASE','package_count',v_requested)
  );

  return jsonb_build_object(
    'event_id',v_event_id,
    'processed_package_count',v_requested,
    'movement_state','TRANSFER_PENDING',
    'movement_version',v_version
  );
end;
$$;

create or replace function public.tc_apply_canonical_departure_receive(
  p_movement_id uuid,
  p_package_ids uuid[],
  p_actor_profile_id uuid,
  p_idempotency_key text,
  p_occurred_at timestamptz default now()
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_movement public.movements%rowtype;
  v_event jsonb;
  v_event_id text;
  v_requested integer;
  v_rec record;
  v_total integer;
  v_received integer;
  v_state text;
  v_version bigint;
begin
  select * into v_movement
  from public.movements m
  where m.id=p_movement_id
  for update;

  if v_movement.state<>'TRANSFER_PENDING' then
    raise exception using errcode='P0001', message='TC_DEPARTURE_RECEIVE_RELEASE_REQUIRED';
  end if;

  if p_package_ids is null or cardinality(p_package_ids)<1 then
    raise exception using errcode='P0001', message='TC_EMPTY_EVENT_PACKAGE_SET';
  end if;

  select count(distinct x) into v_requested from unnest(p_package_ids) x;

  if (
    select count(*)
    from public.logistics_movement_custody_phases h
    where h.movement_id=p_movement_id
      and h.phase='DEPARTURE'
      and h.package_id=any(p_package_ids)
      and h.to_profile_id=p_actor_profile_id
      and h.status in ('RELEASED','RECEIVED')
  )<>v_requested then
    raise exception using errcode='P0001', message='TC_DEPARTURE_RECEIVE_ACTOR_OR_RELEASE_MISMATCH';
  end if;

  v_event:=public.tc_begin_internal_logistics_event(
    p_idempotency_key,'CANONICAL_DEPARTURE_RECEIVE',
    p_actor_profile_id,p_movement_id,p_occurred_at,
    jsonb_build_object('package_ids',to_jsonb(p_package_ids))
  );
  v_event_id:=v_event->>'event_id';

  for v_rec in
    select h.id,h.package_id,h.status,h.receive_event_id,
           h.from_profile_id,h.to_profile_id,h.release_occurred_at
    from public.logistics_movement_custody_phases h
    where h.movement_id=p_movement_id
      and h.phase='DEPARTURE'
      and h.package_id=any(p_package_ids)
    order by h.package_id
    for update
  loop
    if v_rec.status='RELEASED' then
      if v_rec.release_occurred_at is not null and p_occurred_at<v_rec.release_occurred_at then
        raise exception using errcode='P0001', message='TC_RECEIVE_BEFORE_RELEASE_TIME';
      end if;

      if not exists(
        select 1 from public.packages p
        where p.id=v_rec.package_id
          and p.current_custodian_id=v_rec.from_profile_id
      ) then
        raise exception using errcode='P0001', message='TC_CUSTODY_MISMATCH';
      end if;

      update public.packages
         set current_custodian_id=v_rec.to_profile_id,
             state='IN_TRANSIT',
             version=version+1
       where id=v_rec.package_id;

      update public.logistics_movement_custody_phases
         set status='RECEIVED',
             receive_event_id=v_event_id,
             receive_occurred_at=p_occurred_at,
             version=version+1
       where id=v_rec.id;

      insert into public.custody_events(
        package_id,movement_id,from_profile_id,to_profile_id,event_id,occurred_at
      ) values(
        v_rec.package_id,p_movement_id,
        v_rec.from_profile_id,v_rec.to_profile_id,
        v_event_id,p_occurred_at
      );
    elsif v_rec.status='RECEIVED' and v_rec.receive_event_id=v_event_id then
      null;
    else
      raise exception using errcode='P0001', message='TC_DEPARTURE_RECEIVE_INVALID_PHASE_STATE';
    end if;
  end loop;

  select count(*) into v_total
  from public.logistics_movement_custody_phases h
  where h.movement_id=p_movement_id and h.phase='DEPARTURE';

  select count(*) into v_received
  from public.logistics_movement_custody_phases h
  where h.movement_id=p_movement_id and h.phase='DEPARTURE' and h.status='RECEIVED';

  if v_received=v_total and v_total>0 then
    update public.movements
       set state='IN_TRANSIT',
           departed_at=coalesce(departed_at,p_occurred_at),
           version=version+1
     where id=p_movement_id
     returning state,version into v_state,v_version;

    update public.logistics_demands d
       set state='IN_TRANSIT',version=version+1,updated_at=now()
     where d.id in (
       select md.demand_id
       from public.logistics_movement_demands md
       where md.movement_id=p_movement_id
     )
       and d.state not in ('DELIVERED','CANCELLED');

    if v_movement.board_stop_sequence=1 then
      update public.logistics_trips
         set state='DEPARTED'
       where id=v_movement.logistics_trip_id
         and state in ('PUBLISHED','ACCEPTING');
    end if;
  else
    select state,version into v_state,v_version
    from public.movements where id=p_movement_id;
  end if;

  perform public.tc_finish_internal_logistics_event(
    v_event_id,v_state,v_version,
    jsonb_build_object(
      'phase','DEPARTURE','action','RECEIVE',
      'received_count',v_received,'expected_count',v_total
    )
  );

  return jsonb_build_object(
    'event_id',v_event_id,
    'processed_package_count',v_requested,
    'received_count',v_received,
    'expected_count',v_total,
    'movement_state',v_state,
    'movement_version',v_version
  );
end;
$$;

revoke all on function public.tc_prepare_canonical_movement_custody(uuid)
  from public,anon,authenticated;
revoke all on function public.tc_record_canonical_load_scan(uuid,uuid,uuid,text,timestamptz)
  from public,anon,authenticated;
revoke all on function public.tc_apply_canonical_departure_release(uuid,uuid[],uuid,text,timestamptz)
  from public,anon,authenticated;
revoke all on function public.tc_apply_canonical_departure_receive(uuid,uuid[],uuid,text,timestamptz)
  from public,anon,authenticated;

grant execute on function public.tc_prepare_canonical_movement_custody(uuid)
  to service_role;
grant execute on function public.tc_record_canonical_load_scan(uuid,uuid,uuid,text,timestamptz)
  to service_role;
grant execute on function public.tc_apply_canonical_departure_release(uuid,uuid[],uuid,text,timestamptz)
  to service_role;
grant execute on function public.tc_apply_canonical_departure_receive(uuid,uuid[],uuid,text,timestamptz)
  to service_role;

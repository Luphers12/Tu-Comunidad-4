
create or replace function public.tc_apply_last_mile_pickup_release(
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
  v_ids uuid[];
  v_requested integer;
  v_event jsonb;
  v_event_id text;
  v_movement public.movements%rowtype;
  v_rec record;
  v_version bigint;
begin
  select array_agg(distinct x order by x),count(distinct x)
    into v_ids,v_requested
  from unnest(p_package_ids) x;

  if v_requested is null or v_requested<1 then
    raise exception using errcode='P0001', message='TC_EMPTY_EVENT_PACKAGE_SET';
  end if;

  v_event:=public.tc_internal_event_replay_or_begin(
    p_idempotency_key,'LAST_MILE_PICKUP_RELEASE',
    p_actor_profile_id,p_movement_id,p_occurred_at,
    jsonb_build_object('package_ids',to_jsonb(v_ids))
  );

  if coalesce((v_event->>'replay')::boolean,false) then
    select state,version into v_movement.state,v_version
    from public.movements where id=p_movement_id;
    return jsonb_build_object(
      'event_id',v_event->>'event_id',
      'movement_state',v_movement.state,
      'movement_version',v_version,
      'idempotent',true
    );
  end if;

  select * into v_movement
  from public.movements mv
  where mv.id=p_movement_id
  for update;

  if v_movement.id is null
     or not exists(
       select 1 from public.logistics_last_mile_assignments a
       where a.movement_id=p_movement_id and a.state='ACTIVE'
     ) then
    raise exception using errcode='P0001', message='TC_LAST_MILE_MOVEMENT_NOT_ACTIVE';
  end if;

  if v_movement.from_profile_id is distinct from p_actor_profile_id then
    raise exception using errcode='P0001', message='TC_LAST_MILE_PICKUP_RELEASE_FORBIDDEN';
  end if;

  if v_movement.state not in ('PLANNED','TRANSFER_PENDING') then
    raise exception using errcode='P0001', message='TC_LAST_MILE_PICKUP_RELEASE_STATE_INVALID';
  end if;

  if (
    select count(*)
    from public.logistics_movement_custody_phases h
    where h.movement_id=p_movement_id
      and h.phase='LAST_MILE_PICKUP'
      and h.package_id=any(v_ids)
      and h.from_profile_id=p_actor_profile_id
  )<>v_requested then
    raise exception using errcode='P0001', message='TC_PACKAGE_NOT_IN_MOVEMENT';
  end if;

  for v_rec in
    select h.id,h.package_id,h.status,h.release_event_id
    from public.logistics_movement_custody_phases h
    where h.movement_id=p_movement_id
      and h.phase='LAST_MILE_PICKUP'
      and h.package_id=any(v_ids)
    order by h.package_id
    for update
  loop
    if not exists(
      select 1 from public.packages p
      where p.id=v_rec.package_id
        and p.current_custodian_id=p_actor_profile_id
    ) then
      raise exception using errcode='P0001', message='TC_CUSTODY_MISMATCH';
    end if;

    if v_rec.status='PLANNED' then
      update public.logistics_movement_custody_phases
         set status='RELEASED',
             release_event_id=v_event->>'event_id',
             release_occurred_at=p_occurred_at,
             version=version+1
       where id=v_rec.id;
    elsif v_rec.status='RELEASED'
      and v_rec.release_event_id=v_event->>'event_id' then
      null;
    else
      raise exception using errcode='P0001', message='TC_LAST_MILE_PICKUP_RELEASE_PHASE_INVALID';
    end if;
  end loop;

  update public.movements
     set state='TRANSFER_PENDING',
         version=version+1
   where id=p_movement_id
     and state='PLANNED'
  returning version into v_version;

  if v_version is null then
    select version into v_version
    from public.movements where id=p_movement_id;
  end if;

  perform public.tc_finish_internal_logistics_event(
    v_event->>'event_id','TRANSFER_PENDING',v_version,
    jsonb_build_object('phase','LAST_MILE_PICKUP','action','RELEASE','package_count',v_requested)
  );

  return jsonb_build_object(
    'event_id',v_event->>'event_id',
    'processed_package_count',v_requested,
    'movement_state','TRANSFER_PENDING',
    'movement_version',v_version,
    'idempotent',false
  );
end;
$$;

create or replace function public.tc_apply_last_mile_pickup_receive(
  p_movement_id uuid,
  p_package_ids uuid[],
  p_rsg_profile_id uuid,
  p_idempotency_key text,
  p_occurred_at timestamptz default now()
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_ids uuid[];
  v_requested integer;
  v_event jsonb;
  v_movement public.movements%rowtype;
  v_assignment public.logistics_last_mile_assignments%rowtype;
  v_rec record;
  v_total integer;
  v_received integer;
  v_version bigint;
begin
  select array_agg(distinct x order by x),count(distinct x)
    into v_ids,v_requested
  from unnest(p_package_ids) x;

  if v_requested is null or v_requested<1 then
    raise exception using errcode='P0001', message='TC_EMPTY_EVENT_PACKAGE_SET';
  end if;

  v_event:=public.tc_internal_event_replay_or_begin(
    p_idempotency_key,'LAST_MILE_PICKUP_RECEIVE',
    p_rsg_profile_id,p_movement_id,p_occurred_at,
    jsonb_build_object('package_ids',to_jsonb(v_ids))
  );

  if coalesce((v_event->>'replay')::boolean,false) then
    select state,version into v_movement.state,v_version
    from public.movements where id=p_movement_id;
    return jsonb_build_object(
      'event_id',v_event->>'event_id',
      'movement_state',v_movement.state,
      'movement_version',v_version,
      'idempotent',true
    );
  end if;

  select * into v_assignment
  from public.logistics_last_mile_assignments a
  where a.movement_id=p_movement_id
    and a.rsg_profile_id=p_rsg_profile_id
    and a.state='ACTIVE'
  for update;

  if v_assignment.id is null then
    raise exception using errcode='P0001', message='TC_RSG_MOVEMENT_FORBIDDEN';
  end if;

  select * into v_movement
  from public.movements mv
  where mv.id=p_movement_id
  for update;

  if v_movement.state<>'TRANSFER_PENDING' then
    raise exception using errcode='P0001', message='TC_LAST_MILE_PICKUP_RELEASE_REQUIRED';
  end if;

  if (
    select count(*)
    from public.logistics_movement_custody_phases h
    where h.movement_id=p_movement_id
      and h.phase='LAST_MILE_PICKUP'
      and h.package_id=any(v_ids)
      and h.to_profile_id=p_rsg_profile_id
      and h.status in ('RELEASED','RECEIVED')
  )<>v_requested then
    raise exception using errcode='P0001', message='TC_LAST_MILE_PICKUP_PHASE_NOT_READY';
  end if;

  for v_rec in
    select h.id,h.package_id,h.status,h.from_profile_id,h.to_profile_id,
           h.release_occurred_at
    from public.logistics_movement_custody_phases h
    where h.movement_id=p_movement_id
      and h.phase='LAST_MILE_PICKUP'
      and h.package_id=any(v_ids)
    order by h.package_id
    for update
  loop
    if v_rec.status='RELEASED' then
      if v_rec.release_occurred_at is not null
         and p_occurred_at<v_rec.release_occurred_at then
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
         set current_custodian_id=p_rsg_profile_id,
             state='OUT_FOR_DELIVERY',
             version=version+1
       where id=v_rec.package_id;

      update public.logistics_movement_custody_phases
         set status='RECEIVED',
             receive_event_id=v_event->>'event_id',
             receive_occurred_at=p_occurred_at,
             version=version+1
       where id=v_rec.id;

      insert into public.custody_events(
        package_id,movement_id,from_profile_id,to_profile_id,event_id,occurred_at
      ) values(
        v_rec.package_id,p_movement_id,
        v_rec.from_profile_id,p_rsg_profile_id,
        v_event->>'event_id',p_occurred_at
      );
    end if;
  end loop;

  select count(*) into v_total
  from public.logistics_movement_custody_phases h
  where h.movement_id=p_movement_id
    and h.phase='LAST_MILE_PICKUP';

  select count(*) into v_received
  from public.logistics_movement_custody_phases h
  where h.movement_id=p_movement_id
    and h.phase='LAST_MILE_PICKUP'
    and h.status='RECEIVED';

  if v_total>0 and v_received=v_total then
    update public.movements
       set state='IN_TRANSIT',
           departed_at=coalesce(departed_at,p_occurred_at),
           version=version+1
     where id=p_movement_id
    returning version into v_version;

    update public.logistics_last_mile_tasks
       set state='OUT_FOR_DELIVERY'
     where id=v_assignment.task_id;
  else
    select version into v_version from public.movements where id=p_movement_id;
  end if;

  perform public.tc_finish_internal_logistics_event(
    v_event->>'event_id',
    case when v_received=v_total and v_total>0 then 'IN_TRANSIT' else 'TRANSFER_PENDING' end,
    v_version,
    jsonb_build_object(
      'phase','LAST_MILE_PICKUP','action','RECEIVE',
      'received_count',v_received,'expected_count',v_total
    )
  );

  return jsonb_build_object(
    'event_id',v_event->>'event_id',
    'received_count',v_received,
    'expected_count',v_total,
    'movement_state',case when v_received=v_total and v_total>0 then 'IN_TRANSIT' else 'TRANSFER_PENDING' end,
    'movement_version',v_version,
    'idempotent',false
  );
end;
$$;

create or replace function public.tc_record_last_mile_arrival_candidate(
  p_movement_id uuid,
  p_rsg_profile_id uuid,
  p_source_type text,
  p_latitude numeric,
  p_longitude numeric,
  p_idempotency_key text,
  p_occurred_at timestamptz default now()
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_source text:=upper(btrim(coalesce(p_source_type,'')));
  v_event jsonb;
  v_assignment public.logistics_last_mile_assignments%rowtype;
  v_task public.logistics_last_mile_tasks%rowtype;
  v_point extensions.geography;
  v_distance numeric;
  v_arrival uuid;
  v_public text;
  v_version bigint;
begin
  if v_source not in ('GPS','MANUAL_REFERENCE','OFFLINE_SYNC') then
    raise exception using errcode='P0001', message='TC_LAST_MILE_ARRIVAL_SOURCE_INVALID';
  end if;

  if (p_latitude is null) <> (p_longitude is null)
     or (p_latitude is not null and (p_latitude<-90 or p_latitude>90 or p_longitude<-180 or p_longitude>180)) then
    raise exception using errcode='P0001', message='TC_LAST_MILE_ARRIVAL_COORDINATES_INVALID';
  end if;

  v_event:=public.tc_internal_event_replay_or_begin(
    p_idempotency_key,'LAST_MILE_ARRIVAL_CANDIDATE',
    p_rsg_profile_id,p_movement_id,p_occurred_at,
    jsonb_build_object(
      'source_type',v_source,
      'latitude',p_latitude,
      'longitude',p_longitude
    )
  );

  if coalesce((v_event->>'replay')::boolean,false) then
    select e.id,e.public_id,e.distance_to_destination_m
      into v_arrival,v_public,v_distance
    from public.logistics_last_mile_arrival_events e
    where e.idempotency_key=p_idempotency_key;

    select version into v_version from public.movements where id=p_movement_id;

    return jsonb_build_object(
      'arrival_event_public_id',v_public,
      'distance_to_destination_m',v_distance,
      'movement_version',v_version,
      'idempotent',true
    );
  end if;

  select * into v_assignment
  from public.logistics_last_mile_assignments a
  where a.movement_id=p_movement_id
    and a.rsg_profile_id=p_rsg_profile_id
    and a.state='ACTIVE';

  if v_assignment.id is null then
    raise exception using errcode='P0001', message='TC_RSG_MOVEMENT_FORBIDDEN';
  end if;

  select * into v_task
  from public.logistics_last_mile_tasks t
  where t.id=v_assignment.task_id;

  if not exists(
    select 1 from public.movements mv
    where mv.id=p_movement_id
      and mv.state in ('IN_TRANSIT','ARRIVED')
  ) then
    raise exception using errcode='P0001', message='TC_LAST_MILE_MOVEMENT_NOT_IN_TRANSIT';
  end if;

  select pds.point into v_point
  from public.logistics_destination_versions dsv
  join public.private_destination_snapshots pds on pds.id=dsv.private_snapshot_id
  where dsv.id=v_task.destination_version_id;

  if p_latitude is not null and v_point is not null then
    v_distance:=extensions.st_distance(
      extensions.st_setsrid(extensions.st_makepoint(p_longitude,p_latitude),4326)::extensions.geography,
      v_point
    );
  end if;

  insert into public.logistics_last_mile_arrival_events(
    task_id,assignment_id,movement_id,rsg_profile_id,
    source_type,latitude,longitude,distance_to_destination_m,
    idempotency_key,metadata,occurred_at
  ) values(
    v_task.id,v_assignment.id,p_movement_id,p_rsg_profile_id,
    v_source,p_latitude,p_longitude,v_distance,
    p_idempotency_key,
    jsonb_build_object('event_id',v_event->>'event_id'),
    p_occurred_at
  )
  returning id,public_id into v_arrival,v_public;

  update public.movements
     set state='ARRIVED',
         arrived_at=coalesce(arrived_at,p_occurred_at),
         version=version+1
   where id=p_movement_id
     and state='IN_TRANSIT'
  returning version into v_version;

  if v_version is null then
    select version into v_version from public.movements where id=p_movement_id;
  end if;

  perform public.tc_finish_internal_logistics_event(
    v_event->>'event_id','ARRIVED',v_version,
    jsonb_build_object(
      'arrival_event_id',v_arrival,
      'distance_to_destination_m',v_distance,
      'delivery_completed',false
    )
  );

  return jsonb_build_object(
    'arrival_event_public_id',v_public,
    'distance_to_destination_m',v_distance,
    'movement_state','ARRIVED',
    'movement_version',v_version,
    'delivery_completed',false,
    'idempotent',false
  );
end;
$$;

create or replace function public.tc_apply_last_mile_delivery_confirmation(
  p_movement_id uuid,
  p_package_ids uuid[],
  p_rsg_profile_id uuid,
  p_evidence_public_ids text[],
  p_idempotency_key text,
  p_occurred_at timestamptz default now()
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_ids uuid[];
  v_requested integer;
  v_event jsonb;
  v_assignment public.logistics_last_mile_assignments%rowtype;
  v_movement public.movements%rowtype;
  v_rec record;
  v_total integer;
  v_delivered integer;
  v_version bigint;
  v_evidence_ids text[];
begin
  select array_agg(distinct x order by x),count(distinct x)
    into v_ids,v_requested
  from unnest(p_package_ids) x;

  select array_agg(distinct upper(btrim(x)) order by upper(btrim(x)))
    into v_evidence_ids
  from unnest(p_evidence_public_ids) x
  where nullif(btrim(x),'') is not null;

  if v_requested is null or v_requested<1
     or v_evidence_ids is null
     or cardinality(v_evidence_ids)<1 then
    raise exception using errcode='P0001', message='TC_LAST_MILE_DELIVERY_EVIDENCE_REQUIRED';
  end if;

  v_event:=public.tc_internal_event_replay_or_begin(
    p_idempotency_key,'LAST_MILE_DELIVERY_CONFIRMED',
    p_rsg_profile_id,p_movement_id,p_occurred_at,
    jsonb_build_object(
      'package_ids',to_jsonb(v_ids),
      'evidence_public_ids',to_jsonb(v_evidence_ids)
    )
  );

  if coalesce((v_event->>'replay')::boolean,false) then
    select state,version into v_movement.state,v_version
    from public.movements where id=p_movement_id;

    return jsonb_build_object(
      'event_id',v_event->>'event_id',
      'movement_state',v_movement.state,
      'movement_version',v_version,
      'idempotent',true
    );
  end if;

  select * into v_assignment
  from public.logistics_last_mile_assignments a
  where a.movement_id=p_movement_id
    and a.rsg_profile_id=p_rsg_profile_id
    and a.state='ACTIVE'
  for update;

  if v_assignment.id is null then
    raise exception using errcode='P0001', message='TC_RSG_MOVEMENT_FORBIDDEN';
  end if;

  select * into v_movement
  from public.movements mv
  where mv.id=p_movement_id
  for update;

  if v_movement.state not in ('IN_TRANSIT','ARRIVED') then
    raise exception using errcode='P0001', message='TC_LAST_MILE_DELIVERY_STATE_INVALID';
  end if;

  if (
    select count(*)
    from public.logistics_movement_custody_phases h
    where h.movement_id=p_movement_id
      and h.phase='LAST_MILE_DELIVERY'
      and h.package_id=any(v_ids)
      and h.from_profile_id=p_rsg_profile_id
  )<>v_requested then
    raise exception using errcode='P0001', message='TC_PACKAGE_NOT_IN_MOVEMENT';
  end if;

  if exists(
    select 1
    from unnest(v_ids) p(package_id)
    where not exists(
      select 1
      from public.evidence e
      where e.package_id=p.package_id
        and e.movement_id=p_movement_id
        and e.uploader_profile_id=p_rsg_profile_id
        and e.evidence_type in ('LAST_MILE_DELIVERY_PHOTO','LAST_MILE_SIGNATURE_IMAGE')
        and e.status in ('UPLOADED','VERIFIED','RETAINED')
        and e.public_id=any(v_evidence_ids)
    )
  ) then
    raise exception using errcode='P0001', message='TC_LAST_MILE_PACKAGE_EVIDENCE_MISSING';
  end if;

  for v_rec in
    select h.id,h.package_id,h.status,h.from_profile_id,h.to_profile_id
    from public.logistics_movement_custody_phases h
    where h.movement_id=p_movement_id
      and h.phase='LAST_MILE_DELIVERY'
      and h.package_id=any(v_ids)
    order by h.package_id
    for update
  loop
    if v_rec.status='PLANNED' then
      if not exists(
        select 1 from public.packages p
        where p.id=v_rec.package_id
          and p.current_custodian_id=p_rsg_profile_id
      ) then
        raise exception using errcode='P0001', message='TC_CUSTODY_MISMATCH';
      end if;

      update public.packages
         set current_custodian_id=v_rec.to_profile_id,
             state='DELIVERED',
             version=version+1
       where id=v_rec.package_id;

      update public.logistics_movement_custody_phases
         set status='RECEIVED',
             release_event_id=v_event->>'event_id',
             receive_event_id=v_event->>'event_id',
             release_occurred_at=p_occurred_at,
             receive_occurred_at=p_occurred_at,
             version=version+1
       where id=v_rec.id;

      insert into public.custody_events(
        package_id,movement_id,from_profile_id,to_profile_id,event_id,occurred_at
      ) values(
        v_rec.package_id,p_movement_id,
        p_rsg_profile_id,v_rec.to_profile_id,
        v_event->>'event_id',p_occurred_at
      );
    end if;
  end loop;

  select count(*) into v_total
  from public.logistics_movement_custody_phases h
  where h.movement_id=p_movement_id
    and h.phase='LAST_MILE_DELIVERY';

  select count(*) into v_delivered
  from public.logistics_movement_custody_phases h
  where h.movement_id=p_movement_id
    and h.phase='LAST_MILE_DELIVERY'
    and h.status='RECEIVED';

  if v_total>0 and v_delivered=v_total then
    update public.movements
       set state='COMPLETED',
           arrived_at=coalesce(arrived_at,p_occurred_at),
           completed_at=coalesce(completed_at,p_occurred_at),
           version=version+1
     where id=p_movement_id
    returning version into v_version;

    update public.logistics_last_mile_tasks
       set state='DELIVERED'
     where id=v_assignment.task_id;

    update public.logistics_last_mile_assignments
       set state='COMPLETED',
           updated_at=now()
     where id=v_assignment.id;

    update public.logistics_rsg_capacity_reservations
       set state='CONSUMED',
           updated_at=now()
     where id=v_assignment.capacity_reservation_id
       and state='CONFIRMED';
  else
    select version into v_version from public.movements where id=p_movement_id;
  end if;

  perform public.tc_finish_internal_logistics_event(
    v_event->>'event_id',
    case when v_delivered=v_total and v_total>0 then 'COMPLETED' else v_movement.state end,
    v_version,
    jsonb_build_object(
      'phase','LAST_MILE_DELIVERY',
      'delivered_count',v_delivered,
      'expected_count',v_total,
      'evidence_public_ids',to_jsonb(v_evidence_ids)
    )
  );

  return jsonb_build_object(
    'event_id',v_event->>'event_id',
    'delivered_count',v_delivered,
    'expected_count',v_total,
    'movement_state',case when v_delivered=v_total and v_total>0 then 'COMPLETED' else v_movement.state end,
    'movement_version',v_version,
    'idempotent',false
  );
end;
$$;

revoke all on function public.tc_apply_last_mile_pickup_release(uuid,uuid[],uuid,text,timestamptz)
  from public,anon,authenticated;
revoke all on function public.tc_apply_last_mile_pickup_receive(uuid,uuid[],uuid,text,timestamptz)
  from public,anon,authenticated;
revoke all on function public.tc_record_last_mile_arrival_candidate(uuid,uuid,text,numeric,numeric,text,timestamptz)
  from public,anon,authenticated;
revoke all on function public.tc_apply_last_mile_delivery_confirmation(uuid,uuid[],uuid,text[],text,timestamptz)
  from public,anon,authenticated;

grant execute on function public.tc_apply_last_mile_pickup_release(uuid,uuid[],uuid,text,timestamptz)
  to service_role;
grant execute on function public.tc_apply_last_mile_pickup_receive(uuid,uuid[],uuid,text,timestamptz)
  to service_role;
grant execute on function public.tc_record_last_mile_arrival_candidate(uuid,uuid,text,numeric,numeric,text,timestamptz)
  to service_role;
grant execute on function public.tc_apply_last_mile_delivery_confirmation(uuid,uuid[],uuid,text[],text,timestamptz)
  to service_role;

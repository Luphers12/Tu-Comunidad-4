
create or replace function public.tc_record_canonical_arrival_scan(
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
  v_driver uuid;
  v_destination_owner uuid;
  v_expected boolean;
  v_event jsonb;
  v_event_id text;
  v_scan uuid;
  v_expected_count integer;
  v_arrived_count integer;
  v_state text;
  v_version bigint;
begin
  select * into v_movement
  from public.movements m
  where m.id=p_movement_id
  for update;

  if v_movement.state not in ('IN_TRANSIT','ARRIVED') then
    raise exception using errcode='P0001', message='TC_ARRIVAL_SCAN_MOVEMENT_STATE_INVALID';
  end if;

  select t.driver_profile_id into v_driver
  from public.logistics_trips t
  where t.id=v_movement.logistics_trip_id;

  select o.owner_profile_id into v_destination_owner
  from public.operational_locations o
  where o.id=v_movement.destination_operational_location_id;

  if p_actor_profile_id is distinct from v_driver
     and p_actor_profile_id is distinct from v_destination_owner then
    raise exception using errcode='P0001', message='TC_ARRIVAL_SCAN_ACTOR_FORBIDDEN';
  end if;

  select exists(
    select 1 from public.movement_packages mp
    where mp.movement_id=p_movement_id and mp.package_id=p_package_id
  ) into v_expected;

  v_event:=public.tc_begin_internal_logistics_event(
    p_idempotency_key,
    case when v_expected then 'CANONICAL_ARRIVAL_SCAN' else 'CANONICAL_ARRIVAL_UNEXPECTED_SCAN' end,
    p_actor_profile_id,p_movement_id,p_occurred_at,
    jsonb_build_object('package_id',p_package_id,'expected',v_expected)
  );
  v_event_id:=v_event->>'event_id';

  insert into public.logistics_scan_events(
    package_id,operational_location_id,scan_type,
    trip_id,movement_id,actor_profile_id,idempotency_key,
    metadata,occurred_at
  ) values(
    p_package_id,v_movement.destination_operational_location_id,
    case when v_expected then 'ARRIVAL' else 'EXCEPTION' end,
    v_movement.logistics_trip_id,p_movement_id,p_actor_profile_id,p_idempotency_key,
    jsonb_build_object(
      'event_id',v_event_id,
      'canonical_phase','ARRIVAL',
      'expected_in_movement',v_expected
    ),
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

  select count(*) into v_expected_count
  from public.movement_packages mp
  where mp.movement_id=p_movement_id;

  select count(distinct s.package_id) into v_arrived_count
  from public.logistics_scan_events s
  join public.movement_packages mp
    on mp.movement_id=s.movement_id
   and mp.package_id=s.package_id
  where s.movement_id=p_movement_id
    and s.scan_type='ARRIVAL';

  if v_expected
     and v_arrived_count=v_expected_count
     and v_expected_count>0
     and v_movement.state='IN_TRANSIT' then
    update public.movements
       set state='ARRIVED',
           arrived_at=coalesce(arrived_at,p_occurred_at),
           version=version+1
     where id=p_movement_id
     returning state,version into v_state,v_version;
  else
    select state,version into v_state,v_version
    from public.movements where id=p_movement_id;
  end if;

  perform public.tc_finish_internal_logistics_event(
    v_event_id,v_state,v_version,
    jsonb_build_object(
      'scan_event_id',v_scan,
      'expected',v_expected,
      'arrived_expected_count',v_arrived_count,
      'expected_count',v_expected_count
    )
  );

  return jsonb_build_object(
    'scan_event_id',v_scan,
    'event_id',v_event_id,
    'expected',v_expected,
    'arrived_expected_count',v_arrived_count,
    'expected_count',v_expected_count,
    'movement_state',v_state,
    'movement_version',v_version
  );
end;
$$;

create or replace function public.tc_reconcile_canonical_movement_arrival(
  p_movement_id uuid,
  p_actor_profile_id uuid default null
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_movement public.movements%rowtype;
  v_manifest uuid;
  v_run_no bigint;
  v_run uuid;
  v_expected integer;
  v_observed integer;
  v_missing integer;
  v_unexpected integer;
  v_status text;
  v_actor_person uuid;
begin
  select * into v_movement
  from public.movements m
  where m.id=p_movement_id
  for update;

  if v_movement.id is null then
    raise exception using errcode='P0001', message='TC_MOVEMENT_NOT_FOUND';
  end if;

  if v_movement.state not in ('IN_TRANSIT','ARRIVED','TRANSFER_PENDING') then
    raise exception using errcode='P0001', message='TC_RECONCILIATION_MOVEMENT_STATE_INVALID';
  end if;

  select m.id into v_manifest
  from public.logistics_manifests m
  where m.trip_id=v_movement.logistics_trip_id
    and exists(
      select 1
      from public.logistics_manifest_segments s
      where s.manifest_id=m.id
        and s.movement_id=p_movement_id
    )
  order by m.version_no desc
  limit 1;

  if v_manifest is null then
    raise exception using errcode='P0001', message='TC_RECONCILIATION_MANIFEST_REQUIRED';
  end if;

  if p_actor_profile_id is not null then
    select p.person_id into v_actor_person
    from public.profiles p
    where p.id=p_actor_profile_id and p.status='active';

    if v_actor_person is null then
      raise exception using errcode='P0001', message='TC_RECONCILIATION_ACTOR_INVALID';
    end if;
  end if;

  select coalesce(max(r.run_no),0)+1 into v_run_no
  from public.logistics_movement_reconciliation_runs r
  where r.movement_id=p_movement_id
    and r.manifest_id=v_manifest;

  select count(*) into v_expected
  from public.movement_packages mp
  where mp.movement_id=p_movement_id;

  select count(distinct s.package_id) into v_observed
  from public.logistics_scan_events s
  join public.movement_packages mp
    on mp.movement_id=s.movement_id
   and mp.package_id=s.package_id
  where s.movement_id=p_movement_id
    and s.scan_type='ARRIVAL';

  v_missing:=greatest(v_expected-v_observed,0);

  select count(distinct s.package_id) into v_unexpected
  from public.logistics_scan_events s
  where s.movement_id=p_movement_id
    and s.scan_type='EXCEPTION'
    and coalesce((s.metadata->>'expected_in_movement')::boolean,false)=false;

  v_status:=case when v_missing=0 and v_unexpected=0 then 'MATCHED' else 'MISMATCH' end;

  insert into public.logistics_movement_reconciliation_runs(
    movement_id,manifest_id,run_no,status,
    expected_count,observed_expected_count,missing_count,unexpected_count
  ) values(
    p_movement_id,v_manifest,v_run_no,v_status,
    v_expected,v_observed,v_missing,v_unexpected
  ) returning id into v_run;

  insert into public.logistics_reconciliation_events(
    manifest_id,package_id,event_type,
    observed_operational_location_id,movement_id,
    note,metadata,actor_person_id
  )
  select
    v_manifest,mp.package_id,'OBSERVED_PRESENT',
    v_movement.destination_operational_location_id,p_movement_id,
    'Arrival scan matched expected movement package',
    jsonb_build_object('reconciliation_run_id',v_run),
    v_actor_person
  from public.movement_packages mp
  where mp.movement_id=p_movement_id
    and exists(
      select 1 from public.logistics_scan_events s
      where s.movement_id=p_movement_id
        and s.package_id=mp.package_id
        and s.scan_type='ARRIVAL'
    );

  insert into public.logistics_reconciliation_events(
    manifest_id,package_id,event_type,
    observed_operational_location_id,movement_id,
    note,metadata,actor_person_id
  )
  select
    v_manifest,mp.package_id,'EXPECTED_MISSING',
    v_movement.destination_operational_location_id,p_movement_id,
    'Expected movement package has no ARRIVAL scan',
    jsonb_build_object('reconciliation_run_id',v_run),
    v_actor_person
  from public.movement_packages mp
  where mp.movement_id=p_movement_id
    and not exists(
      select 1 from public.logistics_scan_events s
      where s.movement_id=p_movement_id
        and s.package_id=mp.package_id
        and s.scan_type='ARRIVAL'
    );

  insert into public.logistics_reconciliation_events(
    manifest_id,package_id,event_type,
    observed_operational_location_id,movement_id,
    note,metadata,actor_person_id
  )
  select
    v_manifest,s.package_id,'UNEXPECTED_PRESENT',
    v_movement.destination_operational_location_id,p_movement_id,
    'Scanned package was not expected in movement',
    jsonb_build_object('reconciliation_run_id',v_run,'scan_event_id',s.id),
    v_actor_person
  from public.logistics_scan_events s
  where s.movement_id=p_movement_id
    and s.scan_type='EXCEPTION'
    and coalesce((s.metadata->>'expected_in_movement')::boolean,false)=false;

  return v_run;
end;
$$;

create or replace function public.tc_apply_canonical_arrival_release(
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
  v_latest_status text;
  v_version bigint;
begin
  select * into v_movement
  from public.movements m
  where m.id=p_movement_id
  for update;

  if v_movement.state not in ('ARRIVED','TRANSFER_PENDING') then
    raise exception using errcode='P0001', message='TC_ARRIVAL_RELEASE_MOVEMENT_NOT_ARRIVED';
  end if;

  select r.status into v_latest_status
  from public.logistics_movement_reconciliation_runs r
  where r.movement_id=p_movement_id
  order by r.created_at desc,r.run_no desc
  limit 1;

  if v_latest_status is distinct from 'MATCHED' then
    raise exception using errcode='P0001', message='TC_ARRIVAL_RECONCILIATION_REQUIRED';
  end if;

  if p_package_ids is null or cardinality(p_package_ids)<1 then
    raise exception using errcode='P0001', message='TC_EMPTY_EVENT_PACKAGE_SET';
  end if;

  select count(distinct x) into v_requested from unnest(p_package_ids) x;

  if (
    select count(*)
    from public.logistics_movement_custody_phases h
    where h.movement_id=p_movement_id
      and h.phase='ARRIVAL'
      and h.package_id=any(p_package_ids)
      and h.from_profile_id=p_actor_profile_id
  )<>v_requested then
    raise exception using errcode='P0001', message='TC_ARRIVAL_RELEASE_ACTOR_OR_PACKAGE_MISMATCH';
  end if;

  v_event:=public.tc_begin_internal_logistics_event(
    p_idempotency_key,'CANONICAL_ARRIVAL_RELEASE',
    p_actor_profile_id,p_movement_id,p_occurred_at,
    jsonb_build_object('package_ids',to_jsonb(p_package_ids))
  );
  v_event_id:=v_event->>'event_id';

  for v_rec in
    select h.id,h.package_id,h.status,h.release_event_id,h.from_profile_id
    from public.logistics_movement_custody_phases h
    where h.movement_id=p_movement_id
      and h.phase='ARRIVAL'
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
      raise exception using errcode='P0001', message='TC_ARRIVAL_RELEASE_INVALID_PHASE_STATE';
    end if;
  end loop;

  if v_movement.state='ARRIVED' then
    update public.movements
       set state='TRANSFER_PENDING',version=version+1
     where id=p_movement_id
     returning version into v_version;
  else
    select version into v_version from public.movements where id=p_movement_id;
  end if;

  perform public.tc_finish_internal_logistics_event(
    v_event_id,'TRANSFER_PENDING',v_version,
    jsonb_build_object('phase','ARRIVAL','action','RELEASE','package_count',v_requested)
  );

  return jsonb_build_object(
    'event_id',v_event_id,
    'processed_package_count',v_requested,
    'movement_state','TRANSFER_PENDING',
    'movement_version',v_version
  );
end;
$$;

create or replace function public.tc_apply_canonical_arrival_receive(
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
  v_version bigint;
  v_profile_type text;
  v_package_state text;
  v_next_movements jsonb;
begin
  select * into v_movement
  from public.movements m
  where m.id=p_movement_id
  for update;

  if v_movement.state<>'TRANSFER_PENDING' then
    raise exception using errcode='P0001', message='TC_ARRIVAL_RECEIVE_RELEASE_REQUIRED';
  end if;

  if p_package_ids is null or cardinality(p_package_ids)<1 then
    raise exception using errcode='P0001', message='TC_EMPTY_EVENT_PACKAGE_SET';
  end if;

  select p.profile_type into v_profile_type
  from public.profiles p
  where p.id=p_actor_profile_id and p.status='active';

  if v_profile_type is null then
    raise exception using errcode='P0001', message='TC_RECEIVER_PROFILE_INACTIVE';
  end if;

  v_package_state:=case v_profile_type
    when 'PTC' then 'AT_PTC'
    when 'TIE' then 'READY'
    when 'VEN' then 'READY'
    when 'RSG' then 'OUT_FOR_DELIVERY'
    else 'READY'
  end;

  select count(distinct x) into v_requested from unnest(p_package_ids) x;

  if (
    select count(*)
    from public.logistics_movement_custody_phases h
    where h.movement_id=p_movement_id
      and h.phase='ARRIVAL'
      and h.package_id=any(p_package_ids)
      and h.to_profile_id=p_actor_profile_id
      and h.status in ('RELEASED','RECEIVED')
  )<>v_requested then
    raise exception using errcode='P0001', message='TC_ARRIVAL_RECEIVE_ACTOR_OR_RELEASE_MISMATCH';
  end if;

  v_event:=public.tc_begin_internal_logistics_event(
    p_idempotency_key,'CANONICAL_ARRIVAL_RECEIVE',
    p_actor_profile_id,p_movement_id,p_occurred_at,
    jsonb_build_object('package_ids',to_jsonb(p_package_ids))
  );
  v_event_id:=v_event->>'event_id';

  for v_rec in
    select h.id,h.package_id,h.status,h.receive_event_id,
           h.from_profile_id,h.to_profile_id,h.release_occurred_at
    from public.logistics_movement_custody_phases h
    where h.movement_id=p_movement_id
      and h.phase='ARRIVAL'
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
             state=v_package_state,
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
      raise exception using errcode='P0001', message='TC_ARRIVAL_RECEIVE_INVALID_PHASE_STATE';
    end if;
  end loop;

  select count(*) into v_total
  from public.logistics_movement_custody_phases h
  where h.movement_id=p_movement_id and h.phase='ARRIVAL';

  select count(*) into v_received
  from public.logistics_movement_custody_phases h
  where h.movement_id=p_movement_id and h.phase='ARRIVAL' and h.status='RECEIVED';

  if v_received=v_total and v_total>0 then
    update public.movements
       set state='COMPLETED',
           completed_at=coalesce(completed_at,p_occurred_at),
           version=version+1
     where id=p_movement_id
     returning version into v_version;

    update public.logistics_capacity_reservations r
       set state='CONSUMED',updated_at=now()
     where r.id in (
       select md.capacity_reservation_id
       from public.logistics_movement_demands md
       where md.movement_id=p_movement_id
     )
       and r.state='CONFIRMED';

    update public.logistics_execution_plans ep
       set state='COMPLETED',updated_at=now()
     where ep.id in (
       select he.execution_plan_id
       from public.logistics_hop_executions he
       where he.movement_id=p_movement_id
         and not exists(
           select 1
           from public.logistics_hop_executions he2
           join public.movements m2 on m2.id=he2.movement_id
           where he2.execution_plan_id=he.execution_plan_id
             and he2.id<>he.id
             and m2.state<>'COMPLETED'
         )
     );

    update public.logistics_demands d
       set state=case
           when exists(
             select 1
             from public.logistics_execution_plans ep
             where ep.demand_id=d.id and ep.state='COMPLETED'
           ) then 'DELIVERED'
           else 'IN_TRANSIT'
         end,
         version=version+1,
         updated_at=now()
     where d.id in (
       select md.demand_id
       from public.logistics_movement_demands md
       where md.movement_id=p_movement_id
     )
       and d.state not in ('DELIVERED','CANCELLED');

    select coalesce(jsonb_agg(jsonb_build_object(
      'execution_plan_id',ep.id,
      'movement_id',m2.id,
      'movement_public_id',m2.public_id,
      'hop_sequence',h2.hop_sequence,
      'origin_operational_location_id',m2.origin_operational_location_id,
      'destination_operational_location_id',m2.destination_operational_location_id
    ) order by h2.hop_sequence),'[]'::jsonb)
    into v_next_movements
    from public.logistics_hop_executions he
    join public.logistics_execution_plans ep on ep.id=he.execution_plan_id
    join public.logistics_routing_hops h on h.id=he.routing_hop_id
    join public.logistics_hop_executions he2
      on he2.execution_plan_id=he.execution_plan_id
    join public.logistics_routing_hops h2
      on h2.id=he2.routing_hop_id
     and h2.hop_sequence=h.hop_sequence+1
    join public.movements m2 on m2.id=he2.movement_id
    where he.movement_id=p_movement_id;
  else
    select version into v_version from public.movements where id=p_movement_id;
    v_next_movements:='[]'::jsonb;
  end if;

  perform public.tc_finish_internal_logistics_event(
    v_event_id,
    case when v_received=v_total and v_total>0 then 'COMPLETED' else 'TRANSFER_PENDING' end,
    v_version,
    jsonb_build_object(
      'phase','ARRIVAL','action','RECEIVE',
      'received_count',v_received,'expected_count',v_total,
      'next_movements',v_next_movements
    )
  );

  return jsonb_build_object(
    'event_id',v_event_id,
    'processed_package_count',v_requested,
    'received_count',v_received,
    'expected_count',v_total,
    'movement_state',case when v_received=v_total and v_total>0 then 'COMPLETED' else 'TRANSFER_PENDING' end,
    'movement_version',v_version,
    'next_movements',v_next_movements
  );
end;
$$;

revoke all on function public.tc_record_canonical_arrival_scan(uuid,uuid,uuid,text,timestamptz)
  from public,anon,authenticated;
revoke all on function public.tc_reconcile_canonical_movement_arrival(uuid,uuid)
  from public,anon,authenticated;
revoke all on function public.tc_apply_canonical_arrival_release(uuid,uuid[],uuid,text,timestamptz)
  from public,anon,authenticated;
revoke all on function public.tc_apply_canonical_arrival_receive(uuid,uuid[],uuid,text,timestamptz)
  from public,anon,authenticated;

grant execute on function public.tc_record_canonical_arrival_scan(uuid,uuid,uuid,text,timestamptz)
  to service_role;
grant execute on function public.tc_reconcile_canonical_movement_arrival(uuid,uuid)
  to service_role;
grant execute on function public.tc_apply_canonical_arrival_release(uuid,uuid[],uuid,text,timestamptz)
  to service_role;
grant execute on function public.tc_apply_canonical_arrival_receive(uuid,uuid[],uuid,text,timestamptz)
  to service_role;

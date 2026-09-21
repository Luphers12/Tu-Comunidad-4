
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
  v_case uuid;
  v_case_key text;
  v_case_created boolean := false;
  v_latest_case_event text;
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
    and coalesce((s.metadata->>'expected_in_movement')::boolean,false)=false
    and not exists(
      select 1
      from public.logistics_reconciliation_resolutions rr
      where rr.scan_event_id=s.id
    );

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
    and coalesce((s.metadata->>'expected_in_movement')::boolean,false)=false
    and not exists(
      select 1
      from public.logistics_reconciliation_resolutions rr
      where rr.scan_event_id=s.id
    );

  v_case_key:='ARRIVAL_MISMATCH:'||p_movement_id::text||':'||v_manifest::text;

  if v_status='MISMATCH' then
    insert into public.logistics_recovery_cases(
      case_key,case_type,movement_id,manifest_id
    ) values(
      v_case_key,'ARRIVAL_MISMATCH',p_movement_id,v_manifest
    )
    on conflict (case_key) do nothing
    returning id into v_case;

    if v_case is not null then
      v_case_created:=true;
      insert into public.logistics_recovery_events(
        recovery_case_id,event_type,reason_code,metadata,actor_profile_id
      ) values(
        v_case,'OPENED','ARRIVAL_MISMATCH',
        jsonb_build_object(
          'reconciliation_run_id',v_run,
          'missing_count',v_missing,
          'unexpected_count',v_unexpected
        ),
        p_actor_profile_id
      );
    else
      select id into v_case
      from public.logistics_recovery_cases
      where case_key=v_case_key;
    end if;

    if not v_case_created then
      insert into public.logistics_recovery_events(
        recovery_case_id,event_type,reason_code,metadata,actor_profile_id
      ) values(
        v_case,'NOTE','ARRIVAL_MISMATCH_RECHECK',
        jsonb_build_object(
          'reconciliation_run_id',v_run,
          'missing_count',v_missing,
          'unexpected_count',v_unexpected
        ),
        p_actor_profile_id
      );
    end if;
  else
    select id into v_case
    from public.logistics_recovery_cases
    where case_key=v_case_key;

    if v_case is not null then
      select e.event_type into v_latest_case_event
      from public.logistics_recovery_events e
      where e.recovery_case_id=v_case
      order by e.occurred_at desc,e.created_at desc,e.id desc
      limit 1;

      if v_latest_case_event is distinct from 'CLOSED' then
        insert into public.logistics_recovery_events(
          recovery_case_id,event_type,reason_code,metadata,actor_profile_id
        ) values(
          v_case,'CLOSED','RECONCILIATION_MATCHED',
          jsonb_build_object('reconciliation_run_id',v_run),
          p_actor_profile_id
        );
      end if;
    end if;
  end if;

  return v_run;
end;
$$;

create or replace function public.tc_resolve_unexpected_arrival_scan(
  p_scan_event_id uuid,
  p_actor_profile_id uuid,
  p_resolution_type text,
  p_note text default null
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_type text:=upper(btrim(coalesce(p_resolution_type,'')));
  v_scan public.logistics_scan_events%rowtype;
  v_movement public.movements%rowtype;
  v_driver uuid;
  v_owner uuid;
  v_manifest uuid;
  v_case uuid;
  v_case_key text;
  v_resolution uuid;
begin
  if v_type not in (
    'REMOVED_FROM_FLOW',
    'IDENTIFIED_OTHER_FLOW',
    'AUTHORIZED_FALSE_POSITIVE'
  ) then
    raise exception using errcode='P0001', message='TC_RECONCILIATION_RESOLUTION_TYPE_INVALID';
  end if;

  select * into v_scan
  from public.logistics_scan_events s
  where s.id=p_scan_event_id
  for update;

  if v_scan.id is null
     or v_scan.scan_type<>'EXCEPTION'
     or coalesce((v_scan.metadata->>'expected_in_movement')::boolean,true)<>false
     or v_scan.movement_id is null then
    raise exception using errcode='P0001', message='TC_UNEXPECTED_ARRIVAL_SCAN_REQUIRED';
  end if;

  select * into v_movement
  from public.movements m
  where m.id=v_scan.movement_id;

  select t.driver_profile_id into v_driver
  from public.logistics_trips t
  where t.id=v_movement.logistics_trip_id;

  select o.owner_profile_id into v_owner
  from public.operational_locations o
  where o.id=v_movement.destination_operational_location_id;

  if p_actor_profile_id is distinct from v_driver
     and p_actor_profile_id is distinct from v_owner then
    raise exception using errcode='P0001', message='TC_RECONCILIATION_RESOLUTION_ACTOR_FORBIDDEN';
  end if;

  select m.id into v_manifest
  from public.logistics_manifests m
  where m.trip_id=v_movement.logistics_trip_id
    and exists(
      select 1
      from public.logistics_manifest_segments s
      where s.manifest_id=m.id
        and s.movement_id=v_movement.id
    )
  order by m.version_no desc
  limit 1;

  if v_manifest is null then
    raise exception using errcode='P0001', message='TC_RECONCILIATION_MANIFEST_REQUIRED';
  end if;

  v_case_key:='ARRIVAL_MISMATCH:'||v_movement.id::text||':'||v_manifest::text;

  insert into public.logistics_recovery_cases(
    case_key,case_type,movement_id,manifest_id
  ) values(
    v_case_key,'ARRIVAL_MISMATCH',v_movement.id,v_manifest
  )
  on conflict (case_key) do nothing
  returning id into v_case;

  if v_case is null then
    select id into v_case
    from public.logistics_recovery_cases
    where case_key=v_case_key;
  else
    insert into public.logistics_recovery_events(
      recovery_case_id,event_type,reason_code,actor_profile_id,
      metadata
    ) values(
      v_case,'OPENED','ARRIVAL_MISMATCH',p_actor_profile_id,
      jsonb_build_object('source','UNEXPECTED_SCAN_RESOLUTION')
    );
  end if;

  insert into public.logistics_reconciliation_resolutions(
    recovery_case_id,scan_event_id,resolution_type,
    actor_profile_id,note
  ) values(
    v_case,v_scan.id,v_type,p_actor_profile_id,
    nullif(btrim(coalesce(p_note,'')),'')
  ) returning id into v_resolution;

  insert into public.logistics_recovery_events(
    recovery_case_id,event_type,reason_code,actor_profile_id,
    metadata
  ) values(
    v_case,'OBSERVATION_RESOLVED',v_type,p_actor_profile_id,
    jsonb_build_object(
      'scan_event_id',v_scan.id,
      'resolution_id',v_resolution
    )
  );

  return v_resolution;
end;
$$;

revoke all on function public.tc_reconcile_canonical_movement_arrival(uuid,uuid)
  from public,anon,authenticated;
revoke all on function public.tc_resolve_unexpected_arrival_scan(uuid,uuid,text,text)
  from public,anon,authenticated;

grant execute on function public.tc_reconcile_canonical_movement_arrival(uuid,uuid)
  to service_role;
grant execute on function public.tc_resolve_unexpected_arrival_scan(uuid,uuid,text,text)
  to service_role;

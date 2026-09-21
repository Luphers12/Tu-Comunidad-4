
create or replace function public.tc_node_scan_arrival(
  p_node_public_id text,
  p_movement_public_id text,
  p_package_public_id text,
  p_idempotency_key text,
  p_occurred_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_node uuid;
  v_actor uuid;
  v_movement uuid;
  v_package uuid;
  v_result jsonb;
  v_scan_public text;
begin
  v_node:=public.tc_require_my_operational_node(
    p_node_public_id,'RECEIVE_CARGO'
  );
  v_actor:=public.tc_active_profile_id();

  if nullif(btrim(coalesce(p_idempotency_key,'')),'') is null then
    raise exception using errcode='P0001', message='TC_NODE_IDEMPOTENCY_KEY_REQUIRED';
  end if;

  select mv.id into v_movement
  from public.movements mv
  where mv.public_id=upper(btrim(coalesce(p_movement_public_id,'')))
    and mv.destination_operational_location_id=v_node
    and mv.logistics_trip_id is not null
    and mv.state in ('IN_TRANSIT','ARRIVED');

  if v_movement is null then
    raise exception using errcode='P0001', message='TC_NODE_INBOUND_MOVEMENT_NOT_FOUND';
  end if;

  select p.id into v_package
  from public.packages p
  where p.public_id=upper(btrim(coalesce(p_package_public_id,'')));

  if v_package is null then
    raise exception using errcode='P0001', message='TC_PACKAGE_NOT_FOUND';
  end if;

  v_result:=public.tc_record_canonical_arrival_scan(
    v_movement,v_package,v_actor,p_idempotency_key,p_occurred_at
  );

  select s.public_id into v_scan_public
  from public.logistics_scan_events s
  where s.id=(v_result->>'scan_event_id')::uuid;

  return (v_result-'scan_event_id')||jsonb_build_object(
    'scan_event_public_id',v_scan_public,
    'movement_public_id',upper(btrim(p_movement_public_id)),
    'package_public_id',upper(btrim(p_package_public_id))
  );
end;
$$;

create or replace function public.tc_node_reconcile_arrival(
  p_node_public_id text,
  p_movement_public_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_node uuid;
  v_actor uuid;
  v_movement uuid;
  v_run uuid;
  v_row public.logistics_movement_reconciliation_runs%rowtype;
begin
  v_node:=public.tc_require_my_operational_node(
    p_node_public_id,'RECEIVE_CARGO'
  );
  v_actor:=public.tc_active_profile_id();

  select mv.id into v_movement
  from public.movements mv
  where mv.public_id=upper(btrim(coalesce(p_movement_public_id,'')))
    and mv.destination_operational_location_id=v_node
    and mv.logistics_trip_id is not null
    and mv.state in ('IN_TRANSIT','ARRIVED','TRANSFER_PENDING');

  if v_movement is null then
    raise exception using errcode='P0001', message='TC_NODE_INBOUND_MOVEMENT_NOT_FOUND';
  end if;

  v_run:=public.tc_reconcile_canonical_movement_arrival(
    v_movement,v_actor
  );

  select * into v_row
  from public.logistics_movement_reconciliation_runs r
  where r.id=v_run;

  return jsonb_build_object(
    'reconciliation_run_public_id',v_row.public_id,
    'status',v_row.status,
    'run_no',v_row.run_no,
    'expected_count',v_row.expected_count,
    'observed_expected_count',v_row.observed_expected_count,
    'missing_count',v_row.missing_count,
    'unexpected_count',v_row.unexpected_count
  );
end;
$$;

create or replace function public.tc_node_receive_custody(
  p_node_public_id text,
  p_movement_public_id text,
  p_package_public_ids text[],
  p_idempotency_key text,
  p_occurred_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_node uuid;
  v_actor uuid;
  v_movement uuid;
  v_ids uuid[];
  v_requested integer;
  v_resolved integer;
begin
  v_node:=public.tc_require_my_operational_node(
    p_node_public_id,'RECEIVE_CARGO'
  );
  v_actor:=public.tc_active_profile_id();

  if nullif(btrim(coalesce(p_idempotency_key,'')),'') is null then
    raise exception using errcode='P0001', message='TC_NODE_IDEMPOTENCY_KEY_REQUIRED';
  end if;

  select mv.id into v_movement
  from public.movements mv
  where mv.public_id=upper(btrim(coalesce(p_movement_public_id,'')))
    and mv.destination_operational_location_id=v_node
    and mv.logistics_trip_id is not null
    and mv.state in ('ARRIVED','TRANSFER_PENDING');

  if v_movement is null then
    raise exception using errcode='P0001', message='TC_NODE_INBOUND_MOVEMENT_NOT_READY';
  end if;

  select count(distinct upper(btrim(x))) into v_requested
  from unnest(p_package_public_ids) x
  where nullif(btrim(x),'') is not null;

  select array_agg(p.id order by p.public_id),count(*)
    into v_ids,v_resolved
  from public.packages p
  join public.movement_packages mp
    on mp.package_id=p.id
   and mp.movement_id=v_movement
  where p.public_id in (
    select distinct upper(btrim(x))
    from unnest(p_package_public_ids) x
    where nullif(btrim(x),'') is not null
  );

  if v_requested is null or v_requested<1 or v_resolved<>v_requested then
    raise exception using errcode='P0001', message='TC_PACKAGE_NOT_IN_MOVEMENT';
  end if;

  return public.tc_apply_canonical_arrival_receive(
    v_movement,v_ids,v_actor,p_idempotency_key,p_occurred_at
  );
end;
$$;

create or replace function public.tc_node_scan_load(
  p_node_public_id text,
  p_movement_public_id text,
  p_package_public_id text,
  p_idempotency_key text,
  p_occurred_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_node uuid;
  v_actor uuid;
  v_movement uuid;
  v_package uuid;
  v_result jsonb;
  v_scan_public text;
begin
  v_node:=public.tc_require_my_operational_node(
    p_node_public_id,'HANDOFF_CARGO'
  );
  v_actor:=public.tc_active_profile_id();

  if nullif(btrim(coalesce(p_idempotency_key,'')),'') is null then
    raise exception using errcode='P0001', message='TC_NODE_IDEMPOTENCY_KEY_REQUIRED';
  end if;

  select mv.id into v_movement
  from public.movements mv
  where mv.public_id=upper(btrim(coalesce(p_movement_public_id,'')))
    and mv.origin_operational_location_id=v_node
    and mv.logistics_trip_id is not null
    and mv.state in ('PLANNED','READY');

  if v_movement is null then
    raise exception using errcode='P0001', message='TC_NODE_OUTBOUND_MOVEMENT_NOT_FOUND';
  end if;

  select p.id into v_package
  from public.packages p
  join public.movement_packages mp
    on mp.package_id=p.id
   and mp.movement_id=v_movement
  where p.public_id=upper(btrim(coalesce(p_package_public_id,'')))
    and p.current_custodian_id=v_actor;

  if v_package is null then
    raise exception using errcode='P0001', message='TC_NODE_PACKAGE_NOT_READY_FOR_LOAD';
  end if;

  v_result:=public.tc_record_canonical_load_scan(
    v_movement,v_package,v_actor,p_idempotency_key,p_occurred_at
  );

  select s.public_id into v_scan_public
  from public.logistics_scan_events s
  where s.id=(v_result->>'scan_event_id')::uuid;

  return (v_result-'scan_event_id')||jsonb_build_object(
    'scan_event_public_id',v_scan_public,
    'movement_public_id',upper(btrim(p_movement_public_id)),
    'package_public_id',upper(btrim(p_package_public_id))
  );
end;
$$;

create or replace function public.tc_node_sort_package(
  p_node_public_id text,
  p_package_public_id text,
  p_actual_next_node_public_id text,
  p_idempotency_key text,
  p_device_ref text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_node uuid;
  v_actor uuid;
  v_package public.packages%rowtype;
  v_actual_next uuid;
  v_actual_next_public text;
  v_he public.logistics_hop_executions%rowtype;
  v_hop public.logistics_routing_hops%rowtype;
  v_he_id uuid;
  v_hop_id uuid;
  v_candidate_count integer;
  v_manifest uuid;
  v_existing_scan public.logistics_scan_events%rowtype;
  v_existing_sort public.logistics_sort_events%rowtype;
  v_result jsonb;
  v_scan uuid;
  v_sort uuid;
  v_scan_public text;
  v_sort_public text;
  v_expected_public text;
begin
  v_node:=public.tc_require_my_operational_node(
    p_node_public_id,'SORT_CARGO'
  );
  v_actor:=public.tc_active_profile_id();

  if nullif(btrim(coalesce(p_idempotency_key,'')),'') is null then
    raise exception using errcode='P0001', message='TC_NODE_IDEMPOTENCY_KEY_REQUIRED';
  end if;

  select * into v_package
  from public.packages p
  where p.public_id=upper(btrim(coalesce(p_package_public_id,'')))
  for update;

  if v_package.id is null then
    raise exception using errcode='P0001', message='TC_PACKAGE_NOT_FOUND';
  end if;

  if v_package.current_custodian_id is distinct from v_actor then
    raise exception using errcode='P0001', message='TC_NODE_PACKAGE_NOT_IN_CUSTODY';
  end if;

  select o.id,o.public_id
    into v_actual_next,v_actual_next_public
  from public.operational_locations o
  where o.public_id=upper(btrim(coalesce(p_actual_next_node_public_id,'')))
    and o.active
    and o.network_enabled;

  if v_actual_next is null then
    raise exception using errcode='P0001', message='TC_NODE_NEXT_NODE_NOT_FOUND';
  end if;

  select s.* into v_existing_scan
  from public.logistics_scan_events s
  where s.idempotency_key=p_idempotency_key;

  if v_existing_scan.id is not null then
    if v_existing_scan.package_id is distinct from v_package.id
       or v_existing_scan.operational_location_id is distinct from v_node
       or v_existing_scan.scan_type<>'SORT' then
      raise exception using errcode='P0001', message='TC_NODE_IDEMPOTENCY_KEY_REUSED';
    end if;

    select se.* into v_existing_sort
    from public.logistics_sort_events se
    where se.scan_event_id=v_existing_scan.id;

    select o.public_id into v_expected_public
    from public.operational_locations o
    where o.id=v_existing_sort.expected_next_operational_location_id;

    return jsonb_build_object(
      'scan_event_public_id',v_existing_scan.public_id,
      'sort_event_public_id',v_existing_sort.public_id,
      'result',v_existing_sort.result,
      'reason_code',v_existing_sort.reason_code,
      'expected_next_node_public_id',v_expected_public,
      'actual_next_node_public_id',v_actual_next_public,
      'idempotent',true
    );
  end if;

  select count(*) into v_candidate_count
  from public.logistics_hop_executions he
  join public.logistics_execution_plans ep on ep.id=he.execution_plan_id
  join public.logistics_routing_hops h on h.id=he.routing_hop_id
  join public.logistics_demand_packages dp on dp.demand_id=ep.demand_id
  join public.movements mv on mv.id=he.movement_id
  where dp.package_id=v_package.id
    and ep.state='ACTIVE'
    and h.origin_operational_location_id=v_node
    and mv.state in ('PLANNED','READY','TRANSFER_PENDING')
    and not exists(
      select 1
      from public.logistics_hop_executions newer
      where newer.supersedes_hop_execution_id=he.id
    );

  if v_candidate_count=0 then
    raise exception using errcode='P0001', message='TC_NODE_SORT_NO_OUTGOING_HOP';
  elsif v_candidate_count>1 then
    raise exception using errcode='P0001', message='TC_NODE_SORT_AMBIGUOUS';
  end if;

  select he.id,h.id
    into v_he_id,v_hop_id
  from public.logistics_hop_executions he
  join public.logistics_execution_plans ep on ep.id=he.execution_plan_id
  join public.logistics_routing_hops h on h.id=he.routing_hop_id
  join public.logistics_demand_packages dp on dp.demand_id=ep.demand_id
  join public.movements mv on mv.id=he.movement_id
  where dp.package_id=v_package.id
    and ep.state='ACTIVE'
    and h.origin_operational_location_id=v_node
    and mv.state in ('PLANNED','READY','TRANSFER_PENDING')
    and not exists(
      select 1
      from public.logistics_hop_executions newer
      where newer.supersedes_hop_execution_id=he.id
    )
  limit 1;

  select * into v_he
  from public.logistics_hop_executions he
  where he.id=v_he_id;

  select * into v_hop
  from public.logistics_routing_hops h
  where h.id=v_hop_id;

  select m.id into v_manifest
  from public.logistics_manifests m
  where m.trip_id=(
    select mv.logistics_trip_id
    from public.movements mv
    where mv.id=v_he.movement_id
  )
    and exists(
      select 1
      from public.logistics_manifest_segments s
      where s.manifest_id=m.id
        and s.movement_id=v_he.movement_id
        and s.package_id=v_package.id
    )
  order by m.version_no desc,m.id desc
  limit 1;

  v_result:=public.tc_record_logistics_sort_scan(
    v_package.id,
    v_hop.routing_attempt_id,
    v_hop.hop_sequence,
    v_node,
    v_actual_next,
    v_actor,
    p_device_ref,
    coalesce(p_metadata,'{}'::jsonb)||jsonb_build_object(
      'node_operation',true,
      'movement_id',v_he.movement_id
    )
  );

  v_scan:=(v_result->>'scan_event_id')::uuid;
  v_sort:=(v_result->>'sort_event_id')::uuid;

  update public.logistics_scan_events
     set idempotency_key=p_idempotency_key,
         movement_id=v_he.movement_id,
         manifest_id=v_manifest
   where id=v_scan;

  select s.public_id into v_scan_public
  from public.logistics_scan_events s where s.id=v_scan;

  select se.public_id into v_sort_public
  from public.logistics_sort_events se where se.id=v_sort;

  select o.public_id into v_expected_public
  from public.operational_locations o
  where o.id=v_hop.destination_operational_location_id;

  return jsonb_build_object(
    'scan_event_public_id',v_scan_public,
    'sort_event_public_id',v_sort_public,
    'result',v_result->>'result',
    'reason_code',v_result->>'reason_code',
    'expected_next_node_public_id',v_expected_public,
    'actual_next_node_public_id',v_actual_next_public,
    'movement_public_id',(
      select mv.public_id from public.movements mv where mv.id=v_he.movement_id
    ),
    'routing_hop_public_id',v_hop.public_id,
    'idempotent',false
  );
end;
$$;

create or replace function public.tc_node_release_to_con(
  p_node_public_id text,
  p_movement_public_id text,
  p_package_public_ids text[],
  p_idempotency_key text,
  p_occurred_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_node uuid;
  v_actor uuid;
  v_movement uuid;
  v_ids uuid[];
  v_requested integer;
  v_resolved integer;
  v_sort_required boolean;
  v_missing_sort integer;
begin
  v_node:=public.tc_require_my_operational_node(
    p_node_public_id,'HANDOFF_CARGO'
  );
  v_actor:=public.tc_active_profile_id();

  if nullif(btrim(coalesce(p_idempotency_key,'')),'') is null then
    raise exception using errcode='P0001', message='TC_NODE_IDEMPOTENCY_KEY_REQUIRED';
  end if;

  select mv.id into v_movement
  from public.movements mv
  where mv.public_id=upper(btrim(coalesce(p_movement_public_id,'')))
    and mv.origin_operational_location_id=v_node
    and mv.logistics_trip_id is not null
    and mv.state in ('READY','TRANSFER_PENDING');

  if v_movement is null then
    raise exception using errcode='P0001', message='TC_NODE_OUTBOUND_MOVEMENT_NOT_READY';
  end if;

  select count(distinct upper(btrim(x))) into v_requested
  from unnest(p_package_public_ids) x
  where nullif(btrim(x),'') is not null;

  select array_agg(p.id order by p.public_id),count(*)
    into v_ids,v_resolved
  from public.packages p
  join public.movement_packages mp
    on mp.package_id=p.id
   and mp.movement_id=v_movement
  where p.public_id in (
    select distinct upper(btrim(x))
    from unnest(p_package_public_ids) x
    where nullif(btrim(x),'') is not null
  )
    and p.current_custodian_id=v_actor;

  if v_requested is null or v_requested<1 or v_resolved<>v_requested then
    raise exception using errcode='P0001', message='TC_NODE_PACKAGE_NOT_READY_FOR_RELEASE';
  end if;

  select exists(
    select 1
    from public.operational_location_capabilities olc
    join public.logistics_capability_catalog c on c.id=olc.capability_id
    where olc.operational_location_id=v_node
      and olc.status='ENABLED'
      and c.active
      and c.code='SORT_CARGO'
  ) into v_sort_required;

  if v_sort_required then
    select count(*) into v_missing_sort
    from unnest(v_ids) p(package_id)
    where not exists(
      select 1
      from public.logistics_hop_executions he
      join public.logistics_execution_plans ep on ep.id=he.execution_plan_id
      join public.logistics_routing_hops h on h.id=he.routing_hop_id
      join public.logistics_demand_packages dp on dp.demand_id=ep.demand_id
      join public.logistics_sort_events se on se.routing_hop_id=h.id
      join public.logistics_scan_events sc
        on sc.id=se.scan_event_id
       and sc.package_id=p.package_id
      where he.movement_id=v_movement
        and dp.package_id=p.package_id
        and h.origin_operational_location_id=v_node
        and se.result='CORRECT_ROUTE'
        and se.actual_next_operational_location_id=h.destination_operational_location_id
        and not exists(
          select 1
          from public.logistics_hop_executions newer
          where newer.supersedes_hop_execution_id=he.id
        )
    );

    if v_missing_sort>0 then
      raise exception using errcode='P0001', message='TC_NODE_SORT_REQUIRED';
    end if;
  end if;

  return public.tc_apply_canonical_departure_release(
    v_movement,v_ids,v_actor,p_idempotency_key,p_occurred_at
  );
end;
$$;

revoke all on function public.tc_node_scan_arrival(text,text,text,text,timestamptz)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_node_reconcile_arrival(text,text)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_node_receive_custody(text,text,text[],text,timestamptz)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_node_scan_load(text,text,text,text,timestamptz)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_node_sort_package(text,text,text,text,text,jsonb)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_node_release_to_con(text,text,text[],text,timestamptz)
  from public,anon,authenticated,service_role;

grant execute on function public.tc_node_scan_arrival(text,text,text,text,timestamptz)
  to authenticated;
grant execute on function public.tc_node_reconcile_arrival(text,text)
  to authenticated;
grant execute on function public.tc_node_receive_custody(text,text,text[],text,timestamptz)
  to authenticated;
grant execute on function public.tc_node_scan_load(text,text,text,text,timestamptz)
  to authenticated;
grant execute on function public.tc_node_sort_package(text,text,text,text,text,jsonb)
  to authenticated;
grant execute on function public.tc_node_release_to_con(text,text,text[],text,timestamptz)
  to authenticated;

comment on function public.tc_node_scan_arrival(text,text,text,text,timestamptz) is
'Active exact NODE-owner arrival scan. Unexpected physical PKG is preserved as EXCEPTION evidence instead of being silently rejected.';
comment on function public.tc_node_release_to_con(text,text,text[],text,timestamptz) is
'Active exact NODE-owner custody release to canonical CON movement. If SORT_CARGO is enabled at the NODE, every released PKG must have a CORRECT_ROUTE sort for its effective outgoing HOP.';

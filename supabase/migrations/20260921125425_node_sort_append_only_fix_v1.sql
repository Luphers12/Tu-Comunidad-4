
create or replace function public.tc_record_node_sort_scan_once(
  p_package_id uuid,
  p_routing_attempt_id uuid,
  p_hop_sequence integer,
  p_current_operational_location_id uuid,
  p_actual_next_operational_location_id uuid,
  p_movement_id uuid,
  p_manifest_id uuid,
  p_actor_profile_id uuid,
  p_idempotency_key text,
  p_device_ref text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_hop public.logistics_routing_hops%rowtype;
  v_demand uuid;
  v_scan uuid;
  v_sort uuid;
  v_result text;
  v_reason text;
  v_existing public.logistics_scan_events%rowtype;
  v_existing_sort public.logistics_sort_events%rowtype;
begin
  if nullif(btrim(coalesce(p_idempotency_key,'')),'') is null then
    raise exception using errcode='P0001', message='TC_NODE_IDEMPOTENCY_KEY_REQUIRED';
  end if;

  select * into v_existing
  from public.logistics_scan_events s
  where s.idempotency_key=p_idempotency_key;

  if v_existing.id is not null then
    if v_existing.package_id is distinct from p_package_id
       or v_existing.operational_location_id is distinct from p_current_operational_location_id
       or v_existing.scan_type<>'SORT'
       or v_existing.movement_id is distinct from p_movement_id
       or v_existing.manifest_id is distinct from p_manifest_id then
      raise exception using errcode='P0001', message='TC_NODE_IDEMPOTENCY_KEY_REUSED';
    end if;

    select * into v_existing_sort
    from public.logistics_sort_events se
    where se.scan_event_id=v_existing.id;

    if v_existing_sort.id is null then
      raise exception using errcode='P0001', message='TC_NODE_SORT_IDEMPOTENCY_INCOMPLETE';
    end if;

    return jsonb_build_object(
      'scan_event_id',v_existing.id,
      'sort_event_id',v_existing_sort.id,
      'result',v_existing_sort.result,
      'reason_code',v_existing_sort.reason_code,
      'expected_next_operational_location_id',v_existing_sort.expected_next_operational_location_id,
      'actual_next_operational_location_id',v_existing_sort.actual_next_operational_location_id,
      'idempotent',true
    );
  end if;

  select h.* into v_hop
  from public.logistics_routing_hops h
  where h.routing_attempt_id=p_routing_attempt_id
    and h.hop_sequence=p_hop_sequence;

  if v_hop.id is null then
    raise exception using errcode='P0001', message='TC_SORT_HOP_NOT_FOUND';
  end if;

  select a.demand_id into v_demand
  from public.logistics_routing_attempts a
  where a.id=p_routing_attempt_id;

  if not exists(
    select 1
    from public.logistics_demand_packages dp
    where dp.demand_id=v_demand
      and dp.package_id=p_package_id
  ) then
    v_result:='PACKAGE_NOT_IN_DEMAND';
    v_reason:='PACKAGE_NOT_IN_DEMAND';
  elsif v_hop.origin_operational_location_id is distinct from p_current_operational_location_id then
    v_result:='HOP_MISMATCH';
    v_reason:='CURRENT_NODE_DOES_NOT_MATCH_HOP_ORIGIN';
  elsif v_hop.destination_operational_location_id is distinct from p_actual_next_operational_location_id then
    v_result:='WRONG_DESTINATION';
    v_reason:='TORO_EN_CORRAL_DESTINATION_MISMATCH';
  else
    v_result:='CORRECT_ROUTE';
    v_reason:=null;
  end if;

  insert into public.logistics_scan_events(
    package_id,operational_location_id,scan_type,
    routing_attempt_id,routing_hop_id,trip_id,
    movement_id,manifest_id,actor_profile_id,
    device_ref,metadata,idempotency_key
  ) values(
    p_package_id,p_current_operational_location_id,'SORT',
    p_routing_attempt_id,v_hop.id,v_hop.selected_trip_id,
    p_movement_id,p_manifest_id,p_actor_profile_id,
    nullif(btrim(coalesce(p_device_ref,'')),''),
    coalesce(p_metadata,'{}'::jsonb),
    p_idempotency_key
  )
  returning id into v_scan;

  insert into public.logistics_sort_events(
    scan_event_id,routing_attempt_id,routing_hop_id,
    expected_next_operational_location_id,
    actual_next_operational_location_id,
    result,reason_code
  ) values(
    v_scan,p_routing_attempt_id,v_hop.id,
    v_hop.destination_operational_location_id,
    p_actual_next_operational_location_id,
    v_result,v_reason
  )
  returning id into v_sort;

  return jsonb_build_object(
    'scan_event_id',v_scan,
    'sort_event_id',v_sort,
    'result',v_result,
    'reason_code',v_reason,
    'expected_next_operational_location_id',v_hop.destination_operational_location_id,
    'actual_next_operational_location_id',p_actual_next_operational_location_id,
    'idempotent',false
  );
end;
$$;

revoke all on function public.tc_record_node_sort_scan_once(
  uuid,uuid,integer,uuid,uuid,uuid,uuid,uuid,text,text,jsonb
) from public,anon,authenticated,service_role;

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

  if v_manifest is null then
    raise exception using errcode='P0001', message='TC_NODE_SORT_MANIFEST_REQUIRED';
  end if;

  v_result:=public.tc_record_node_sort_scan_once(
    v_package.id,
    v_hop.routing_attempt_id,
    v_hop.hop_sequence,
    v_node,
    v_actual_next,
    v_he.movement_id,
    v_manifest,
    v_actor,
    p_idempotency_key,
    p_device_ref,
    coalesce(p_metadata,'{}'::jsonb)||jsonb_build_object(
      'node_operation',true
    )
  );

  v_scan:=(v_result->>'scan_event_id')::uuid;
  v_sort:=(v_result->>'sort_event_id')::uuid;

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
    'idempotent',coalesce((v_result->>'idempotent')::boolean,false)
  );
end;
$$;

revoke all on function public.tc_node_sort_package(text,text,text,text,text,jsonb)
  from public,anon,authenticated,service_role;
grant execute on function public.tc_node_sort_package(text,text,text,text,text,jsonb)
  to authenticated;

comment on function public.tc_record_node_sort_scan_once(
  uuid,uuid,integer,uuid,uuid,uuid,uuid,uuid,text,text,jsonb
) is
'Append-only node sort writer. Scan event is born complete with idempotency, movement and manifest references; no post-insert mutation is required.';

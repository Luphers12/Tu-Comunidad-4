
-- TU COMUNIDAD — CLIENT ORDER LOGISTICS BRIDGE UUID SELECTION FIX V1

create or replace function public.tc_ensure_client_order_destination_contract(
  p_order_id uuid
)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_order public.orders%rowtype;
  v_ptc_profile uuid;
  v_node uuid;
  v_node_count integer;
  v_version uuid;
begin
  select * into v_order
  from public.orders o
  where o.id=p_order_id
  for update;

  if v_order.id is null then
    raise exception using errcode='P0001', message='TC_ORDER_NOT_FOUND';
  end if;

  if v_order.destination_contract_id is not null then
    if not exists(
      select 1
      from public.logistics_destination_versions dv
      where dv.id=v_order.destination_contract_id
    ) then
      raise exception using errcode='P0001', message='TC_ORDER_DESTINATION_CONTRACT_INVALID';
    end if;
    return v_order.destination_contract_id;
  end if;

  if upper(btrim(coalesce(v_order.destination_type,'')))='HOME' then
    raise exception using errcode='P0001', message='TC_HOME_DESTINATION_CONTRACT_REQUIRED';
  end if;

  if upper(btrim(coalesce(v_order.destination_type,'')))<>'PTC' then
    raise exception using errcode='P0001', message='TC_CLIENT_DESTINATION_CONTRACT_UNSUPPORTED';
  end if;

  select p.id into v_ptc_profile
  from public.profiles p
  where p.public_id=upper(btrim(coalesce(v_order.destination_id,'')))
    and p.profile_type='PTC'
    and p.status='active'
  limit 1;

  if v_ptc_profile is null then
    raise exception using errcode='P0001', message='TC_PTC_DESTINATION_PROFILE_INVALID';
  end if;

  select count(*)::int
    into v_node_count
  from public.operational_locations o
  where o.owner_profile_id=v_ptc_profile
    and o.purpose='PTC_PICKUP'
    and o.active
    and o.network_enabled
    and o.verification_status='VERIFIED';

  if v_node_count=0 then
    raise exception using errcode='P0001', message='TC_PTC_DESTINATION_NODE_REQUIRED';
  end if;
  if v_node_count>1 then
    raise exception using errcode='P0001', message='TC_PTC_DESTINATION_NODE_AMBIGUOUS';
  end if;

  select o.id into v_node
  from public.operational_locations o
  where o.owner_profile_id=v_ptc_profile
    and o.purpose='PTC_PICKUP'
    and o.active
    and o.network_enabled
    and o.verification_status='VERIFIED'
  order by o.public_id
  limit 1;

  v_version:=public.tc_ensure_operational_node_destination_version(v_node);

  update public.orders
     set destination_contract_id=v_version,
         updated_at=now()
   where id=v_order.id
     and destination_contract_id is null;

  select destination_contract_id into v_version
  from public.orders
  where id=v_order.id;

  return v_version;
end;
$function$;


create or replace function public.tc_materialize_client_order_logistics_demand(
  p_package_id uuid
)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_pkg public.packages%rowtype;
  v_sub public.sub_orders%rowtype;
  v_order public.orders%rowtype;
  v_store public.profiles%rowtype;
  v_origin_node uuid;
  v_origin_count integer;
  v_origin_version uuid;
  v_destination_version uuid;
  v_existing_count integer;
  v_existing_demand uuid;
  v_demand uuid;
begin
  if p_package_id is null then
    raise exception using errcode='P0001', message='TC_PACKAGE_REQUIRED';
  end if;

  perform pg_advisory_xact_lock(hashtext('TC_CLIENT_ORDER_LGD|'||p_package_id::text));

  select * into v_pkg
  from public.packages p
  where p.id=p_package_id
  for update;

  if v_pkg.id is null then
    raise exception using errcode='P0001', message='TC_PACKAGE_NOT_FOUND';
  end if;

  if v_pkg.state<>'READY' then
    raise exception using errcode='P0001', message='TC_PACKAGE_NOT_READY_FOR_LOGISTICS';
  end if;

  select * into v_sub
  from public.sub_orders so
  where so.id=v_pkg.sub_order_id
  for update;

  if v_sub.id is null then
    raise exception using errcode='P0001', message='TC_SUB_ORDER_NOT_FOUND';
  end if;

  select * into v_order
  from public.orders o
  where o.id=v_sub.order_id
  for update;

  if v_order.id is null then
    raise exception using errcode='P0001', message='TC_ORDER_NOT_FOUND';
  end if;

  select * into v_store
  from public.profiles p
  where p.id=v_sub.store_profile_id
    and p.status='active'
    and p.profile_type in ('TIE','VEN');

  if v_store.id is null
     or v_pkg.current_custodian_id is distinct from v_store.id then
    raise exception using errcode='P0001', message='TC_PACKAGE_SOURCE_CUSTODY_INVALID';
  end if;

  select count(*)::int
    into v_origin_count
  from public.operational_locations o
  where o.owner_profile_id=v_store.id
    and o.purpose='STORE_PICKUP'
    and o.active
    and o.network_enabled
    and o.verification_status='VERIFIED';

  if v_origin_count=0 then
    raise exception using errcode='P0001', message='TC_SOURCE_OPERATIONAL_NODE_REQUIRED';
  end if;
  if v_origin_count>1 then
    raise exception using errcode='P0001', message='TC_SOURCE_OPERATIONAL_NODE_AMBIGUOUS';
  end if;

  select o.id into v_origin_node
  from public.operational_locations o
  where o.owner_profile_id=v_store.id
    and o.purpose='STORE_PICKUP'
    and o.active
    and o.network_enabled
    and o.verification_status='VERIFIED'
  order by o.public_id
  limit 1;

  select count(*)::int
    into v_existing_count
  from public.logistics_demand_packages dp
  join public.logistics_demands d on d.id=dp.demand_id
  where dp.package_id=v_pkg.id
    and d.source_type='CLIENT_ORDER'
    and d.source_id=v_order.public_id
    and d.state<>'CANCELLED';

  if v_existing_count>1 then
    raise exception using errcode='P0001', message='TC_PACKAGE_ACTIVE_LOGISTICS_DEMAND_AMBIGUOUS';
  end if;

  if v_existing_count=1 then
    select d.id into v_existing_demand
    from public.logistics_demand_packages dp
    join public.logistics_demands d on d.id=dp.demand_id
    where dp.package_id=v_pkg.id
      and d.source_type='CLIENT_ORDER'
      and d.source_id=v_order.public_id
      and d.state<>'CANCELLED'
    order by d.created_at,d.id
    limit 1;
    return v_existing_demand;
  end if;

  v_origin_version:=public.tc_ensure_operational_node_destination_version(v_origin_node);
  v_destination_version:=public.tc_ensure_client_order_destination_contract(v_order.id);

  insert into public.logistics_demands(
    source_type,source_id,
    origin_destination_version_id,destination_version_id,
    state,version,cargo_class,
    total_weight_kg,total_volume_m3,
    requires_cold_chain,requires_fragile_handling,
    earliest_ready_at,requirements
  ) values(
    'CLIENT_ORDER',v_order.public_id,
    v_origin_version,v_destination_version,
    'CREATED',0,'PACKAGE',
    v_pkg.weight_kg,v_pkg.volume_m3,
    v_pkg.requires_cold_chain,v_pkg.requires_fragile_handling,
    now(),
    jsonb_build_object(
      'source_operation','CLIENT_ORDER',
      'order_public_id',v_order.public_id,
      'sub_order_public_id',v_sub.public_id,
      'package_public_id',v_pkg.public_id,
      'source_profile_public_id',v_store.public_id
    )
  )
  returning id into v_demand;

  insert into public.logistics_demand_packages(demand_id,package_id)
  values(v_demand,v_pkg.id);

  update public.logistics_demands
     set state='READY_FOR_ROUTING',
         version=version+1,
         updated_at=now()
   where id=v_demand;

  insert into public.audit_logs(
    actor_person_id,actor_profile_id,operation,entity_type,
    entity_public_id,event_id,result,metadata
  )
  select
    p.person_id,
    case when p.id=public.tc_active_profile_id() then p.id else null end,
    'CLIENT_ORDER_LOGISTICS_DEMAND_CREATE',
    'LOGISTICS_DEMAND',
    d.public_id,
    null,
    'APPLIED',
    jsonb_build_object(
      'package_public_id',v_pkg.public_id,
      'order_public_id',v_order.public_id,
      'sub_order_public_id',v_sub.public_id,
      'origin_operational_location_id',v_origin_node,
      'origin_destination_version_id',v_origin_version,
      'destination_version_id',v_destination_version
    )
  from public.logistics_demands d
  join public.profiles p on p.id=v_store.id
  where d.id=v_demand;

  return v_demand;
end;
$function$;

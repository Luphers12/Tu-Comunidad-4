
-- TU COMUNIDAD — CLIENT ORDER -> LOGISTICS DEMAND BRIDGE V1
-- Closes the commerce/package-to-logistics handoff without creating parallel tables.
-- Canonical grain: one CLIENT_ORDER LGD per ready PKG. Many LGDs may later share one MOV.

create or replace function public.tc_inv_consume(
  p_reservation_id uuid,
  p_reason_code text,
  p_event_id text,
  p_occurred_at timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_res public.inventory_reservations%rowtype;
  v_inv public.inventory%rowtype;
  v_reason text:=upper(btrim(coalesce(p_reason_code,'')));
  v_event text:=btrim(coalesce(p_event_id,''));
  v_occurred timestamptz:=coalesce(p_occurred_at,now());
  v_before_reserved bigint;
  v_before_consumed bigint;
  v_before_on_hand bigint;
begin
  if p_reservation_id is null or v_reason='' or v_event='' then
    raise exception using errcode='P0001', message='TC_INVALID_ARGUMENT';
  end if;

  if v_reason not in ('PREPARATION_COMPLETE','FULFILLMENT_COMPLETE','OTHER') then
    raise exception using errcode='P0001', message='TC_INVALID_REASON_CODE';
  end if;

  select * into v_res
  from public.inventory_reservations
  where id=p_reservation_id
  for update;

  if v_res.id is null then
    raise exception using errcode='P0001', message='TC_RESERVATION_NOT_FOUND';
  end if;

  select * into v_inv
  from public.inventory
  where id=v_res.inventory_id
  for update;

  if v_inv.id is null then
    raise exception using errcode='P0001', message='TC_INVENTORY_NOT_FOUND';
  end if;

  if v_res.status='CONSUMED' then
    return jsonb_build_object(
      'success',true,
      'disposition','IDEMPOTENT',
      'reservation_status','CONSUMED',
      'quantity_consumed',v_res.quantity,
      'inventory_version',v_inv.version
    );
  end if;

  if v_res.status='RELEASED' then
    raise exception using errcode='P0001', message='TC_RESERVATION_ALREADY_RELEASED';
  end if;
  if v_res.status='EXPIRED' then
    raise exception using errcode='P0001', message='TC_RESERVATION_ALREADY_EXPIRED';
  end if;
  if v_res.status<>'RESERVED' then
    raise exception using errcode='P0001', message='TC_INVALID_RESERVATION_STATE';
  end if;

  v_before_reserved:=v_inv.quantity_reserved;
  v_before_consumed:=v_inv.quantity_consumed;
  v_before_on_hand:=v_inv.quantity_on_hand;

  if v_before_reserved<v_res.quantity
     or v_before_on_hand<v_res.quantity then
    raise exception using errcode='P0001', message='TC_DATA_INCONSISTENCY';
  end if;

  update public.inventory
     set quantity_reserved=quantity_reserved-v_res.quantity,
         quantity_consumed=quantity_consumed+v_res.quantity,
         quantity_on_hand=quantity_on_hand-v_res.quantity,
         version=version+1,
         updated_at=now()
   where id=v_inv.id;

  update public.inventory_reservations
     set status='CONSUMED',
         consumed_at=v_occurred
   where id=v_res.id
     and status='RESERVED';

  if not found then
    raise exception using errcode='P0001', message='TC_CONSUME_RACE';
  end if;

  select * into v_inv from public.inventory where id=v_inv.id;

  insert into public.audit_logs(
    actor_person_id,actor_profile_id,operation,entity_type,
    entity_public_id,event_id,result,metadata
  ) values(
    null,null,'INVENTORY_RESERVATION_CONSUME','INVENTORY_RESERVATION',
    null,null,'APPLIED',
    jsonb_build_object(
      'reservation_id',v_res.id,
      'inventory_id',v_res.inventory_id,
      'quantity',v_res.quantity,
      'reason_code',v_reason,
      'event_id',v_event,
      'reserved_before',v_before_reserved,
      'reserved_after',v_inv.quantity_reserved,
      'consumed_before',v_before_consumed,
      'consumed_after',v_inv.quantity_consumed,
      'on_hand_before',v_before_on_hand,
      'on_hand_after',v_inv.quantity_on_hand,
      'inventory_version',v_inv.version
    )
  );

  return jsonb_build_object(
    'success',true,
    'disposition','APPLIED',
    'reservation_status','CONSUMED',
    'quantity_consumed',v_res.quantity,
    'inventory_version',v_inv.version
  );
end;
$function$;

revoke all on function public.tc_inv_consume(uuid,text,text,timestamptz)
  from public,anon,authenticated;
grant execute on function public.tc_inv_consume(uuid,text,text,timestamptz)
  to service_role;

comment on function public.tc_inv_consume(uuid,text,text,timestamptz) is
'Internal inventory primitive. Atomically converts RESERVED to CONSUMED, moves reserved quantity into consumed commitment, decrements physical on-hand, and preserves audit history.';


create or replace function public.tc_ensure_operational_node_destination_version(
  p_operational_location_id uuid
)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_node public.operational_locations%rowtype;
  v_destination uuid;
  v_existing_version uuid;
  v_existing_no bigint;
  v_existing_country uuid;
  v_existing_department uuid;
  v_existing_municipality uuid;
  v_existing_community uuid;
  v_destination_count integer;
  v_new_version uuid;
begin
  if p_operational_location_id is null then
    raise exception using errcode='P0001', message='TC_OPERATIONAL_NODE_REQUIRED';
  end if;

  perform pg_advisory_xact_lock(hashtext('TC_NODE_DESTINATION|'||p_operational_location_id::text));

  select * into v_node
  from public.operational_locations o
  where o.id=p_operational_location_id
    and o.active
  for update;

  if v_node.id is null then
    raise exception using errcode='P0001', message='TC_OPERATIONAL_NODE_NOT_ACTIVE';
  end if;

  select count(distinct dv.destination_id)::int
    into v_destination_count
  from public.logistics_destination_versions dv
  where dv.target_kind='OPERATIONAL_NODE'
    and dv.operational_location_id=v_node.id;

  if v_destination_count>1 then
    raise exception using errcode='P0001', message='TC_NODE_DESTINATION_AMBIGUOUS';
  end if;

  select
    dv.id,dv.destination_id,dv.version_no,
    dv.country_id,dv.department_id,dv.municipality_id,dv.community_id
  into
    v_existing_version,v_destination,v_existing_no,
    v_existing_country,v_existing_department,v_existing_municipality,v_existing_community
  from public.logistics_destination_versions dv
  join public.logistics_destinations d on d.id=dv.destination_id
  where dv.target_kind='OPERATIONAL_NODE'
    and dv.operational_location_id=v_node.id
    and d.status='ACTIVE'
  order by dv.version_no desc,dv.created_at desc,dv.id desc
  limit 1;

  if v_existing_version is not null
     and v_existing_country is not distinct from v_node.country_id
     and v_existing_department is not distinct from v_node.department_id
     and v_existing_municipality is not distinct from v_node.municipality_id
     and v_existing_community is not distinct from v_node.community_id then
    return v_existing_version;
  end if;

  if v_destination is null then
    insert into public.logistics_destinations(created_by_person_id)
    values(v_node.created_by_person_id)
    returning id into v_destination;
    v_existing_no:=0;
  end if;

  insert into public.logistics_destination_versions(
    destination_id,version_no,target_kind,
    private_snapshot_id,operational_location_id,
    country_id,department_id,municipality_id,community_id
  ) values(
    v_destination,coalesce(v_existing_no,0)+1,'OPERATIONAL_NODE',
    null,v_node.id,
    v_node.country_id,v_node.department_id,v_node.municipality_id,v_node.community_id
  )
  returning id into v_new_version;

  return v_new_version;
end;
$function$;

revoke all on function public.tc_ensure_operational_node_destination_version(uuid)
  from public,anon,authenticated;
grant execute on function public.tc_ensure_operational_node_destination_version(uuid)
  to service_role;

comment on function public.tc_ensure_operational_node_destination_version(uuid) is
'Internal canonical adapter from operational_locations to immutable logistics_destination_versions. Reuses the current node snapshot and appends a new version only if typed territory changed.';


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

  select count(*)::int,min(o.id)
    into v_node_count,v_node
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

revoke all on function public.tc_ensure_client_order_destination_contract(uuid)
  from public,anon,authenticated;
grant execute on function public.tc_ensure_client_order_destination_contract(uuid)
  to service_role;

comment on function public.tc_ensure_client_order_destination_contract(uuid) is
'Internal client-order destination adapter. HOME must already be frozen at order insert. Legacy PTC destinations are canonically mapped to the single verified network-enabled PTC node.';


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

  select count(*)::int,min(o.id)
    into v_origin_count,v_origin_node
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

  select count(*)::int,min(d.id)
    into v_existing_count,v_existing_demand
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

revoke all on function public.tc_materialize_client_order_logistics_demand(uuid)
  from public,anon,authenticated;
grant execute on function public.tc_materialize_client_order_logistics_demand(uuid)
  to service_role;

comment on function public.tc_materialize_client_order_logistics_demand(uuid) is
'Internal SOURCE_OPERATION -> LOGISTICS_DEMAND bridge for a READY client-order PKG. Creates one LGD per ready PKG, links it append-only, then atomically transitions to READY_FOR_ROUTING so the existing outbox/runtime takes over.';


create or replace function public.tc_publish_ready_package_to_logistics(
  p_package_public_id text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_active uuid;
  v_pkg public.packages%rowtype;
  v_sub public.sub_orders%rowtype;
  v_demand uuid;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode='P0001', message='TC_UNAUTHENTICATED';
  end if;

  v_active:=public.tc_active_profile_id();
  if v_active is null then
    raise exception using errcode='P0001', message='TC_ACTIVE_PROFILE_NOT_SELECTED';
  end if;

  if not exists(
    select 1 from public.profiles p
    where p.id=v_active
      and p.status='active'
      and p.profile_type in ('TIE','VEN')
  ) then
    raise exception using errcode='P0001', message='TC_ACTIVE_PROFILE_TYPE_MISMATCH';
  end if;

  select * into v_pkg
  from public.packages p
  where p.public_id=upper(btrim(coalesce(p_package_public_id,'')))
  for update;

  if v_pkg.id is null then
    raise exception using errcode='P0001', message='TC_PACKAGE_NOT_FOUND';
  end if;

  select * into v_sub
  from public.sub_orders so
  where so.id=v_pkg.sub_order_id;

  if v_sub.store_profile_id is distinct from v_active
     or v_pkg.current_custodian_id is distinct from v_active then
    raise exception using errcode='P0001', message='TC_PACKAGE_SOURCE_PROFILE_FORBIDDEN';
  end if;

  v_demand:=public.tc_materialize_client_order_logistics_demand(v_pkg.id);

  select jsonb_build_object(
    'success',true,
    'package_public_id',v_pkg.public_id,
    'logistics_demand_public_id',d.public_id,
    'logistics_demand_state',d.state,
    'idempotent',
      exists(
        select 1
        from public.logistics_demand_packages dp
        where dp.demand_id=d.id
          and dp.package_id=v_pkg.id
          and dp.created_at<d.updated_at
      )
  )
  into v_result
  from public.logistics_demands d
  where d.id=v_demand;

  return v_result;
end;
$function$;

revoke all on function public.tc_publish_ready_package_to_logistics(text)
  from public,anon;
grant execute on function public.tc_publish_ready_package_to_logistics(text)
  to authenticated,service_role;

comment on function public.tc_publish_ready_package_to_logistics(text) is
'Authenticated store/VEN wrapper for publishing an already READY package into canonical logistics. Requires the exact active source profile and source custody.';


create or replace function public.tc_complete_package_preparation(
  p_package_public_id text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_uid uuid:=auth.uid();
  v_person uuid;
  v_active uuid;
  v_pkg public.packages%rowtype;
  v_sub public.sub_orders%rowtype;
  v_key text:=btrim(coalesce(p_idempotency_key,''));
  v_hash text;
  v_inserted integer:=0;
  v_idem public.idempotency_records%rowtype;
  v_content_count integer;
  v_package_count integer;
  v_rec record;
  v_res_result jsonb;
  v_alloc public.order_sourcing_allocations%rowtype;
  v_demand_item public.order_demand_items%rowtype;
  v_new_fulfilled bigint;
  v_weight numeric:=0;
  v_volume numeric:=0;
  v_cold boolean:=false;
  v_fragile boolean:=false;
  v_demand uuid;
  v_demand_public text;
  v_result jsonb;
begin
  if v_uid is null then
    raise exception using errcode='P0001', message='TC_UNAUTHENTICATED';
  end if;
  if nullif(btrim(coalesce(p_package_public_id,'')),'') is null
     or v_key='' then
    raise exception using errcode='P0001', message='TC_INVALID_ARGUMENT';
  end if;

  select per.id into v_person
  from public.persons per
  where per.auth_user_id=v_uid
  limit 1;

  if v_person is null then
    raise exception using errcode='P0001', message='TC_UNAUTHENTICATED';
  end if;

  v_active:=public.tc_active_profile_id();
  if v_active is null then
    raise exception using errcode='P0001', message='TC_ACTIVE_PROFILE_NOT_SELECTED';
  end if;

  if not exists(
    select 1 from public.profiles p
    where p.id=v_active
      and p.person_id=v_person
      and p.status='active'
      and p.profile_type in ('TIE','VEN')
  ) then
    raise exception using errcode='P0001', message='TC_ACTIVE_PROFILE_TYPE_MISMATCH';
  end if;

  v_hash:=encode(
    extensions.digest(
      convert_to(
        'COMPLETE_PACKAGE_PREPARATION|'||
        upper(btrim(p_package_public_id)),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  insert into public.idempotency_records(
    operation_type,idempotency_key,person_id,request_hash,status
  ) values(
    'COMPLETE_PACKAGE_PREPARATION',v_key,v_person,v_hash,'PROCESSING'
  )
  on conflict(operation_type,idempotency_key) do nothing;
  get diagnostics v_inserted=row_count;

  if v_inserted=0 then
    select * into v_idem
    from public.idempotency_records
    where operation_type='COMPLETE_PACKAGE_PREPARATION'
      and idempotency_key=v_key
    for update;

    if v_idem.person_id is distinct from v_person
       or v_idem.request_hash is distinct from v_hash then
      raise exception using errcode='P0001', message='TC_IDEMPOTENCY_KEY_REUSED';
    end if;

    if v_idem.status='COMPLETED' then
      return v_idem.response_payload;
    end if;

    if v_idem.status='PROCESSING' then
      raise exception using errcode='P0001', message='TC_IDEMPOTENCY_IN_PROGRESS';
    end if;
  end if;

  select * into v_pkg
  from public.packages p
  where p.public_id=upper(btrim(p_package_public_id))
  for update;

  if v_pkg.id is null then
    raise exception using errcode='P0001', message='TC_PACKAGE_NOT_FOUND';
  end if;

  select * into v_sub
  from public.sub_orders so
  where so.id=v_pkg.sub_order_id
  for update;

  if v_sub.id is null then
    raise exception using errcode='P0001', message='TC_SUB_ORDER_NOT_FOUND';
  end if;

  if v_sub.store_profile_id is distinct from v_active
     or v_pkg.current_custodian_id is distinct from v_active then
    raise exception using errcode='P0001', message='TC_PACKAGE_SOURCE_PROFILE_FORBIDDEN';
  end if;

  if v_pkg.state='READY' then
    v_demand:=public.tc_materialize_client_order_logistics_demand(v_pkg.id);
    select public_id into v_demand_public
    from public.logistics_demands where id=v_demand;

    v_result:=jsonb_build_object(
      'success',true,
      'disposition','IDEMPOTENT',
      'package_public_id',v_pkg.public_id,
      'package_state','READY',
      'logistics_demand_public_id',v_demand_public
    );

    update public.idempotency_records
       set status='COMPLETED',response_payload=v_result,completed_at=now()
     where operation_type='COMPLETE_PACKAGE_PREPARATION'
       and idempotency_key=v_key;

    return v_result;
  end if;

  if v_pkg.state<>'CREATED' then
    raise exception using errcode='P0001', message='TC_PACKAGE_PREPARATION_STATE_INVALID';
  end if;

  select count(*)::int into v_content_count
  from public.package_contents pc
  where pc.package_id=v_pkg.id;

  -- LEGACY_ADAPTER: old checkout created one package per sub-order before package_contents existed.
  if v_content_count=0 then
    select count(*)::int into v_package_count
    from public.packages p
    where p.sub_order_id=v_sub.id;

    if v_package_count<>1 then
      raise exception using errcode='P0001', message='TC_PACKAGE_CONTENTS_REQUIRED';
    end if;

    if not exists(
      select 1 from public.order_items oi
      where oi.sub_order_id=v_sub.id
    ) then
      raise exception using errcode='P0001', message='TC_PACKAGE_CONTENTS_REQUIRED';
    end if;

    insert into public.package_contents(package_id,order_item_id,quantity)
    select v_pkg.id,oi.id,oi.quantity
    from public.order_items oi
    where oi.sub_order_id=v_sub.id
    order by oi.id;

    select count(*)::int into v_content_count
    from public.package_contents pc
    where pc.package_id=v_pkg.id;
  end if;

  if v_content_count<1 then
    raise exception using errcode='P0001', message='TC_PACKAGE_CONTENTS_REQUIRED';
  end if;

  if exists(
    select 1
    from public.package_contents pc
    join public.order_items oi on oi.id=pc.order_item_id
    where pc.package_id=v_pkg.id
      and oi.sub_order_id is distinct from v_sub.id
  ) then
    raise exception using errcode='P0001', message='TC_PACKAGE_CONTENT_SUB_ORDER_MISMATCH';
  end if;

  for v_rec in
    select
      pc.id as package_content_id,
      pc.quantity,
      oi.id as order_item_id,
      ir.id as reservation_id,
      ir.inventory_id,
      osa.id as allocation_id
    from public.package_contents pc
    join public.order_items oi on oi.id=pc.order_item_id
    left join public.inventory_reservations ir on ir.order_item_id=oi.id
    left join public.order_sourcing_allocations osa on osa.order_item_id=oi.id
    where pc.package_id=v_pkg.id
    order by ir.inventory_id nulls last,oi.id
  loop
    if v_rec.reservation_id is null then
      raise exception using errcode='P0001', message='TC_RESERVATION_REQUIRED';
    end if;

    if not exists(
      select 1
      from public.inventory_reservations ir
      where ir.id=v_rec.reservation_id
        and ir.quantity=v_rec.quantity
        and ir.status in ('RESERVED','CONSUMED')
    ) then
      raise exception using errcode='P0001', message='TC_RESERVATION_QUANTITY_MISMATCH';
    end if;

    v_res_result:=public.tc_inv_consume(
      v_rec.reservation_id,
      'PREPARATION_COMPLETE',
      'PKG_READY:'||v_pkg.public_id||':'||v_rec.reservation_id::text
    );

    if v_rec.allocation_id is not null then
      select * into v_alloc
      from public.order_sourcing_allocations a
      where a.id=v_rec.allocation_id
      for update;

      if v_alloc.state='ACTIVE' then
        if v_rec.quantity>(v_alloc.qty_allocated-v_alloc.qty_fulfilled-v_alloc.qty_released) then
          raise exception using errcode='P0001', message='TC_ALLOCATION_FULFILLMENT_OVERFLOW';
        end if;

        update public.order_sourcing_allocations
           set qty_fulfilled=qty_fulfilled+v_rec.quantity,
               state=case
                 when qty_fulfilled+v_rec.quantity >= qty_allocated-qty_released
                   then 'FULFILLED'
                 else state
               end,
               closed_at=case
                 when qty_fulfilled+v_rec.quantity >= qty_allocated-qty_released
                   then coalesce(closed_at,now())
                 else closed_at
               end,
               version=version+1,
               updated_at=now()
         where id=v_alloc.id;

        select * into v_demand_item
        from public.order_demand_items d
        where d.id=v_alloc.demand_item_id
        for update;

        if v_demand_item.id is null then
          raise exception using errcode='P0001', message='TC_ORDER_DEMAND_ITEM_NOT_FOUND';
        end if;

        v_new_fulfilled:=v_demand_item.quantity_fulfilled+v_rec.quantity;
        if v_new_fulfilled>v_demand_item.quantity_requested then
          raise exception using errcode='P0001', message='TC_ORDER_DEMAND_FULFILLMENT_OVERFLOW';
        end if;

        update public.order_demand_items
           set quantity_fulfilled=v_new_fulfilled,
               state=case
                 when v_new_fulfilled=v_demand_item.quantity_requested then 'FULFILLED'
                 when v_new_fulfilled>0 then 'PARTIALLY_FULFILLED'
                 else state
               end,
               version=version+1,
               updated_at=now()
         where id=v_demand_item.id;
      elsif v_alloc.state<>'FULFILLED' then
        raise exception using errcode='P0001', message='TC_ALLOCATION_NOT_FULFILLABLE';
      end if;
    end if;
  end loop;

  select
    coalesce(sum(coalesce(pv.weight_kg,0)*pc.quantity),0),
    coalesce(sum(coalesce(pv.volume_m3,0)*pc.quantity),0),
    coalesce(bool_or(coalesce(pv.requires_cold_chain,false)),false),
    coalesce(bool_or(coalesce(pv.requires_fragile_handling,false)),false)
  into v_weight,v_volume,v_cold,v_fragile
  from public.package_contents pc
  join public.order_items oi on oi.id=pc.order_item_id
  join public.product_variants pv on pv.id=oi.variant_id
  where pc.package_id=v_pkg.id;

  update public.packages
     set state='READY',
         weight_kg=v_weight,
         volume_m3=v_volume,
         requires_cold_chain=v_cold,
         requires_fragile_handling=v_fragile,
         version=version+1,
         updated_at=now()
   where id=v_pkg.id
     and state='CREATED';

  if not found then
    raise exception using errcode='P0001', message='TC_PACKAGE_READY_RACE';
  end if;

  select * into v_pkg
  from public.packages
  where id=v_pkg.id;

  v_demand:=public.tc_materialize_client_order_logistics_demand(v_pkg.id);

  select public_id into v_demand_public
  from public.logistics_demands
  where id=v_demand;

  insert into public.audit_logs(
    actor_person_id,actor_profile_id,operation,entity_type,
    entity_public_id,event_id,before_version,after_version,result,metadata
  ) values(
    v_person,v_active,
    'COMPLETE_PACKAGE_PREPARATION',
    'PACKAGE',
    v_pkg.public_id,
    null,
    v_pkg.version-1,v_pkg.version,
    'APPLIED',
    jsonb_build_object(
      'logistics_demand_public_id',v_demand_public,
      'package_weight_kg',v_pkg.weight_kg,
      'package_volume_m3',v_pkg.volume_m3,
      'idempotency_key',v_key
    )
  );

  v_result:=jsonb_build_object(
    'success',true,
    'disposition','APPLIED',
    'package_public_id',v_pkg.public_id,
    'package_state','READY',
    'logistics_demand_public_id',v_demand_public,
    'logistics_demand_state','READY_FOR_ROUTING'
  );

  update public.idempotency_records
     set status='COMPLETED',
         response_payload=v_result,
         completed_at=now()
   where operation_type='COMPLETE_PACKAGE_PREPARATION'
     and idempotency_key=v_key
     and person_id=v_person
     and request_hash=v_hash;

  return v_result;
end;
$function$;

revoke all on function public.tc_complete_package_preparation(text,text)
  from public,anon;
grant execute on function public.tc_complete_package_preparation(text,text)
  to authenticated,service_role;

comment on function public.tc_complete_package_preparation(text,text) is
'Canonical preparation completion. Requires the exact active TIE/VEN source profile, consumes inventory reservations, updates sourcing fulfillment where present, marks PKG READY, then atomically publishes the PKG into canonical logistics. Legacy one-package-per-suborder rows are adapted by materializing package_contents before consumption.';

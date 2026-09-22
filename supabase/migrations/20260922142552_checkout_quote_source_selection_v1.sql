
-- TU COMUNIDAD — CHECKOUT QUOTE + SOURCE SELECTION V1

create or replace function public.tc_checkout_destination_context(
  p_client_profile_id uuid,
  p_destination_type text,
  p_destination_id text
)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_type text:=upper(btrim(coalesce(p_destination_type,'')));
  v_dest text:=btrim(coalesce(p_destination_id,''));
  v_person uuid;
  v_country uuid;
  v_department uuid;
  v_municipality uuid;
  v_community uuid;
  v_target_nodes uuid[];
  v_ptc_profile uuid;
  v_count integer;
begin
  select p.person_id into v_person
  from public.profiles p
  where p.id=p_client_profile_id
    and p.profile_type='CLI'
    and p.status='active';

  if v_person is null then
    raise exception using errcode='P0001', message='TC_CLIENT_PROFILE_INVALID';
  end if;

  if v_type='HOME' then
    select
      cl.country_id,cl.department_id,cl.municipality_id,cl.community_id
    into
      v_country,v_department,v_municipality,v_community
    from public.customer_locations cl
    where cl.person_id=v_person
      and cl.active
      and upper(cl.destination_type)='HOME'
      and (
        cl.id::text=v_dest
        or cl.public_id=upper(v_dest)
      )
    limit 1;

    if v_community is null then
      raise exception using errcode='P0001', message='TC_HOME_DESTINATION_NOT_OWNED_OR_INACTIVE';
    end if;

    select array_agg(o.id order by o.public_id)
      into v_target_nodes
    from public.operational_locations o
    where o.community_id=v_community
      and o.active
      and o.network_enabled
      and o.verification_status='VERIFIED'
      and exists(
        select 1
        from public.operational_location_capabilities olc
        join public.logistics_capability_catalog cap
          on cap.id=olc.capability_id
        where olc.operational_location_id=o.id
          and olc.status='ENABLED'
          and cap.active
          and cap.code='LAST_MILE_ORIGIN'
      );

    if v_target_nodes is null or cardinality(v_target_nodes)<1 then
      raise exception using errcode='P0001', message='TC_HOME_LAST_MILE_ORIGIN_REQUIRED';
    end if;

  elsif v_type='PTC' then
    select p.id into v_ptc_profile
    from public.profiles p
    where p.public_id=upper(v_dest)
      and p.profile_type='PTC'
      and p.status='active'
    limit 1;

    if v_ptc_profile is null then
      raise exception using errcode='P0001', message='TC_PTC_DESTINATION_PROFILE_INVALID';
    end if;

    select count(*)::int,
           array_agg(o.id order by o.public_id)
      into v_count,v_target_nodes
    from public.operational_locations o
    where o.owner_profile_id=v_ptc_profile
      and o.purpose='PTC_PICKUP'
      and o.active
      and o.network_enabled
      and o.verification_status='VERIFIED';

    if v_count=0 then
      raise exception using errcode='P0001', message='TC_PTC_DESTINATION_NODE_REQUIRED';
    end if;
    if v_count>1 then
      raise exception using errcode='P0001', message='TC_PTC_DESTINATION_NODE_AMBIGUOUS';
    end if;

    select o.country_id,o.department_id,o.municipality_id,o.community_id
      into v_country,v_department,v_municipality,v_community
    from public.operational_locations o
    where o.id=v_target_nodes[1];

  else
    raise exception using errcode='P0001', message='TC_DESTINATION_INVALID';
  end if;

  return jsonb_build_object(
    'destination_type',v_type,
    'country_id',v_country,
    'department_id',v_department,
    'municipality_id',v_municipality,
    'community_id',v_community,
    'target_node_ids',to_jsonb(v_target_nodes)
  );
end;
$function$;

revoke all on function public.tc_checkout_destination_context(uuid,text,text)
  from public,anon,authenticated;
grant execute on function public.tc_checkout_destination_context(uuid,text,text)
  to service_role;


create or replace function public.tc_quote_structural_path_exists(
  p_origin_node_id uuid,
  p_target_node_id uuid,
  p_package_weight_kg numeric default 0,
  p_package_volume_m3 numeric default 0,
  p_max_hops integer default 8
)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
with recursive
valid_endpoints as (
  select
    exists(
      select 1 from public.operational_locations o
      where o.id=p_origin_node_id and o.active and o.network_enabled
    ) as origin_ok,
    exists(
      select 1 from public.operational_locations o
      where o.id=p_target_node_id and o.active and o.network_enabled
    ) as target_ok
),
paths as (
  select
    p_origin_node_id as current_node,
    array[p_origin_node_id]::uuid[] as path_nodes,
    0 as depth
  from valid_endpoints
  where origin_ok and target_ok

  union all

  select
    e.destination_operational_location_id,
    p.path_nodes || e.destination_operational_location_id,
    p.depth+1
  from paths p
  join public.logistics_edges e
    on e.origin_operational_location_id=p.current_node
   and e.structural_status='ACTIVE'
  join public.operational_locations dst
    on dst.id=e.destination_operational_location_id
   and dst.active
   and dst.network_enabled
  where p.depth<p_max_hops
    and not (e.destination_operational_location_id=any(p.path_nodes))
    and (
      e.max_single_package_weight_kg is null
      or coalesce(p_package_weight_kg,0)<=e.max_single_package_weight_kg
    )
    and (
      e.max_single_package_volume_m3 is null
      or coalesce(p_package_volume_m3,0)<=e.max_single_package_volume_m3
    )
    and (
      e.destination_operational_location_id=p_target_node_id
      or (
        exists(
          select 1
          from public.operational_location_capabilities olc
          join public.logistics_capability_catalog cap on cap.id=olc.capability_id
          where olc.operational_location_id=e.destination_operational_location_id
            and olc.status='ENABLED'
            and cap.active
            and cap.code='RECEIVE_CARGO'
        )
        and exists(
          select 1
          from public.operational_location_capabilities olc
          join public.logistics_capability_catalog cap on cap.id=olc.capability_id
          where olc.operational_location_id=e.destination_operational_location_id
            and olc.status='ENABLED'
            and cap.active
            and cap.code='HANDOFF_CARGO'
        )
        and not exists(
          select 1
          from unnest(coalesce(e.required_capability_codes,'{}'::text[])) req(code)
          where not exists(
            select 1
            from public.operational_location_capabilities olc
            join public.logistics_capability_catalog cap on cap.id=olc.capability_id
            where olc.operational_location_id=e.destination_operational_location_id
              and olc.status='ENABLED'
              and cap.active
              and cap.code=req.code
          )
        )
      )
    )
)
select
  p_origin_node_id=p_target_node_id
  or exists(
    select 1 from paths
    where current_node=p_target_node_id
  );
$function$;

revoke all on function public.tc_quote_structural_path_exists(uuid,uuid,numeric,numeric,integer)
  from public,anon,authenticated;
grant execute on function public.tc_quote_structural_path_exists(uuid,uuid,numeric,numeric,integer)
  to service_role;


create or replace function public.tc_quote_checkout(
  p_client_profile_public_id text,
  p_destination_type text,
  p_destination_id text,
  p_items jsonb,
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
  v_client uuid;
  v_client_public text:=upper(btrim(coalesce(p_client_profile_public_id,'')));
  v_dest_type text:=upper(btrim(coalesce(p_destination_type,'')));
  v_dest_id text:=btrim(coalesce(p_destination_id,''));
  v_key text:=btrim(coalesce(p_idempotency_key,''));
  v_hash text;
  v_inserted integer:=0;
  v_idem public.idempotency_records%rowtype;
  v_dest_ctx jsonb;
  v_dest_community uuid;
  v_dest_municipality uuid;
  v_dest_department uuid;
  v_targets uuid[];
  v_item jsonb;
  v_qty bigint;
  v_listing_public text;
  v_variant_public text;
  v_seller_public text;
  v_source_mode text;
  v_listing uuid;
  v_variant uuid;
  v_store uuid;
  v_store_public text;
  v_source_node uuid;
  v_price bigint;
  v_currency varchar(3);
  v_seller_name text;
  v_weight numeric;
  v_volume numeric;
  v_line_total bigint;
  v_total bigint:=0;
  v_quote_currency varchar(3);
  v_lines jsonb:='[]'::jsonb;
  v_line_no integer:=0;
  v_already_qty bigint;
  v_match_count integer;
  v_candidate record;
  v_quote uuid;
  v_quote_public text;
  v_result jsonb;
begin
  if v_uid is null then
    raise exception using errcode='P0001', message='TC_UNAUTHENTICATED';
  end if;

  if v_client_public='' or v_dest_id='' or v_key='' then
    raise exception using errcode='P0001', message='TC_INVALID_ARGUMENT';
  end if;

  if p_items is null
     or jsonb_typeof(p_items)<>'array'
     or jsonb_array_length(p_items)<1
     or jsonb_array_length(p_items)>200 then
    raise exception using errcode='P0001', message='TC_INVALID_ITEMS_PAYLOAD';
  end if;

  select per.id,pr.id
    into v_person,v_client
  from public.persons per
  join public.profiles pr on pr.person_id=per.id
  where per.auth_user_id=v_uid
    and pr.public_id=v_client_public
    and pr.profile_type='CLI'
    and pr.status='active'
  limit 1;

  if v_client is null then
    raise exception using errcode='P0001', message='TC_FORBIDDEN_CLIENT_PROFILE';
  end if;

  if public.tc_active_profile_id() is distinct from v_client then
    raise exception using errcode='P0001', message='TC_ACTIVE_PROFILE_MISMATCH';
  end if;

  v_hash:=encode(
    extensions.digest(
      convert_to(
        'QUOTE_CHECKOUT|'||v_client_public||'|'||v_dest_type||'|'||
        upper(v_dest_id)||'|'||p_items::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  insert into public.idempotency_records(
    operation_type,idempotency_key,person_id,request_hash,status
  ) values(
    'QUOTE_CHECKOUT',v_key,v_person,v_hash,'PROCESSING'
  )
  on conflict(operation_type,idempotency_key) do nothing;
  get diagnostics v_inserted=row_count;

  if v_inserted=0 then
    select * into v_idem
    from public.idempotency_records
    where operation_type='QUOTE_CHECKOUT'
      and idempotency_key=v_key
    for update;

    if v_idem.person_id is distinct from v_person
       or v_idem.request_hash is distinct from v_hash then
      raise exception using errcode='P0001', message='TC_IDEMPOTENCY_KEY_REUSED';
    end if;

    if v_idem.status='COMPLETED' then
      return v_idem.response_payload;
    end if;

    raise exception using errcode='P0001', message='TC_IDEMPOTENCY_IN_PROGRESS';
  end if;

  v_dest_ctx:=public.tc_checkout_destination_context(v_client,v_dest_type,v_dest_id);
  v_dest_community:=(v_dest_ctx->>'community_id')::uuid;
  v_dest_municipality:=(v_dest_ctx->>'municipality_id')::uuid;
  v_dest_department:=(v_dest_ctx->>'department_id')::uuid;

  select array_agg(value::text::uuid)
    into v_targets
  from jsonb_array_elements_text(v_dest_ctx->'target_node_ids');

  for v_item in
    select value from jsonb_array_elements(p_items)
  loop
    if jsonb_typeof(v_item)<>'object'
       or coalesce(v_item->>'quantity','') !~ '^[1-9][0-9]*$'
       or length(v_item->>'quantity')>9 then
      raise exception using errcode='P0001', message='TC_INVALID_ITEMS_PAYLOAD';
    end if;

    v_qty:=(v_item->>'quantity')::bigint;
    v_listing_public:=nullif(upper(btrim(coalesce(v_item->>'listing_public_id',''))),'');
    v_variant_public:=nullif(upper(btrim(coalesce(v_item->>'variant_public_id',''))),'');
    v_seller_public:=nullif(upper(btrim(coalesce(v_item->>'seller_profile_public_id',''))),'');

    if v_listing_public is null and v_variant_public is null then
      raise exception using errcode='P0001', message='TC_ITEM_VARIANT_OR_LISTING_REQUIRED';
    end if;

    v_source_mode:=case
      when v_listing_public is not null or v_seller_public is not null
        then 'CLIENT_SELECTED'
      else 'AUTO_SELECTED'
    end;

    if v_listing_public is not null then
      select count(*)::int
        into v_match_count
      from public.store_listings sl
      join public.product_variants pv on pv.id=sl.variant_id
      join public.profiles sp on sp.id=sl.store_profile_id
      join public.inventory i on i.listing_id=sl.id
      left join public.store_directory sd on sd.store_profile_id=sp.id
      where sl.public_id=v_listing_public
        and sl.is_active
        and pv.is_active
        and sp.status='active'
        and sp.profile_type in ('TIE','VEN')
        and (v_variant_public is null or pv.public_id=v_variant_public)
        and (v_seller_public is null or sp.public_id=v_seller_public)
        and coalesce(sd.is_active,true)
        and coalesce(sd.is_open,true);

      if v_match_count<>1 then
        raise exception using errcode='P0001', message='TC_SELECTED_SOURCE_INVALID';
      end if;

      select
        sl.id,pv.id,sp.id,sp.public_id,sl.price_minor,sl.currency,
        coalesce(nullif(btrim(sd.commercial_name),''),sp.public_id),
        coalesce(pv.weight_kg,0)*v_qty,
        coalesce(pv.volume_m3,0)*v_qty,
        ol.id
      into
        v_listing,v_variant,v_store,v_store_public,v_price,v_currency,
        v_seller_name,v_weight,v_volume,v_source_node
      from public.store_listings sl
      join public.product_variants pv on pv.id=sl.variant_id
      join public.profiles sp on sp.id=sl.store_profile_id
      join public.inventory i on i.listing_id=sl.id
      left join public.store_directory sd on sd.store_profile_id=sp.id
      join public.operational_locations ol
        on ol.owner_profile_id=sp.id
       and ol.purpose='STORE_PICKUP'
       and ol.active
       and ol.network_enabled
       and ol.verification_status='VERIFIED'
      where sl.public_id=v_listing_public
        and sl.is_active
        and pv.is_active
        and sp.status='active'
        and sp.profile_type in ('TIE','VEN')
        and (v_variant_public is null or pv.public_id=v_variant_public)
        and (v_seller_public is null or sp.public_id=v_seller_public)
        and coalesce(sd.is_active,true)
        and coalesce(sd.is_open,true)
        and (
          select count(*)
          from public.operational_locations o2
          where o2.owner_profile_id=sp.id
            and o2.purpose='STORE_PICKUP'
            and o2.active
            and o2.network_enabled
            and o2.verification_status='VERIFIED'
        )=1
      limit 1;

      if v_listing is null then
        raise exception using errcode='P0001', message='TC_SELECTED_SOURCE_NODE_REQUIRED';
      end if;

      select coalesce(sum((e->>'quantity')::bigint),0)
        into v_already_qty
      from jsonb_array_elements(v_lines) e
      where (e->>'listing_id')::uuid=v_listing;

      if not exists(
        select 1
        from public.inventory i
        where i.listing_id=v_listing
          and (i.quantity_committed-i.quantity_reserved-i.quantity_consumed)
              >= v_qty+v_already_qty
      ) then
        raise exception using errcode='P0001', message='TC_SELECTED_SOURCE_UNAVAILABLE';
      end if;

      if not exists(
        select 1
        from unnest(v_targets) t(node_id)
        where public.tc_quote_structural_path_exists(
          v_source_node,t.node_id,v_weight,v_volume,8
        )
      ) then
        raise exception using errcode='P0001', message='TC_SELECTED_SOURCE_STRUCTURAL_UNREACHABLE';
      end if;

    else
      v_candidate:=null;

      select
        sl.id as listing_id,
        pv.id as variant_id,
        sp.id as store_id,
        sp.public_id as store_public_id,
        sl.price_minor,
        sl.currency,
        coalesce(nullif(btrim(sd.commercial_name),''),sp.public_id) as seller_name,
        coalesce(pv.weight_kg,0)*v_qty as total_weight,
        coalesce(pv.volume_m3,0)*v_qty as total_volume,
        ol.id as source_node
      into v_candidate
      from public.store_listings sl
      join public.product_variants pv on pv.id=sl.variant_id
      join public.profiles sp on sp.id=sl.store_profile_id
      join public.inventory i on i.listing_id=sl.id
      left join public.store_directory sd on sd.store_profile_id=sp.id
      left join public.communities sc on sc.public_id=sp.territory_id
      left join public.municipalities sm on sm.id=sc.municipality_id
      left join public.departments sdep on sdep.id=sm.department_id
      join public.operational_locations ol
        on ol.owner_profile_id=sp.id
       and ol.purpose='STORE_PICKUP'
       and ol.active
       and ol.network_enabled
       and ol.verification_status='VERIFIED'
      where pv.public_id=v_variant_public
        and pv.is_active
        and sl.is_active
        and sp.status='active'
        and sp.profile_type in ('TIE','VEN')
        and coalesce(sd.is_active,true)
        and coalesce(sd.is_open,true)
        and (v_seller_public is null or sp.public_id=v_seller_public)
        and (
          select count(*)
          from public.operational_locations o2
          where o2.owner_profile_id=sp.id
            and o2.purpose='STORE_PICKUP'
            and o2.active
            and o2.network_enabled
            and o2.verification_status='VERIFIED'
        )=1
        and (
          i.quantity_committed-i.quantity_reserved-i.quantity_consumed
        ) >= v_qty + coalesce((
          select sum((e->>'quantity')::bigint)
          from jsonb_array_elements(v_lines) e
          where (e->>'listing_id')::uuid=sl.id
        ),0)
        and exists(
          select 1
          from unnest(v_targets) t(node_id)
          where public.tc_quote_structural_path_exists(
            ol.id,t.node_id,
            coalesce(pv.weight_kg,0)*v_qty,
            coalesce(pv.volume_m3,0)*v_qty,
            8
          )
        )
      order by
        case
          when sc.id=v_dest_community then 0
          when sm.id=v_dest_municipality then 1
          when sdep.id=v_dest_department then 2
          else 3
        end,
        sl.price_minor asc,
        sl.public_id asc
      limit 1;

      if v_candidate.listing_id is null then
        raise exception using errcode='P0001', message='TC_NO_ELIGIBLE_SOURCE';
      end if;

      v_listing:=v_candidate.listing_id;
      v_variant:=v_candidate.variant_id;
      v_store:=v_candidate.store_id;
      v_store_public:=v_candidate.store_public_id;
      v_price:=v_candidate.price_minor;
      v_currency:=v_candidate.currency;
      v_seller_name:=v_candidate.seller_name;
      v_weight:=v_candidate.total_weight;
      v_volume:=v_candidate.total_volume;
      v_source_node:=v_candidate.source_node;
    end if;

    if v_quote_currency is null then
      v_quote_currency:=v_currency;
    elsif v_quote_currency<>v_currency then
      raise exception using errcode='P0001', message='TC_CURRENCY_MISMATCH';
    end if;

    v_line_no:=v_line_no+1;
    v_line_total:=v_price*v_qty;
    v_total:=v_total+v_line_total;

    v_lines:=v_lines || jsonb_build_array(jsonb_build_object(
      'line_no',v_line_no,
      'variant_id',v_variant,
      'listing_id',v_listing,
      'store_profile_id',v_store,
      'store_profile_public_id',v_store_public,
      'source_operational_location_id',v_source_node,
      'quantity',v_qty,
      'unit_price_minor',v_price,
      'line_total_minor',v_line_total,
      'source_mode',v_source_mode,
      'seller_display_name',v_seller_name,
      'sold_by_label','Vendido por'
    ));
  end loop;

  if v_line_no<1 or v_quote_currency is null then
    raise exception using errcode='P0001', message='TC_INVALID_ITEMS_PAYLOAD';
  end if;

  insert into public.checkout_quotes(
    client_profile_id,destination_type,destination_id,
    currency,total_minor,status,request_hash
  ) values(
    v_client,v_dest_type,
    case when v_dest_type='PTC' then upper(v_dest_id) else v_dest_id end,
    v_quote_currency,v_total,'OPEN',v_hash
  )
  returning id,public_id into v_quote,v_quote_public;

  for v_item in
    select value from jsonb_array_elements(v_lines)
  loop
    insert into public.checkout_quote_lines(
      quote_id,line_no,variant_id,listing_id,store_profile_id,
      source_operational_location_id,quantity,unit_price_minor,line_total_minor,
      source_mode,seller_display_name
    ) values(
      v_quote,
      (v_item->>'line_no')::integer,
      (v_item->>'variant_id')::uuid,
      (v_item->>'listing_id')::uuid,
      (v_item->>'store_profile_id')::uuid,
      (v_item->>'source_operational_location_id')::uuid,
      (v_item->>'quantity')::bigint,
      (v_item->>'unit_price_minor')::bigint,
      (v_item->>'line_total_minor')::bigint,
      v_item->>'source_mode',
      v_item->>'seller_display_name'
    );
  end loop;

  v_result:=jsonb_build_object(
    'success',true,
    'quote_public_id',v_quote_public,
    'currency',v_quote_currency,
    'merchandise_total_minor',v_total,
    'fees_minor',0,
    'total_minor',v_total,
    'inventory_reserved',false,
    'payment_required',true,
    'lines',v_lines
  );

  update public.idempotency_records
     set status='COMPLETED',
         response_payload=v_result,
         completed_at=now()
   where operation_type='QUOTE_CHECKOUT'
     and idempotency_key=v_key
     and person_id=v_person
     and request_hash=v_hash;

  return v_result;
end;
$function$;

revoke all on function public.tc_quote_checkout(text,text,text,jsonb,text)
  from public,anon;
grant execute on function public.tc_quote_checkout(text,text,text,jsonb,text)
  to authenticated,service_role;

comment on function public.tc_quote_checkout(text,text,text,jsonb,text) is
'Authenticated checkout quote. Supports source mode C: explicit listing/seller choice or deterministic automatic sourcing. Creates no inventory reservation. Automatic selection ranks same community, municipality, department, then outside; within tier lower price and stable listing ID. Only structurally reachable verified network sources qualify. Seller is returned only as independent attribution for UI: "Vendido por: <seller_display_name>".';


create or replace function public.tc_create_last_mile_task(
  p_origin_location_public_id text,
  p_package_public_ids text[],
  p_earliest_ready_at timestamptz default null,
  p_latest_delivery_at timestamptz default null
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_origin public.operational_locations%rowtype;
  v_requested integer;
  v_resolved integer;
  v_destination_version uuid;
  v_destination_versions uuid[];
  v_package_ids uuid[];
  v_package_string text;
  v_task_key text;
  v_task uuid;
  v_task_public text;
  v_weight numeric;
  v_volume numeric;
  v_cold boolean;
  v_fragile boolean;
  v_refresh jsonb;
begin
  if p_package_public_ids is null or cardinality(p_package_public_ids)<1 then
    raise exception using errcode='P0001', message='TC_EMPTY_EVENT_PACKAGE_SET';
  end if;

  select * into v_origin
  from public.operational_locations o
  where o.public_id=upper(btrim(coalesce(p_origin_location_public_id,'')))
    and o.active and o.network_enabled;

  if v_origin.id is null or v_origin.owner_profile_id is null then
    raise exception using errcode='P0001', message='TC_LAST_MILE_ORIGIN_NODE_INVALID';
  end if;

  select count(distinct upper(btrim(x)))
    into v_requested
  from unnest(p_package_public_ids) x
  where nullif(btrim(x),'') is not null;

  select
    array_agg(p.id order by p.public_id),
    count(*),
    string_agg(p.public_id,'|' order by p.public_id),
    sum(p.weight_kg),
    sum(p.volume_m3),
    bool_or(p.requires_cold_chain),
    bool_or(p.requires_fragile_handling)
  into
    v_package_ids,v_resolved,v_package_string,
    v_weight,v_volume,v_cold,v_fragile
  from public.packages p
  where p.public_id in (
    select distinct upper(btrim(x))
    from unnest(p_package_public_ids) x
    where nullif(btrim(x),'') is not null
  )
    and p.current_custodian_id=v_origin.owner_profile_id;

  if v_requested<1 or v_resolved<>v_requested then
    raise exception using errcode='P0001', message='TC_LAST_MILE_PACKAGE_NOT_AT_ORIGIN';
  end if;

  select array_agg(distinct o.destination_contract_id)
    into v_destination_versions
  from public.packages p
  join public.sub_orders so on so.id=p.sub_order_id
  join public.orders o on o.id=so.order_id
  where p.id=any(v_package_ids)
    and o.destination_contract_id is not null;

  if cardinality(v_destination_versions)<>1 then
    raise exception using errcode='P0001', message='TC_LAST_MILE_SINGLE_PRIVATE_DESTINATION_REQUIRED';
  end if;

  v_destination_version:=v_destination_versions[1];

  if not exists(
    select 1
    from public.logistics_destination_versions dsv
    join public.private_destination_snapshots pds
      on pds.id=dsv.private_snapshot_id
    join public.service_coverage sc
      on sc.community_id=dsv.community_id
     and sc.is_active
     and sc.home_delivery_available
    where dsv.id=v_destination_version
      and dsv.target_kind='PRIVATE_LOCATION'
  ) then
    raise exception using errcode='P0001', message='TC_HOME_DELIVERY_NOT_AVAILABLE';
  end if;

  if p_latest_delivery_at is not null
     and p_earliest_ready_at is not null
     and p_latest_delivery_at<p_earliest_ready_at then
    raise exception using errcode='P0001', message='TC_LAST_MILE_TIME_WINDOW_INVALID';
  end if;

  v_task_key:=encode(
    extensions.digest(
      convert_to(
        v_origin.id::text||'|'||v_destination_version::text||'|'||v_package_string,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  select t.id,t.public_id into v_task,v_task_public
  from public.logistics_last_mile_tasks t
  where t.task_key=v_task_key;

  if v_task is null then
    insert into public.logistics_last_mile_tasks(
      task_key,origin_operational_location_id,destination_version_id,
      state,total_weight_kg,total_volume_m3,package_count,
      requires_cold_chain,requires_fragile_handling,requires_bulky,
      earliest_ready_at,latest_delivery_at
    ) values(
      v_task_key,v_origin.id,v_destination_version,
      'PENDING',coalesce(v_weight,0),coalesce(v_volume,0),v_resolved,
      coalesce(v_cold,false),coalesce(v_fragile,false),false,
      p_earliest_ready_at,p_latest_delivery_at
    )
    returning id,public_id into v_task,v_task_public;

    insert into public.logistics_last_mile_task_packages(task_id,package_id)
    select v_task,unnest(v_package_ids);
  end if;

  v_refresh:=public.tc_refresh_last_mile_matches(v_task);

  return jsonb_build_object(
    'task_public_id',v_task_public,
    'task_id',v_task,
    'match_refresh',v_refresh
  );
end;
$$;

revoke all on function public.tc_create_last_mile_task(text,text[],timestamptz,timestamptz)
  from public,anon,authenticated;
grant execute on function public.tc_create_last_mile_task(text,text[],timestamptz,timestamptz)
  to service_role;


create or replace function public.tc_require_my_con_profile(
  p_con_public_id text
)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return public.tc_require_active_profile(
    p_con_public_id,'CON'
  );
end;
$$;

create or replace function public.tc_require_my_rsg_profile(
  p_rsg_public_id text
)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return public.tc_require_active_profile(
    p_rsg_public_id,'RSG'
  );
end;
$$;

revoke all on function public.tc_require_my_con_profile(text)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_require_my_rsg_profile(text)
  from public,anon,authenticated,service_role;

create or replace function public.tc_con_my_context()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_active uuid;
  v_profiles jsonb;
begin
  v_active:=public.tc_active_profile_id();

  if v_active is null then
    raise exception using errcode='P0001', message='TC_ACTIVE_PROFILE_NOT_SELECTED';
  end if;

  if not exists(
    select 1 from public.profiles p
    where p.id=v_active
      and p.profile_type='CON'
      and p.status='active'
  ) then
    raise exception using errcode='P0001', message='TC_ACTIVE_PROFILE_TYPE_MISMATCH';
  end if;

  select jsonb_build_array(
    jsonb_build_object(
      'con_public_id',p.public_id,
      'territory_id',p.territory_id,
      'vehicles',coalesce((
        select jsonb_agg(jsonb_build_object(
          'vehicle_public_id',v.public_id,
          'transport_type',v.transport_type,
          'plate_number',v.plate_number,
          'max_weight_kg',v.max_weight_kg,
          'max_volume_m3',v.max_volume_m3,
          'max_packages',v.max_packages,
          'supports_cold_chain',v.supports_cold_chain,
          'supports_fragile',v.supports_fragile,
          'supports_bulky',v.supports_bulky,
          'supports_rural_cargo',v.supports_rural_cargo,
          'valid_from',a.valid_from,
          'valid_until',a.valid_until
        ) order by v.public_id)
        from public.driver_vehicle_authorizations a
        join public.vehicles v on v.id=a.vehicle_id
        where a.driver_profile_id=p.id
          and a.is_active
          and v.is_active
      ),'[]'::jsonb)
    )
  )
  into v_profiles
  from public.profiles p
  where p.id=v_active;

  return jsonb_build_object(
    'con_profiles',coalesce(v_profiles,'[]'::jsonb),
    'con_profile_count',case when v_profiles is null then 0 else 1 end
  );
end;
$$;

create or replace function public.tc_con_network_nodes(
  p_search text default null,
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_active uuid;
  v_result jsonb;
  v_q text:=nullif(btrim(coalesce(p_search,'')),'');
begin
  v_active:=public.tc_active_profile_id();

  if v_active is null then
    raise exception using errcode='P0001', message='TC_ACTIVE_PROFILE_NOT_SELECTED';
  end if;

  if not exists(
    select 1 from public.profiles p
    where p.id=v_active
      and p.profile_type='CON'
      and p.status='active'
  ) then
    raise exception using errcode='P0001', message='TC_ACTIVE_PROFILE_TYPE_MISMATCH';
  end if;

  if p_limit<1 or p_limit>250 then
    raise exception using errcode='P0001', message='TC_LIMIT_INVALID';
  end if;

  select coalesce(jsonb_agg(x.obj order by x.department_name,x.municipality_name,x.community_name,x.name),'[]'::jsonb)
  into v_result
  from (
    select
      d.name as department_name,
      m.name as municipality_name,
      c.name as community_name,
      o.name,
      jsonb_build_object(
        'node_public_id',o.public_id,
        'name',o.name,
        'purpose',o.purpose,
        'community_name',c.name,
        'municipality_name',m.name,
        'department_name',d.name,
        'lat',case when o.point is null then null else extensions.st_y(o.point::extensions.geometry) end,
        'lng',case when o.point is null then null else extensions.st_x(o.point::extensions.geometry) end,
        'visual_reference',o.visual_reference
      ) as obj
    from public.operational_locations o
    join public.communities c on c.id=o.community_id
    join public.municipalities m on m.id=o.municipality_id
    join public.departments d on d.id=o.department_id
    where o.active
      and o.network_enabled
      and (
        v_q is null
        or o.name ilike '%'||v_q||'%'
        or c.name ilike '%'||v_q||'%'
        or m.name ilike '%'||v_q||'%'
        or d.name ilike '%'||v_q||'%'
      )
    order by d.name,m.name,c.name,o.name,o.public_id
    limit p_limit
  ) x;

  return v_result;
end;
$$;

create or replace function public.tc_rsg_my_context()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_active uuid;
  v_profiles jsonb;
begin
  v_active:=public.tc_active_profile_id();

  if v_active is null then
    raise exception using errcode='P0001', message='TC_ACTIVE_PROFILE_NOT_SELECTED';
  end if;

  if not exists(
    select 1 from public.profiles p
    where p.id=v_active
      and p.profile_type='RSG'
      and p.status='active'
  ) then
    raise exception using errcode='P0001', message='TC_ACTIVE_PROFILE_TYPE_MISMATCH';
  end if;

  select jsonb_build_array(jsonb_build_object(
    'rsg_public_id',p.public_id,
    'territory_id',p.territory_id,
    'availabilities',coalesce((
      select jsonb_agg(jsonb_build_object(
        'availability_public_id',a.public_id,
        'community_public_id',c.public_id,
        'community_name',c.name,
        'service_mode',a.service_mode,
        'state',a.state,
        'available_weight_kg',a.available_weight_kg,
        'available_volume_m3',a.available_volume_m3,
        'available_packages',a.available_packages,
        'supports_cold_chain',a.supports_cold_chain,
        'supports_fragile',a.supports_fragile,
        'supports_bulky',a.supports_bulky,
        'max_radius_km',a.max_radius_km,
        'available_from',a.available_from,
        'available_until',a.available_until
      ) order by a.created_at desc,a.public_id)
      from public.logistics_rsg_availability a
      join public.communities c on c.id=a.community_id
      where a.rsg_profile_id=p.id
    ),'[]'::jsonb)
  ))
  into v_profiles
  from public.profiles p
  where p.id=v_active;

  return jsonb_build_object(
    'rsg_profiles',coalesce(v_profiles,'[]'::jsonb),
    'rsg_profile_count',case when v_profiles is null then 0 else 1 end
  );
end;
$$;

create or replace function public.tc_release_last_mile_to_rsg(
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
  v_movement public.movements%rowtype;
  v_actor uuid;
  v_active uuid;
  v_ids uuid[];
  v_requested integer;
  v_resolved integer;
begin
  v_active:=public.tc_active_profile_id();

  if v_active is null then
    raise exception using errcode='P0001', message='TC_ACTIVE_PROFILE_NOT_SELECTED';
  end if;

  select * into v_movement
  from public.movements mv
  where mv.public_id=upper(btrim(coalesce(p_movement_public_id,'')));

  if v_movement.id is null or v_movement.from_profile_id is null then
    raise exception using errcode='P0001', message='TC_LAST_MILE_MOVEMENT_NOT_FOUND';
  end if;

  v_actor:=v_movement.from_profile_id;

  if v_active is distinct from v_actor then
    raise exception using errcode='P0001', message='TC_ACTIVE_PROFILE_REQUIRED';
  end if;

  select
    array_agg(p.id order by p.public_id),
    count(*)
  into v_ids,v_resolved
  from public.packages p
  join public.movement_packages mp
    on mp.package_id=p.id
   and mp.movement_id=v_movement.id
  where p.public_id in (
    select distinct upper(btrim(x))
    from unnest(p_package_public_ids) x
    where nullif(btrim(x),'') is not null
  );

  select count(distinct upper(btrim(x))) into v_requested
  from unnest(p_package_public_ids) x
  where nullif(btrim(x),'') is not null;

  if v_requested is null or v_requested<1 or v_resolved<>v_requested then
    raise exception using errcode='P0001', message='TC_PACKAGE_NOT_IN_MOVEMENT';
  end if;

  return public.tc_apply_last_mile_pickup_release(
    v_movement.id,v_ids,v_actor,p_idempotency_key,p_occurred_at
  );
end;
$$;

create or replace function public.tc_render_final_delivery_label(
  p_package_public_id text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_pkg public.packages%rowtype;
  v_task public.logistics_last_mile_tasks%rowtype;
  v_assignment public.logistics_last_mile_assignments%rowtype;
  v_origin_owner uuid;
  v_snapshot public.private_destination_snapshots%rowtype;
  v_community text;
  v_municipality text;
  v_department text;
  v_active uuid;
begin
  v_active:=public.tc_active_profile_id();

  if v_active is null then
    raise exception using errcode='P0001', message='TC_ACTIVE_PROFILE_NOT_SELECTED';
  end if;

  select * into v_pkg
  from public.packages p
  where p.public_id=upper(btrim(coalesce(p_package_public_id,'')));

  if v_pkg.id is null then
    raise exception using errcode='P0001', message='TC_NOT_FOUND';
  end if;

  select t.* into v_task
  from public.logistics_last_mile_task_packages tp
  join public.logistics_last_mile_tasks t on t.id=tp.task_id
  where tp.package_id=v_pkg.id
    and t.state in ('ASSIGNED','PICKED_UP','OUT_FOR_DELIVERY')
  order by t.created_at desc
  limit 1;

  if v_task.id is null then
    raise exception using errcode='P0001', message='TC_FINAL_MILE_ASSIGNMENT_REQUIRED';
  end if;

  select * into v_assignment
  from public.logistics_last_mile_assignments a
  where a.task_id=v_task.id
    and a.state='ACTIVE'
  order by a.accepted_at desc
  limit 1;

  select o.owner_profile_id into v_origin_owner
  from public.operational_locations o
  where o.id=v_task.origin_operational_location_id;

  if v_active is distinct from v_assignment.rsg_profile_id
     and not (
       v_active=v_origin_owner
       and v_pkg.current_custodian_id=v_origin_owner
     ) then
    raise exception using errcode='P0001', message='TC_FINAL_DELIVERY_LABEL_FORBIDDEN';
  end if;

  select pds.* into v_snapshot
  from public.logistics_destination_versions dsv
  join public.private_destination_snapshots pds
    on pds.id=dsv.private_snapshot_id
  where dsv.id=v_task.destination_version_id
    and dsv.target_kind='PRIVATE_LOCATION';

  if v_snapshot.id is null then
    raise exception using errcode='P0001', message='TC_FINAL_DELIVERY_DESTINATION_UNRESOLVED';
  end if;

  select c.name,m.name,d.name
    into v_community,v_municipality,v_department
  from public.communities c
  join public.municipalities m on m.id=c.municipality_id
  join public.departments d on d.id=m.department_id
  where c.id=v_snapshot.community_id;

  return jsonb_build_object(
    'package_public_id',v_pkg.public_id,
    'qr_value',v_pkg.public_id,
    'barcode_value',v_pkg.public_id,
    'recipient_name',v_snapshot.recipient_name,
    'address_text',concat_ws(', ',v_snapshot.label,v_community,v_municipality,v_department),
    'address',jsonb_build_object(
      'label',v_snapshot.label,
      'community',v_community,
      'municipality',v_municipality,
      'department',v_department
    )
  );
end;
$$;

revoke all on function public.tc_con_my_context()
  from public,anon,authenticated,service_role;
revoke all on function public.tc_con_network_nodes(text,integer)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_rsg_my_context()
  from public,anon,authenticated,service_role;
revoke all on function public.tc_release_last_mile_to_rsg(text,text[],text,timestamptz)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_render_final_delivery_label(text)
  from public,anon,authenticated,service_role;

grant execute on function public.tc_con_my_context() to authenticated;
grant execute on function public.tc_con_network_nodes(text,integer) to authenticated;
grant execute on function public.tc_rsg_my_context() to authenticated;
grant execute on function public.tc_release_last_mile_to_rsg(text,text[],text,timestamptz) to authenticated;
grant execute on function public.tc_render_final_delivery_label(text) to authenticated;

drop policy if exists evidence_read on public.evidence;

create policy evidence_read
on public.evidence
for select
to authenticated
using (
  (
    evidence_type like 'LAST_MILE_%'
    and (
      uploader_profile_id=public.tc_active_profile_id()
      or exists(
        select 1
        from public.packages p
        join public.sub_orders so on so.id=p.sub_order_id
        join public.orders o on o.id=so.order_id
        where p.id=evidence.package_id
          and o.client_profile_id=public.tc_active_profile_id()
      )
    )
  )
  or
  (
    evidence_type not like 'LAST_MILE_%'
    and (
      uploader_profile_id in (
        select profile_id
        from public.current_user_profile_ids()
      )
      or package_id in (
        select p.id from public.packages p
      )
    )
  )
);

comment on policy evidence_read on public.evidence is
'LAST_MILE evidence is role-context scoped: only the active uploader profile or active CLI owner of the order may read it. Other legacy evidence retains previous account-wide semantics.';

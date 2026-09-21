
create or replace function public.tc_require_my_con_profile(
  p_con_public_id text
)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_profile uuid;
begin
  if auth.uid() is null then
    raise exception using errcode='P0001', message='TC_UNAUTHENTICATED';
  end if;

  select p.id into v_profile
  from public.profiles p
  join public.persons per on per.id=p.person_id
  where per.auth_user_id=auth.uid()
    and p.public_id=upper(btrim(coalesce(p_con_public_id,'')))
    and p.profile_type='CON'
    and p.status='active';

  if v_profile is null then
    raise exception using errcode='P0001', message='TC_CON_PROFILE_FORBIDDEN';
  end if;

  return v_profile;
end;
$$;

create or replace function public.tc_con_my_context()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_person uuid;
  v_profiles jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode='P0001', message='TC_UNAUTHENTICATED';
  end if;

  select per.id into v_person
  from public.persons per
  where per.auth_user_id=auth.uid();

  if v_person is null then
    raise exception using errcode='P0001', message='TC_SESSION_PERSON_NOT_FOUND';
  end if;

  select coalesce(jsonb_agg(
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
    order by p.public_id
  ),'[]'::jsonb)
  into v_profiles
  from public.profiles p
  where p.person_id=v_person
    and p.profile_type='CON'
    and p.status='active';

  return jsonb_build_object(
    'con_profiles',v_profiles,
    'con_profile_count',jsonb_array_length(v_profiles)
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
  v_exists boolean;
  v_result jsonb;
  v_q text:=nullif(btrim(coalesce(p_search,'')),'');
begin
  if auth.uid() is null then
    raise exception using errcode='P0001', message='TC_UNAUTHENTICATED';
  end if;

  select exists(
    select 1
    from public.profiles p
    join public.persons per on per.id=p.person_id
    where per.auth_user_id=auth.uid()
      and p.profile_type='CON'
      and p.status='active'
  ) into v_exists;

  if not v_exists then
    raise exception using errcode='P0001', message='TC_CON_PROFILE_REQUIRED';
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

revoke all on function public.tc_require_my_con_profile(text)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_con_my_context()
  from public,anon,authenticated,service_role;
revoke all on function public.tc_con_network_nodes(text,integer)
  from public,anon,authenticated,service_role;

grant execute on function public.tc_con_my_context()
  to authenticated;
grant execute on function public.tc_con_network_nodes(text,integer)
  to authenticated;

comment on function public.tc_require_my_con_profile(text) is
'Private authenticated subprofile resolver. Never infers which CON subprofile to use when one person owns multiple active CON profiles.';

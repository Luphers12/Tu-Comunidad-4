
create or replace function public.tc_require_my_rsg_profile(
  p_rsg_public_id text
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
    and p.public_id=upper(btrim(coalesce(p_rsg_public_id,'')))
    and p.profile_type='RSG'
    and p.status='active';

  if v_profile is null then
    raise exception using errcode='P0001', message='TC_RSG_PROFILE_FORBIDDEN';
  end if;

  return v_profile;
end;
$$;

revoke all on function public.tc_require_my_rsg_profile(text)
  from public,anon,authenticated,service_role;

create or replace function public.tc_rsg_my_context()
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

  select coalesce(jsonb_agg(jsonb_build_object(
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
  ) order by p.public_id),'[]'::jsonb)
  into v_profiles
  from public.profiles p
  where p.person_id=v_person
    and p.profile_type='RSG'
    and p.status='active';

  return jsonb_build_object(
    'rsg_profiles',v_profiles,
    'rsg_profile_count',jsonb_array_length(v_profiles)
  );
end;
$$;

create or replace function public.tc_rsg_set_availability(
  p_rsg_public_id text,
  p_community_public_id text,
  p_service_mode text,
  p_state text,
  p_available_weight_kg numeric,
  p_available_volume_m3 numeric,
  p_available_packages integer,
  p_supports_cold_chain boolean default false,
  p_supports_fragile boolean default false,
  p_supports_bulky boolean default false,
  p_max_radius_km numeric default null,
  p_available_from timestamptz default null,
  p_available_until timestamptz default null,
  p_vehicle_public_id text default null,
  p_availability_public_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rsg uuid;
  v_community uuid;
  v_mode text:=upper(btrim(coalesce(p_service_mode,'')));
  v_state text:=upper(btrim(coalesce(p_state,'')));
  v_vehicle uuid;
  v_availability uuid;
  v_public text;
  v_used_weight numeric:=0;
  v_used_volume numeric:=0;
  v_used_packages integer:=0;
  v_refreshed integer:=0;
  v_task record;
begin
  v_rsg:=public.tc_require_my_rsg_profile(p_rsg_public_id);

  if v_mode not in ('RSG_MOTO','RSG_CAR','WALK') then
    raise exception using errcode='P0001', message='TC_RSG_SERVICE_MODE_INVALID';
  end if;

  if v_state not in ('AVAILABLE','PAUSED','OFFLINE') then
    raise exception using errcode='P0001', message='TC_RSG_AVAILABILITY_STATE_INVALID';
  end if;

  if p_available_weight_kg is null or p_available_weight_kg<0
     or p_available_volume_m3 is null or p_available_volume_m3<0
     or p_available_packages is null or p_available_packages<0
     or (p_max_radius_km is not null and p_max_radius_km<=0)
     or (p_available_until is not null and p_available_from is not null
         and p_available_until<p_available_from) then
    raise exception using errcode='P0001', message='TC_RSG_AVAILABILITY_INPUT_INVALID';
  end if;

  select c.id into v_community
  from public.communities c
  where c.public_id=upper(btrim(coalesce(p_community_public_id,'')))
    and c.is_active;

  if v_community is null then
    raise exception using errcode='P0001', message='TC_RSG_COMMUNITY_NOT_FOUND';
  end if;

  if v_state='AVAILABLE' and not exists(
    select 1 from public.service_coverage sc
    where sc.community_id=v_community
      and sc.is_active
      and sc.home_delivery_available
  ) then
    raise exception using errcode='P0001', message='TC_HOME_DELIVERY_NOT_AVAILABLE';
  end if;

  if nullif(btrim(coalesce(p_vehicle_public_id,'')),'') is not null then
    select v.id into v_vehicle
    from public.vehicles v
    where v.public_id=upper(btrim(p_vehicle_public_id))
      and v.is_active
      and (
        v.owner_profile_id=v_rsg
        or exists(
          select 1 from public.driver_vehicle_authorizations a
          where a.vehicle_id=v.id
            and a.driver_profile_id=v_rsg
            and a.is_active
            and (p_available_from is null or a.valid_from<=p_available_from)
            and (a.valid_until is null or p_available_from is null or a.valid_until>=p_available_from)
        )
      );

    if v_vehicle is null then
      raise exception using errcode='P0001', message='TC_RSG_VEHICLE_FORBIDDEN';
    end if;
  end if;

  if nullif(btrim(coalesce(p_availability_public_id,'')),'') is null then
    insert into public.logistics_rsg_availability(
      rsg_profile_id,community_id,service_mode,vehicle_id,state,
      available_weight_kg,available_volume_m3,available_packages,
      supports_cold_chain,supports_fragile,supports_bulky,max_radius_km,
      available_from,available_until
    ) values(
      v_rsg,v_community,v_mode,v_vehicle,v_state,
      p_available_weight_kg,p_available_volume_m3,p_available_packages,
      coalesce(p_supports_cold_chain,false),
      coalesce(p_supports_fragile,false),
      coalesce(p_supports_bulky,false),
      p_max_radius_km,p_available_from,p_available_until
    )
    returning id,public_id into v_availability,v_public;
  else
    select a.id,a.public_id
      into v_availability,v_public
    from public.logistics_rsg_availability a
    where a.public_id=upper(btrim(p_availability_public_id))
      and a.rsg_profile_id=v_rsg
    for update;

    if v_availability is null then
      raise exception using errcode='P0001', message='TC_RSG_AVAILABILITY_NOT_FOUND';
    end if;

    select
      coalesce(sum(r.reserved_weight_kg),0),
      coalesce(sum(r.reserved_volume_m3),0),
      coalesce(sum(r.reserved_packages),0)
    into v_used_weight,v_used_volume,v_used_packages
    from public.logistics_rsg_capacity_reservations r
    where r.availability_id=v_availability
      and r.state='CONFIRMED';

    if p_available_weight_kg<v_used_weight
       or p_available_volume_m3<v_used_volume
       or p_available_packages<v_used_packages then
      raise exception using errcode='P0001', message='TC_RSG_AVAILABILITY_BELOW_RESERVED_CAPACITY';
    end if;

    update public.logistics_rsg_availability
       set community_id=v_community,
           service_mode=v_mode,
           vehicle_id=v_vehicle,
           state=v_state,
           available_weight_kg=p_available_weight_kg,
           available_volume_m3=p_available_volume_m3,
           available_packages=p_available_packages,
           supports_cold_chain=coalesce(p_supports_cold_chain,false),
           supports_fragile=coalesce(p_supports_fragile,false),
           supports_bulky=coalesce(p_supports_bulky,false),
           max_radius_km=p_max_radius_km,
           available_from=p_available_from,
           available_until=p_available_until,
           updated_at=now()
     where id=v_availability;
  end if;

  if v_state='AVAILABLE' then
    for v_task in
      select t.id
      from public.logistics_last_mile_tasks t
      join public.logistics_destination_versions dsv
        on dsv.id=t.destination_version_id
      where dsv.community_id=v_community
        and t.state in ('PENDING','OFFERED','RECOVERY')
      order by t.created_at
      limit 100
    loop
      perform public.tc_refresh_last_mile_matches(v_task.id);
      v_refreshed:=v_refreshed+1;
    end loop;
  end if;

  return jsonb_build_object(
    'availability_public_id',v_public,
    'state',v_state,
    'community_public_id',upper(btrim(p_community_public_id)),
    'refreshed_task_count',v_refreshed
  );
end;
$$;

create or replace function public.tc_rsg_list_my_opportunities(
  p_rsg_public_id text,
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_rsg uuid;
  v_limit integer;
  v_result jsonb;
begin
  v_rsg:=public.tc_require_my_rsg_profile(p_rsg_public_id);
  v_limit:=least(greatest(coalesce(p_limit,100),1),250);

  select coalesce(jsonb_agg(x.obj order by x.offered_at,x.match_public_id),'[]'::jsonb)
  into v_result
  from (
    select
      m.offered_at,
      m.public_id as match_public_id,
      jsonb_build_object(
        'match_public_id',m.public_id,
        'task_public_id',t.public_id,
        'availability_public_id',a.public_id,
        'service_mode',a.service_mode,
        'offered_at',m.offered_at,
        'origin',jsonb_build_object(
          'node_public_id',o.public_id,
          'name',o.name,
          'community_name',oc.name
        ),
        'destination_area',jsonb_build_object(
          'community_public_id',dc.public_id,
          'community_name',dc.name,
          'municipality_name',mun.name,
          'department_name',dep.name
        ),
        'requirements',jsonb_build_object(
          'package_count',t.package_count,
          'total_weight_kg',t.total_weight_kg,
          'total_volume_m3',t.total_volume_m3,
          'requires_cold_chain',t.requires_cold_chain,
          'requires_fragile_handling',t.requires_fragile_handling,
          'requires_bulky',t.requires_bulky,
          'earliest_ready_at',t.earliest_ready_at,
          'latest_delivery_at',t.latest_delivery_at
        )
      ) as obj
    from public.logistics_last_mile_matches m
    join public.logistics_last_mile_tasks t on t.id=m.task_id
    join public.logistics_rsg_availability a on a.id=m.availability_id
    join public.operational_locations o on o.id=t.origin_operational_location_id
    join public.communities oc on oc.id=o.community_id
    join public.logistics_destination_versions dsv on dsv.id=t.destination_version_id
    join public.communities dc on dc.id=dsv.community_id
    join public.municipalities mun on mun.id=dsv.municipality_id
    join public.departments dep on dep.id=dsv.department_id
    where m.rsg_profile_id=v_rsg
      and m.state='OFFERED'
    order by m.offered_at,m.public_id
    limit v_limit
  ) x;

  return v_result;
end;
$$;

create or replace function public.tc_rsg_respond_opportunity(
  p_rsg_public_id text,
  p_match_public_id text,
  p_action text,
  p_reason_code text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rsg uuid;
  v_match uuid;
  v_result jsonb;
  v_assignment_public text;
begin
  v_rsg:=public.tc_require_my_rsg_profile(p_rsg_public_id);

  select m.id into v_match
  from public.logistics_last_mile_matches m
  where m.public_id=upper(btrim(coalesce(p_match_public_id,'')))
    and m.rsg_profile_id=v_rsg;

  if v_match is null then
    raise exception using errcode='P0001', message='TC_RSG_OPPORTUNITY_NOT_FOUND';
  end if;

  v_result:=public.tc_respond_last_mile_match(
    v_match,v_rsg,p_action,p_reason_code
  );

  select a.public_id into v_assignment_public
  from public.logistics_last_mile_assignments a
  where a.match_id=v_match;

  return (v_result-'assignment_id'-'capacity_reservation_id')||
    jsonb_build_object(
      'match_public_id',upper(btrim(p_match_public_id)),
      'assignment_public_id',v_assignment_public
    );
end;
$$;

create or replace function public.tc_rsg_my_assignments(
  p_rsg_public_id text,
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_rsg uuid;
  v_limit integer;
  v_result jsonb;
begin
  v_rsg:=public.tc_require_my_rsg_profile(p_rsg_public_id);
  v_limit:=least(greatest(coalesce(p_limit,100),1),250);

  select coalesce(jsonb_agg(x.obj order by x.accepted_at desc,x.assignment_public_id),'[]'::jsonb)
  into v_result
  from (
    select
      a.accepted_at,
      a.public_id as assignment_public_id,
      jsonb_build_object(
        'assignment_public_id',a.public_id,
        'task_public_id',t.public_id,
        'state',a.state,
        'service_mode',av.service_mode,
        'accepted_at',a.accepted_at,
        'origin',jsonb_build_object(
          'node_public_id',o.public_id,
          'name',o.name,
          'community_name',oc.name
        ),
        'packages',coalesce((
          select jsonb_agg(jsonb_build_object(
            'package_public_id',p.public_id,
            'weight_kg',p.weight_kg,
            'volume_m3',p.volume_m3,
            'state',p.state
          ) order by p.public_id)
          from public.logistics_last_mile_task_packages tp
          join public.packages p on p.id=tp.package_id
          where tp.task_id=t.id
        ),'[]'::jsonb),
        'recipient',jsonb_build_object(
          'name',pds.recipient_name,
          'phone',pds.recipient_phone
        ),
        'destination',jsonb_build_object(
          'address_text',concat_ws(', ',pds.label,c.name,mun.name,dep.name),
          'label',pds.label,
          'community_name',c.name,
          'municipality_name',mun.name,
          'department_name',dep.name,
          'lat',case when pds.point is null then null else extensions.st_y(pds.point::extensions.geometry) end,
          'lng',case when pds.point is null then null else extensions.st_x(pds.point::extensions.geometry) end,
          'visual_reference',pds.visual_reference,
          'access_instructions',pds.access_instructions,
          'authorized_contact',pds.authorized_contact,
          'safe_location_ref',pds.safe_location_ref,
          'photo_refs',to_jsonb(pds.photo_refs)
        )
      ) as obj
    from public.logistics_last_mile_assignments a
    join public.logistics_last_mile_tasks t on t.id=a.task_id
    join public.logistics_rsg_availability av on av.id=(
      select m.availability_id
      from public.logistics_last_mile_matches m
      where m.id=a.match_id
    )
    join public.operational_locations o on o.id=t.origin_operational_location_id
    join public.communities oc on oc.id=o.community_id
    join public.logistics_destination_versions dsv on dsv.id=t.destination_version_id
    join public.private_destination_snapshots pds on pds.id=dsv.private_snapshot_id
    join public.communities c on c.id=pds.community_id
    join public.municipalities mun on mun.id=pds.municipality_id
    join public.departments dep on dep.id=pds.department_id
    where a.rsg_profile_id=v_rsg
      and a.state='ACTIVE'
    order by a.accepted_at desc,a.public_id
    limit v_limit
  ) x;

  return v_result;
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
  v_actor_ok boolean:=false;
begin
  if auth.uid() is null then
    raise exception using errcode='P0001', message='TC_UNAUTHENTICATED';
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

  select exists(
    select 1
    from public.profiles p
    join public.persons per on per.id=p.person_id
    where per.auth_user_id=auth.uid()
      and p.status='active'
      and (
        p.id=v_assignment.rsg_profile_id
        or (
          p.id=v_origin_owner
          and v_pkg.current_custodian_id=v_origin_owner
        )
      )
  ) into v_actor_ok;

  if not v_actor_ok then
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

revoke all on function public.tc_rsg_my_context()
  from public,anon,authenticated,service_role;
revoke all on function public.tc_rsg_set_availability(
  text,text,text,text,numeric,numeric,integer,boolean,boolean,boolean,numeric,timestamptz,timestamptz,text,text
) from public,anon,authenticated,service_role;
revoke all on function public.tc_rsg_list_my_opportunities(text,integer)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_rsg_respond_opportunity(text,text,text,text)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_rsg_my_assignments(text,integer)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_render_final_delivery_label(text)
  from public,anon,authenticated,service_role;

grant execute on function public.tc_rsg_my_context()
  to authenticated;
grant execute on function public.tc_rsg_set_availability(
  text,text,text,text,numeric,numeric,integer,boolean,boolean,boolean,numeric,timestamptz,timestamptz,text,text
) to authenticated;
grant execute on function public.tc_rsg_list_my_opportunities(text,integer)
  to authenticated;
grant execute on function public.tc_rsg_respond_opportunity(text,text,text,text)
  to authenticated;
grant execute on function public.tc_rsg_my_assignments(text,integer)
  to authenticated;
grant execute on function public.tc_render_final_delivery_label(text)
  to authenticated;

comment on function public.tc_rsg_list_my_opportunities(text,integer) is
'Pre-accept RSG opportunity feed: area and physical requirements only. No PKG identity, recipient name, exact private address or phone.';
comment on function public.tc_rsg_my_assignments(text,integer) is
'Post-accept assigned RSG digital view. May expose PKG ID, recipient name, private destination and recipient phone while assignment is active.';
comment on function public.tc_render_final_delivery_label(text) is
'Stage-aware physical final-delivery label. Includes PKG ID, recipient name and delivery address. Recipient phone is deliberately excluded.';

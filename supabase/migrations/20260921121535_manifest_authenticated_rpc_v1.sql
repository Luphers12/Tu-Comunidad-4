
create or replace function public.tc_con_my_manifests(
  p_con_public_id text,
  p_trip_public_id text default null,
  p_include_history boolean default false,
  p_limit integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_con uuid;
  v_trip_filter text:=nullif(upper(btrim(coalesce(p_trip_public_id,''))),'');
  v_limit integer;
  v_result jsonb;
begin
  v_con:=public.tc_require_my_con_profile(p_con_public_id);
  v_limit:=least(greatest(coalesce(p_limit,50),1),100);

  if v_trip_filter is not null and not exists(
    select 1
    from public.logistics_trips t
    where t.public_id=v_trip_filter
      and t.driver_profile_id=v_con
  ) then
    raise exception using errcode='P0001', message='TC_CON_TRIP_NOT_FOUND';
  end if;

  select coalesce(jsonb_agg(x.payload order by x.published_at desc,x.version_no desc),'[]'::jsonb)
  into v_result
  from (
    select
      m.published_at,
      m.version_no,
      public.tc_manifest_safe_payload(m.id) as payload
    from public.logistics_manifests m
    join public.logistics_trips t on t.id=m.trip_id
    where t.driver_profile_id=v_con
      and (v_trip_filter is null or t.public_id=v_trip_filter)
      and (
        coalesce(p_include_history,false)
        or not exists(
          select 1
          from public.logistics_manifests newer
          where newer.supersedes_manifest_id=m.id
        )
      )
    order by m.published_at desc,m.version_no desc,m.id desc
    limit v_limit
  ) x;

  return v_result;
end;
$$;

create or replace function public.tc_node_my_manifest_view(
  p_node_public_id text,
  p_include_history boolean default false,
  p_limit integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_active uuid;
  v_type text;
  v_node public.operational_locations%rowtype;
  v_limit integer;
  v_result jsonb;
begin
  v_active:=public.tc_active_profile_id();

  if v_active is null then
    raise exception using errcode='P0001', message='TC_ACTIVE_PROFILE_NOT_SELECTED';
  end if;

  select p.profile_type into v_type
  from public.profiles p
  where p.id=v_active
    and p.status='active';

  if v_type not in ('TIE','PTC') then
    raise exception using errcode='P0001', message='TC_NODE_MANIFEST_ROLE_FORBIDDEN';
  end if;

  select * into v_node
  from public.operational_locations o
  where o.public_id=upper(btrim(coalesce(p_node_public_id,'')))
    and o.active
    and o.network_enabled
    and o.owner_profile_id=v_active;

  if v_node.id is null then
    raise exception using errcode='P0001', message='TC_NODE_MANIFEST_NODE_FORBIDDEN';
  end if;

  v_limit:=least(greatest(coalesce(p_limit,50),1),100);

  select coalesce(jsonb_agg(x.obj order by x.published_at desc,x.version_no desc),'[]'::jsonb)
  into v_result
  from (
    select
      m.published_at,
      m.version_no,
      jsonb_build_object(
        'manifest_public_id',m.public_id,
        'manifest_type',m.manifest_type,
        'version_no',m.version_no,
        'published_at',m.published_at,
        'is_latest',not exists(
          select 1
          from public.logistics_manifests newer
          where newer.supersedes_manifest_id=m.id
        ),
        'trip',jsonb_build_object(
          'trip_public_id',t.public_id,
          'state',t.state,
          'vehicle_public_id',v.public_id,
          'transport_type',v.transport_type,
          'planned_departure_at',t.planned_departure_at,
          'planned_arrival_at',t.planned_arrival_at
        ),
        'node',jsonb_build_object(
          'node_public_id',v_node.public_id,
          'name',v_node.name,
          'community_name',nc.name,
          'stop_occurrences',coalesce((
            select jsonb_agg(jsonb_build_object(
              'stop_sequence',s.stop_sequence,
              'stop_kind',s.stop_kind,
              'planned_arrival_at',s.planned_arrival_at,
              'planned_departure_at',s.planned_departure_at
            ) order by s.stop_sequence)
            from public.logistics_trip_stops s
            where s.trip_id=t.id
              and s.operational_location_id=v_node.id
          ),'[]'::jsonb)
        ),
        'summary',jsonb_build_object(
          'visible_package_count',(
            select count(*)
            from public.logistics_manifest_items mi
            join public.packages p on p.id=mi.package_id
            where mi.manifest_id=m.id
              and exists(
                select 1
                from public.logistics_trip_stops s
                where s.trip_id=t.id
                  and s.operational_location_id=v_node.id
                  and s.stop_sequence between mi.board_stop_sequence and mi.alight_stop_sequence
              )
          ),
          'visible_total_weight_kg',coalesce((
            select sum(p.weight_kg)
            from public.logistics_manifest_items mi
            join public.packages p on p.id=mi.package_id
            where mi.manifest_id=m.id
              and exists(
                select 1
                from public.logistics_trip_stops s
                where s.trip_id=t.id
                  and s.operational_location_id=v_node.id
                  and s.stop_sequence between mi.board_stop_sequence and mi.alight_stop_sequence
              )
          ),0)
        ),
        'items',coalesce((
          select jsonb_agg(jsonb_build_object(
            'package_public_id',p.public_id,
            'demand_public_id',d.public_id,
            'movement_public_id',mv.public_id,
            'movement_state',mv.state,
            'weight_kg',p.weight_kg,
            'volume_m3',p.volume_m3,
            'requires_cold_chain',p.requires_cold_chain,
            'requires_fragile_handling',p.requires_fragile_handling,
            'node_actions',(
              select jsonb_agg(jsonb_build_object(
                'stop_sequence',s.stop_sequence,
                'action',case
                  when mi.board_stop_sequence=s.stop_sequence then 'SUBE'
                  when mi.alight_stop_sequence=s.stop_sequence then 'BAJA'
                  else 'CONTINUA'
                end
              ) order by s.stop_sequence)
              from public.logistics_trip_stops s
              where s.trip_id=t.id
                and s.operational_location_id=v_node.id
                and s.stop_sequence between mi.board_stop_sequence and mi.alight_stop_sequence
            )
          ) order by p.public_id)
          from public.logistics_manifest_items mi
          join public.packages p on p.id=mi.package_id
          join public.logistics_demands d on d.id=mi.demand_id
          left join public.movements mv on mv.id=mi.movement_id
          where mi.manifest_id=m.id
            and exists(
              select 1
              from public.logistics_trip_stops s
              where s.trip_id=t.id
                and s.operational_location_id=v_node.id
                and s.stop_sequence between mi.board_stop_sequence and mi.alight_stop_sequence
            )
        ),'[]'::jsonb)
      ) as obj
    from public.logistics_manifests m
    join public.logistics_trips t on t.id=m.trip_id
    join public.vehicles v on v.id=t.vehicle_id
    join public.communities nc on nc.id=v_node.community_id
    where exists(
      select 1
      from public.logistics_trip_stops s
      where s.trip_id=t.id
        and s.operational_location_id=v_node.id
    )
      and exists(
        select 1
        from public.logistics_manifest_items mi
        where mi.manifest_id=m.id
          and exists(
            select 1
            from public.logistics_trip_stops s
            where s.trip_id=t.id
              and s.operational_location_id=v_node.id
              and s.stop_sequence between mi.board_stop_sequence and mi.alight_stop_sequence
          )
      )
      and (
        coalesce(p_include_history,false)
        or not exists(
          select 1
          from public.logistics_manifests newer
          where newer.supersedes_manifest_id=m.id
        )
      )
    order by m.published_at desc,m.version_no desc,m.id desc
    limit v_limit
  ) x;

  return v_result;
end;
$$;

create or replace function public.tc_support_manifest_view(
  p_support_profile_public_id text,
  p_manifest_public_id text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_support uuid;
  v_type text;
  v_manifest uuid;
begin
  v_support:=public.tc_require_active_profile(
    p_support_profile_public_id,null
  );

  select p.profile_type into v_type
  from public.profiles p
  where p.id=v_support
    and p.status='active';

  if v_type not in ('SOP','ADM') then
    raise exception using errcode='P0001', message='TC_MANIFEST_SUPPORT_ROLE_FORBIDDEN';
  end if;

  if not public.internal_has_capability(
    v_support,
    'logistics.manifest.support.read'::varchar,
    'GLOBAL'::public.tc_scope_type,
    null
  ) then
    raise exception using errcode='P0001', message='TC_MANIFEST_SUPPORT_CAPABILITY_REQUIRED';
  end if;

  select m.id into v_manifest
  from public.logistics_manifests m
  where m.public_id=upper(btrim(coalesce(p_manifest_public_id,'')));

  if v_manifest is null then
    raise exception using errcode='P0001', message='TC_MANIFEST_NOT_FOUND';
  end if;

  return public.tc_manifest_safe_payload(v_manifest);
end;
$$;

revoke all on function public.tc_con_my_manifests(text,text,boolean,integer)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_node_my_manifest_view(text,boolean,integer)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_support_manifest_view(text,text)
  from public,anon,authenticated,service_role;

grant execute on function public.tc_con_my_manifests(text,text,boolean,integer)
  to authenticated;
grant execute on function public.tc_node_my_manifest_view(text,boolean,integer)
  to authenticated;
grant execute on function public.tc_support_manifest_view(text,text)
  to authenticated;

comment on function public.tc_con_my_manifests(text,text,boolean,integer) is
'Authenticated active-CON manifest feed for trips owned by that CON. PII-free.';
comment on function public.tc_node_my_manifest_view(text,boolean,integer) is
'Authenticated active node-owner view. Returns only manifest items whose segment touches that exact owned NODE and labels SUBE/BAJA/CONTINUA.';
comment on function public.tc_support_manifest_view(text,text) is
'Authenticated active SOP/ADM exact-manifest view requiring explicit global logistics.manifest.support.read capability. PII-free.';

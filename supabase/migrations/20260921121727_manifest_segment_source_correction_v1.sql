
create or replace function public.tc_manifest_safe_payload(
  p_manifest_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_manifest public.logistics_manifests%rowtype;
  v_trip public.logistics_trips%rowtype;
  v_vehicle_public text;
  v_transport_type text;
  v_supersedes_public text;
  v_is_latest boolean;
  v_stops jsonb;
  v_packages jsonb;
  v_package_count integer;
  v_segment_count integer;
  v_total_weight numeric;
  v_total_volume numeric;
begin
  select * into v_manifest
  from public.logistics_manifests m
  where m.id=p_manifest_id;

  if v_manifest.id is null then
    raise exception using errcode='P0001', message='TC_MANIFEST_NOT_FOUND';
  end if;

  select * into v_trip
  from public.logistics_trips t
  where t.id=v_manifest.trip_id;

  if v_trip.id is null then
    raise exception using errcode='P0001', message='TC_MANIFEST_TRIP_NOT_FOUND';
  end if;

  select v.public_id,v.transport_type
    into v_vehicle_public,v_transport_type
  from public.vehicles v
  where v.id=v_trip.vehicle_id;

  if v_manifest.supersedes_manifest_id is not null then
    select m.public_id into v_supersedes_public
    from public.logistics_manifests m
    where m.id=v_manifest.supersedes_manifest_id;
  end if;

  v_is_latest:=not exists(
    select 1
    from public.logistics_manifests newer
    where newer.supersedes_manifest_id=v_manifest.id
  );

  select coalesce(jsonb_agg(jsonb_build_object(
    'stop_sequence',s.stop_sequence,
    'stop_kind',s.stop_kind,
    'node_public_id',o.public_id,
    'node_name',o.name,
    'community_name',c.name,
    'planned_arrival_at',s.planned_arrival_at,
    'planned_departure_at',s.planned_departure_at
  ) order by s.stop_sequence),'[]'::jsonb)
  into v_stops
  from public.logistics_trip_stops s
  join public.operational_locations o on o.id=s.operational_location_id
  join public.communities c on c.id=o.community_id
  where s.trip_id=v_trip.id;

  select
    coalesce(jsonb_agg(pkg.obj order by pkg.package_public_id),'[]'::jsonb),
    count(*)::integer,
    coalesce(sum(pkg.weight_kg),0),
    coalesce(sum(pkg.volume_m3),0)
  into v_packages,v_package_count,v_total_weight,v_total_volume
  from (
    select
      p.public_id as package_public_id,
      p.weight_kg,
      p.volume_m3,
      jsonb_build_object(
        'package_public_id',p.public_id,
        'demand_public_id',d.public_id,
        'weight_kg',p.weight_kg,
        'volume_m3',p.volume_m3,
        'requires_cold_chain',p.requires_cold_chain,
        'requires_fragile_handling',p.requires_fragile_handling,
        'package_form',p.package_form,
        'package_state',p.state,
        'segments',coalesce((
          select jsonb_agg(jsonb_build_object(
            'segment_public_id',s.public_id,
            'match_public_id',mat.public_id,
            'reservation_public_id',r.public_id,
            'movement_public_id',mv.public_id,
            'movement_state',mv.state,
            'board_stop_sequence',s.board_stop_sequence,
            'alight_stop_sequence',s.alight_stop_sequence
          ) order by s.board_stop_sequence,s.alight_stop_sequence,s.public_id)
          from public.logistics_manifest_segments s
          join public.logistics_matches mat on mat.id=s.match_id
          join public.logistics_capacity_reservations r on r.id=s.capacity_reservation_id
          left join public.movements mv on mv.id=s.movement_id
          where s.manifest_id=v_manifest.id
            and s.package_id=p.id
            and s.demand_id=d.id
        ),'[]'::jsonb)
      ) as obj
    from (
      select distinct s.package_id,s.demand_id
      from public.logistics_manifest_segments s
      where s.manifest_id=v_manifest.id
    ) x
    join public.packages p on p.id=x.package_id
    join public.logistics_demands d on d.id=x.demand_id
  ) pkg;

  select count(*)::integer into v_segment_count
  from public.logistics_manifest_segments s
  where s.manifest_id=v_manifest.id;

  return jsonb_build_object(
    'manifest_public_id',v_manifest.public_id,
    'manifest_type',v_manifest.manifest_type,
    'version_no',v_manifest.version_no,
    'published_at',v_manifest.published_at,
    'supersedes_manifest_public_id',v_supersedes_public,
    'is_latest',v_is_latest,
    'trip',jsonb_build_object(
      'trip_public_id',v_trip.public_id,
      'state',v_trip.state,
      'vehicle_public_id',v_vehicle_public,
      'transport_type',v_transport_type,
      'planned_departure_at',v_trip.planned_departure_at,
      'planned_arrival_at',v_trip.planned_arrival_at
    ),
    'summary',jsonb_build_object(
      'package_count',coalesce(v_package_count,0),
      'segment_count',coalesce(v_segment_count,0),
      'total_weight_kg',coalesce(v_total_weight,0),
      'total_volume_m3',coalesce(v_total_volume,0)
    ),
    'stops',v_stops,
    'packages',v_packages
  );
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
        'packages',coalesce((
          select jsonb_agg(pkg.obj order by pkg.package_public_id)
          from (
            select
              p.public_id as package_public_id,
              jsonb_build_object(
                'package_public_id',p.public_id,
                'demand_public_id',d.public_id,
                'weight_kg',p.weight_kg,
                'volume_m3',p.volume_m3,
                'requires_cold_chain',p.requires_cold_chain,
                'requires_fragile_handling',p.requires_fragile_handling,
                'action',(
                  select case
                    when bool_or(sg.board_stop_sequence=ns.stop_sequence)
                         and bool_or(sg.alight_stop_sequence=ns.stop_sequence)
                         and count(distinct sg.movement_id) filter(where sg.movement_id is not null)=1
                      then 'CONTINUA'
                    when bool_or(sg.board_stop_sequence<ns.stop_sequence
                                 and sg.alight_stop_sequence>ns.stop_sequence)
                      then 'CONTINUA'
                    when bool_or(sg.board_stop_sequence=ns.stop_sequence)
                         and bool_or(sg.alight_stop_sequence=ns.stop_sequence)
                      then 'BAJA_Y_SUBE'
                    when bool_or(sg.board_stop_sequence=ns.stop_sequence)
                      then 'SUBE'
                    when bool_or(sg.alight_stop_sequence=ns.stop_sequence)
                      then 'BAJA'
                    else 'CONTINUA'
                  end
                  from public.logistics_trip_stops ns
                  join public.logistics_manifest_segments sg
                    on sg.manifest_id=m.id
                   and sg.package_id=p.id
                   and sg.demand_id=d.id
                   and ns.stop_sequence between sg.board_stop_sequence and sg.alight_stop_sequence
                  where ns.trip_id=t.id
                    and ns.operational_location_id=v_node.id
                ),
                'segments',coalesce((
                  select jsonb_agg(jsonb_build_object(
                    'segment_public_id',sg.public_id,
                    'match_public_id',mat.public_id,
                    'movement_public_id',mv.public_id,
                    'movement_state',mv.state,
                    'board_stop_sequence',sg.board_stop_sequence,
                    'alight_stop_sequence',sg.alight_stop_sequence
                  ) order by sg.board_stop_sequence,sg.alight_stop_sequence,sg.public_id)
                  from public.logistics_manifest_segments sg
                  join public.logistics_matches mat on mat.id=sg.match_id
                  left join public.movements mv on mv.id=sg.movement_id
                  where sg.manifest_id=m.id
                    and sg.package_id=p.id
                    and sg.demand_id=d.id
                    and exists(
                      select 1
                      from public.logistics_trip_stops ns
                      where ns.trip_id=t.id
                        and ns.operational_location_id=v_node.id
                        and ns.stop_sequence between sg.board_stop_sequence and sg.alight_stop_sequence
                    )
                ),'[]'::jsonb)
              ) as obj
            from (
              select distinct sg.package_id,sg.demand_id
              from public.logistics_manifest_segments sg
              where sg.manifest_id=m.id
                and exists(
                  select 1
                  from public.logistics_trip_stops ns
                  where ns.trip_id=t.id
                    and ns.operational_location_id=v_node.id
                    and ns.stop_sequence between sg.board_stop_sequence and sg.alight_stop_sequence
                )
            ) vis
            join public.packages p on p.id=vis.package_id
            join public.logistics_demands d on d.id=vis.demand_id
          ) pkg
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
        from public.logistics_manifest_segments sg
        where sg.manifest_id=m.id
          and exists(
            select 1
            from public.logistics_trip_stops ns
            where ns.trip_id=t.id
              and ns.operational_location_id=v_node.id
              and ns.stop_sequence between sg.board_stop_sequence and sg.alight_stop_sequence
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

revoke all on function public.tc_manifest_safe_payload(uuid)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_node_my_manifest_view(text,boolean,integer)
  from public,anon,authenticated,service_role;

grant execute on function public.tc_node_my_manifest_view(text,boolean,integer)
  to authenticated;

comment on function public.tc_manifest_safe_payload(uuid) is
'Private canonical PII-free manifest renderer sourced from logistics_manifest_segments, the append-only per-hop manifest source.';

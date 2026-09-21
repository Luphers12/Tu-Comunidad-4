
insert into public.capabilities(name)
values('logistics.manifest.support.read')
on conflict (name) do nothing;

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
  v_items jsonb;
  v_package_count integer;
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
    coalesce(jsonb_agg(jsonb_build_object(
      'package_public_id',p.public_id,
      'demand_public_id',d.public_id,
      'reservation_public_id',r.public_id,
      'movement_public_id',mv.public_id,
      'movement_state',mv.state,
      'board_stop_sequence',mi.board_stop_sequence,
      'alight_stop_sequence',mi.alight_stop_sequence,
      'weight_kg',p.weight_kg,
      'volume_m3',p.volume_m3,
      'requires_cold_chain',p.requires_cold_chain,
      'requires_fragile_handling',p.requires_fragile_handling,
      'package_form',p.package_form,
      'package_state',p.state
    ) order by mi.board_stop_sequence,mi.alight_stop_sequence,p.public_id),'[]'::jsonb),
    count(*)::integer,
    coalesce(sum(p.weight_kg),0),
    coalesce(sum(p.volume_m3),0)
  into v_items,v_package_count,v_total_weight,v_total_volume
  from public.logistics_manifest_items mi
  join public.packages p on p.id=mi.package_id
  join public.logistics_demands d on d.id=mi.demand_id
  join public.logistics_capacity_reservations r on r.id=mi.capacity_reservation_id
  left join public.movements mv on mv.id=mi.movement_id
  where mi.manifest_id=v_manifest.id;

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
      'total_weight_kg',coalesce(v_total_weight,0),
      'total_volume_m3',coalesce(v_total_volume,0)
    ),
    'stops',v_stops,
    'items',v_items
  );
end;
$$;

revoke all on function public.tc_manifest_safe_payload(uuid)
  from public,anon,authenticated,service_role;

comment on function public.tc_manifest_safe_payload(uuid) is
'Private PII-free manifest renderer. It intentionally does not read orders, persons, customer locations, private destination snapshots, phones, payment data or recipient identity.';

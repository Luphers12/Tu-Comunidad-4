
create or replace function public.tc_validate_manifest_segment()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_manifest_trip uuid;
  v_match public.logistics_matches%rowtype;
  v_reservation public.logistics_capacity_reservations%rowtype;
  v_movement_trip uuid;
begin
  select m.trip_id into v_manifest_trip
  from public.logistics_manifests m
  where m.id=new.manifest_id;

  select * into v_match
  from public.logistics_matches m
  where m.id=new.match_id;

  if v_match.id is null
     or v_match.state <> 'ACCEPTED'
     or v_match.trip_id is distinct from v_manifest_trip
     or v_match.demand_id is distinct from new.demand_id
     or v_match.routing_hop_id is distinct from new.routing_hop_id
     or v_match.capacity_reservation_id is distinct from new.capacity_reservation_id
     or v_match.board_stop_sequence is distinct from new.board_stop_sequence
     or v_match.alight_stop_sequence is distinct from new.alight_stop_sequence then
    raise exception using errcode='P0001', message='TC_MANIFEST_SEGMENT_MATCH_MISMATCH';
  end if;

  select * into v_reservation
  from public.logistics_capacity_reservations r
  where r.id=new.capacity_reservation_id;

  if v_reservation.id is null
     or v_reservation.trip_id is distinct from v_manifest_trip
     or v_reservation.demand_id is distinct from new.demand_id
     or v_reservation.state not in ('CONFIRMED','CONSUMED') then
    raise exception using errcode='P0001', message='TC_MANIFEST_SEGMENT_RESERVATION_MISMATCH';
  end if;

  if not exists (
    select 1
    from public.logistics_demand_packages dp
    where dp.demand_id=new.demand_id
      and dp.package_id=new.package_id
  ) then
    raise exception using errcode='P0001', message='TC_MANIFEST_SEGMENT_PACKAGE_NOT_IN_DEMAND';
  end if;

  if new.movement_id is not null then
    select m.logistics_trip_id into v_movement_trip
    from public.movements m
    where m.id=new.movement_id;

    if v_movement_trip is distinct from v_manifest_trip then
      raise exception using errcode='P0001', message='TC_MANIFEST_SEGMENT_MOVEMENT_TRIP_MISMATCH';
    end if;

    if not exists (
      select 1
      from public.movement_packages mp
      where mp.movement_id=new.movement_id
        and mp.package_id=new.package_id
    ) then
      raise exception using errcode='P0001', message='TC_MANIFEST_SEGMENT_PACKAGE_NOT_IN_MOVEMENT';
    end if;
  end if;

  return new;
end;
$$;

create trigger logistics_manifest_segments_validate
before insert on public.logistics_manifest_segments
for each row execute function public.tc_validate_manifest_segment();

revoke all on function public.tc_validate_manifest_segment()
  from public,anon,authenticated;
grant execute on function public.tc_validate_manifest_segment()
  to service_role;

create or replace function public.tc_rebuild_trip_manifest_snapshot(
  p_trip_id uuid,
  p_manifest_type text default 'LOAD_PLAN',
  p_created_by_person_id uuid default null
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_type text := upper(btrim(coalesce(p_manifest_type,'LOAD_PLAN')));
  v_latest_manifest uuid;
  v_latest_version bigint;
  v_manifest uuid;
begin
  if v_type not in ('LOAD_PLAN','DEPARTURE','IN_TRANSIT','ARRIVAL','RECOVERY') then
    raise exception using errcode='P0001', message='TC_MANIFEST_TYPE_INVALID';
  end if;

  perform 1
  from public.logistics_trips t
  where t.id=p_trip_id
  for update;

  if not found then
    raise exception using errcode='P0001', message='TC_TRIP_NOT_FOUND';
  end if;

  select m.id,m.version_no
    into v_latest_manifest,v_latest_version
  from public.logistics_manifests m
  where m.trip_id=p_trip_id
  order by m.version_no desc
  limit 1;

  insert into public.logistics_manifests(
    trip_id,version_no,manifest_type,
    supersedes_manifest_id,created_by_person_id,metadata
  ) values(
    p_trip_id,
    coalesce(v_latest_version,0)+1,
    v_type,
    v_latest_manifest,
    p_created_by_person_id,
    jsonb_build_object(
      'snapshot_scope','ALL_ACTIVE_ACCEPTED_MATCHES_ON_TRIP',
      'generated_by','tc_rebuild_trip_manifest_snapshot'
    )
  ) returning id into v_manifest;

  insert into public.logistics_manifest_segments(
    manifest_id,package_id,demand_id,routing_hop_id,match_id,
    capacity_reservation_id,board_stop_sequence,alight_stop_sequence,
    movement_id
  )
  select
    v_manifest,
    dp.package_id,
    mat.demand_id,
    mat.routing_hop_id,
    mat.id,
    mat.capacity_reservation_id,
    mat.board_stop_sequence,
    mat.alight_stop_sequence,
    he.movement_id
  from public.logistics_matches mat
  join public.logistics_capacity_reservations r
    on r.id=mat.capacity_reservation_id
   and r.state in ('CONFIRMED','CONSUMED')
  join public.logistics_demand_packages dp
    on dp.demand_id=mat.demand_id
  left join public.logistics_hop_executions he
    on he.match_id=mat.id
  where mat.trip_id=p_trip_id
    and mat.state='ACCEPTED'
  order by mat.board_stop_sequence,mat.alight_stop_sequence,dp.package_id;

  return v_manifest;
end;
$$;

revoke all on function public.tc_rebuild_trip_manifest_snapshot(uuid,text,uuid)
  from public,anon,authenticated;
grant execute on function public.tc_rebuild_trip_manifest_snapshot(uuid,text,uuid)
  to service_role;

comment on function public.tc_rebuild_trip_manifest_snapshot(uuid,text,uuid) is
'Creates the next immutable full-trip manifest snapshot from every active ACCEPTED match with confirmed/consumed capacity on the TRIP. This preserves consolidation across multiple demands and PKGs.';

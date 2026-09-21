
create or replace function public.tc_con_list_my_opportunities(
  p_con_public_id text,
  p_trip_public_id text default null,
  p_include_resolved boolean default false,
  p_limit integer default 100
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
  v_result jsonb;
begin
  v_con:=public.tc_require_my_con_profile(p_con_public_id);

  if p_limit<1 or p_limit>250 then
    raise exception using errcode='P0001', message='TC_LIMIT_INVALID';
  end if;

  select coalesce(jsonb_agg(x.obj order by x.offered_at,x.match_public_id),'[]'::jsonb)
  into v_result
  from (
    select
      m.offered_at,
      m.public_id as match_public_id,
      jsonb_build_object(
        'match_public_id',m.public_id,
        'state',m.state,
        'trip_public_id',t.public_id,
        'offered_at',m.offered_at,
        'responded_at',m.responded_at,
        'board_stop_sequence',m.board_stop_sequence,
        'alight_stop_sequence',m.alight_stop_sequence,
        'origin',jsonb_build_object(
          'node_public_id',oo.public_id,
          'name',oo.name,
          'community_name',oc.name,
          'planned_time',coalesce(bs.planned_departure_at,bs.planned_arrival_at)
        ),
        'destination',jsonb_build_object(
          'node_public_id',do_.public_id,
          'name',do_.name,
          'community_name',dc.name,
          'planned_time',coalesce(as_.planned_arrival_at,as_.planned_departure_at)
        ),
        'requirements',jsonb_build_object(
          'package_count',r.package_count,
          'total_weight_kg',r.total_weight_kg,
          'total_volume_m3',r.total_volume_m3,
          'requires_cold_chain',r.requires_cold_chain,
          'requires_fragile_handling',r.requires_fragile_handling,
          'earliest_ready_at',r.earliest_ready_at,
          'latest_delivery_at',r.latest_delivery_at,
          'package_specs',coalesce((
            select jsonb_agg(jsonb_build_object(
              'weight_kg',e.value->'weight_kg',
              'volume_m3',e.value->'volume_m3',
              'requires_cold_chain',e.value->'requires_cold_chain',
              'requires_fragile_handling',e.value->'requires_fragile_handling',
              'length_cm',e.value->'length_cm',
              'width_cm',e.value->'width_cm',
              'height_cm',e.value->'height_cm',
              'package_form',e.value->'package_form'
            ))
            from jsonb_array_elements(r.package_requirements) e(value)
          ),'[]'::jsonb)
        )
      ) as obj
    from public.logistics_matches m
    join public.logistics_trips t on t.id=m.trip_id
    join public.logistics_match_requirement_snapshots r on r.id=m.requirement_snapshot_id
    join public.logistics_routing_hops h on h.id=m.routing_hop_id
    join public.operational_locations oo on oo.id=h.origin_operational_location_id
    join public.communities oc on oc.id=oo.community_id
    join public.operational_locations do_ on do_.id=h.destination_operational_location_id
    join public.communities dc on dc.id=do_.community_id
    left join public.logistics_trip_stops bs
      on bs.trip_id=t.id and bs.stop_sequence=m.board_stop_sequence
    left join public.logistics_trip_stops as_
      on as_.trip_id=t.id and as_.stop_sequence=m.alight_stop_sequence
    where t.driver_profile_id=v_con
      and t.state in ('PUBLISHED','ACCEPTING')
      and (v_trip_filter is null or t.public_id=v_trip_filter)
      and (
        m.state='OFFERED'
        or (p_include_resolved and m.state in ('ACCEPTED','REJECTED','EXPIRED','INVALIDATED'))
      )
    order by m.offered_at,m.public_id
    limit p_limit
  ) x;

  return v_result;
end;
$$;

create or replace function public.tc_con_respond_opportunity(
  p_con_public_id text,
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
  v_con uuid;
  v_match public.logistics_matches%rowtype;
  v_trip_public_id text;
  v_result jsonb;
begin
  v_con:=public.tc_require_my_con_profile(p_con_public_id);

  select m.* into v_match
  from public.logistics_matches m
  join public.logistics_trips t on t.id=m.trip_id
  where m.public_id=upper(btrim(coalesce(p_match_public_id,'')))
    and t.driver_profile_id=v_con;

  if v_match.id is null then
    raise exception using errcode='P0001', message='TC_CON_OPPORTUNITY_NOT_FOUND';
  end if;

  select t.public_id into v_trip_public_id
  from public.logistics_trips t
  where t.id=v_match.trip_id;

  v_result:=public.tc_respond_logistics_match(
    v_match.id,v_con,p_action,p_reason_code
  );

  return (v_result-'match_id')||jsonb_build_object(
    'match_public_id',v_match.public_id,
    'trip_public_id',v_trip_public_id
  );
end;
$$;

revoke all on function public.tc_con_list_my_opportunities(text,text,boolean,integer)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_con_respond_opportunity(text,text,text,text)
  from public,anon,authenticated,service_role;

grant execute on function public.tc_con_list_my_opportunities(text,text,boolean,integer)
  to authenticated;
grant execute on function public.tc_con_respond_opportunity(text,text,text,text)
  to authenticated;

comment on function public.tc_con_list_my_opportunities(text,text,boolean,integer) is
'Authenticated CON opportunity feed. Pre-accept payload exposes only operational nodes/times and PII-free physical requirements; no PKG ID, recipient name, address or phone.';

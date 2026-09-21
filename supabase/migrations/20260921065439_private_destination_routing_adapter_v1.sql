
CREATE OR REPLACE FUNCTION public.tc_resolve_logistics_demand(p_demand_id uuid, p_mode text DEFAULT 'NORMAL'::text, p_max_hops integer DEFAULT 8)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_mode text := upper(btrim(coalesce(p_mode,'NORMAL')));
  v_origin_kind text;
  v_destination_kind text;
  v_original_destination_kind text;
  v_private_final boolean := false;
  v_origin uuid;
  v_destination uuid;
  v_nodes uuid[];
  v_edges uuid[];
  v_hops integer;
  v_attempt uuid;
  v_result text;
  v_all_current boolean := true;
  v_edge uuid;
  v_edge_state text;
  v_edge_origin uuid;
  v_edge_destination uuid;
  v_trip uuid;
  v_board integer;
  v_alight integer;
  v_seq integer;
  v_demand_weight numeric;
  v_demand_volume numeric;
  v_package_count integer;
  v_requires_cold boolean;
  v_requires_fragile boolean;
  v_earliest timestamptz;
  v_latest timestamptz;
  v_trip_ids uuid[] := '{}'::uuid[];
  v_board_seqs integer[] := '{}'::integer[];
  v_alight_seqs integer[] := '{}'::integer[];
  v_edge_states text[] := '{}'::text[];
begin
  if v_mode not in ('NORMAL','RECOVERY','RETURN') then
    raise exception using errcode='P0001', message='TC_ROUTING_MODE_INVALID';
  end if;

  if p_max_hops < 1 or p_max_hops > 12 then
    raise exception using errcode='P0001', message='TC_ROUTING_MAX_HOPS_INVALID';
  end if;

  select
    ov.target_kind,
    dv.target_kind,
    ov.operational_location_id,
    dv.operational_location_id,
    d.total_weight_kg,
    d.total_volume_m3,
    d.requires_cold_chain,
    d.requires_fragile_handling,
    d.earliest_ready_at,
    d.latest_delivery_at
  into
    v_origin_kind,
    v_destination_kind,
    v_origin,
    v_destination,
    v_demand_weight,
    v_demand_volume,
    v_requires_cold,
    v_requires_fragile,
    v_earliest,
    v_latest
  from public.logistics_demands d
  join public.logistics_destination_versions ov
    on ov.id=d.origin_destination_version_id
  join public.logistics_destination_versions dv
    on dv.id=d.destination_version_id
  where d.id=p_demand_id
  for update of d;

  if v_origin_kind is null then
    raise exception using errcode='P0001', message='TC_LOGISTICS_DEMAND_NOT_FOUND';
  end if;

  select count(*) into v_package_count
  from public.logistics_demand_packages dp
  where dp.demand_id=p_demand_id;

  v_original_destination_kind:=v_destination_kind;

  if v_origin_kind='OPERATIONAL_NODE'
     and v_destination_kind='PRIVATE_LOCATION' then
    v_destination:=public.tc_ensure_private_destination_adapter(
      p_demand_id,p_max_hops
    );

    if v_destination is null then
      insert into public.logistics_routing_attempts(
        demand_id,routing_mode,result_code,
        structural_reachable,current_executable,no_trip_now,
        origin_operational_location_id,destination_operational_location_id,
        path_node_ids,hop_count,detail
      ) values(
        p_demand_id,v_mode,'ADAPTER_REQUIRED',
        false,false,false,
        v_origin,null,
        array_remove(array[v_origin],null),0,
        jsonb_build_object(
          'origin_target_kind',v_origin_kind,
          'destination_target_kind','PRIVATE_LOCATION',
          'reason','LAST_MILE_ORIGIN_UNAVAILABLE'
        )
      ) returning id into v_attempt;
      return v_attempt;
    end if;

    v_private_final:=true;
    v_destination_kind:='OPERATIONAL_NODE';
  end if;

  if v_origin_kind <> 'OPERATIONAL_NODE'
     or v_destination_kind <> 'OPERATIONAL_NODE' then
    insert into public.logistics_routing_attempts(
      demand_id,routing_mode,result_code,
      structural_reachable,current_executable,no_trip_now,
      origin_operational_location_id,destination_operational_location_id,
      path_node_ids,hop_count,detail
    ) values(
      p_demand_id,v_mode,'ADAPTER_REQUIRED',
      false,false,false,
      v_origin,v_destination,
      array_remove(array[v_origin,v_destination],null),0,
      jsonb_build_object(
        'origin_target_kind',v_origin_kind,
        'destination_target_kind',v_original_destination_kind,
        'reason','PRIVATE_OR_NON_NETWORK_ENDPOINT_REQUIRES_ADAPTER'
      )
    ) returning id into v_attempt;
    return v_attempt;
  end if;

  if v_origin=v_destination then
    insert into public.logistics_routing_attempts(
      demand_id,routing_mode,result_code,
      structural_reachable,current_executable,no_trip_now,
      origin_operational_location_id,destination_operational_location_id,
      path_node_ids,hop_count
    ) values(
      p_demand_id,v_mode,'ALREADY_AT_DESTINATION',
      true,true,false,
      v_origin,v_destination,array[v_origin],0
    ) returning id into v_attempt;
    return v_attempt;
  end if;

  with recursive paths as (
    select
      v_origin as current_node,
      array[v_origin]::uuid[] as path_nodes,
      array[]::uuid[] as path_edges,
      0 as depth

    union all

    select
      e.destination_operational_location_id,
      p.path_nodes || e.destination_operational_location_id,
      p.path_edges || e.id,
      p.depth + 1
    from paths p
    join public.logistics_edges e
      on e.origin_operational_location_id=p.current_node
     and e.structural_status='ACTIVE'
    join public.operational_locations o
      on o.id=e.destination_operational_location_id
     and o.active
     and o.network_enabled
    where p.depth < p_max_hops
      and not exists (
        select 1
        from public.logistics_demand_packages dp
        join public.packages pkg on pkg.id=dp.package_id
        where dp.demand_id=p_demand_id
          and (
            (e.max_single_package_weight_kg is not null
              and pkg.weight_kg > e.max_single_package_weight_kg)
            or
            (e.max_single_package_volume_m3 is not null
              and pkg.volume_m3 > e.max_single_package_volume_m3)
          )
      )
      and (
        e.destination_operational_location_id=v_destination
        or (
          exists (
            select 1
            from public.operational_location_capabilities olc
            join public.logistics_capability_catalog cap
              on cap.id=olc.capability_id
            where olc.operational_location_id=e.destination_operational_location_id
              and olc.status='ENABLED'
              and cap.active
              and cap.code='RECEIVE_CARGO'
          )
          and exists (
            select 1
            from public.operational_location_capabilities olc
            join public.logistics_capability_catalog cap
              on cap.id=olc.capability_id
            where olc.operational_location_id=e.destination_operational_location_id
              and olc.status='ENABLED'
              and cap.active
              and cap.code='HANDOFF_CARGO'
          )
          and not exists (
            select 1
            from unnest(coalesce(e.required_capability_codes,'{}'::text[])) req(code)
            where not exists (
              select 1
              from public.operational_location_capabilities olc
              join public.logistics_capability_catalog cap
                on cap.id=olc.capability_id
              where olc.operational_location_id=e.destination_operational_location_id
                and olc.status='ENABLED'
                and cap.active
                and cap.code=req.code
            )
          )
        )
      )
      and (
        case
          when v_mode='NORMAL'
            then not (e.destination_operational_location_id=any(p.path_nodes))
          else (
            select count(*)
            from unnest(p.path_nodes) n(id)
            where n.id=e.destination_operational_location_id
          ) < 2
        end
      )
      and public.tc_routing_path_loop_code(
        p.path_nodes || e.destination_operational_location_id,
        v_mode
      ) is null
  )
  select path_nodes,path_edges,depth
    into v_nodes,v_edges,v_hops
  from paths
  where current_node=v_destination
  order by depth,array_to_string(path_edges,',')
  limit 1;

  if v_nodes is null then
    insert into public.logistics_routing_attempts(
      demand_id,routing_mode,result_code,
      structural_reachable,current_executable,no_trip_now,
      origin_operational_location_id,destination_operational_location_id,
      path_node_ids,hop_count,exception_code,detail
    ) values(
      p_demand_id,v_mode,'STRUCTURAL_UNREACHABLE',
      false,false,false,
      v_origin,v_destination,'{}'::uuid[],0,
      'STRUCTURAL_UNREACHABLE',
      jsonb_build_object('max_hops',p_max_hops)
    ) returning id into v_attempt;

    update public.logistics_demands
       set state='ROUTING_EXCEPTION',
           routing_exception_code='STRUCTURAL_UNREACHABLE',
           routing_exception_detail=jsonb_build_object(
             'routing_attempt_id',v_attempt,
             'max_hops',p_max_hops
           ),
           version=version+1,
           updated_at=now()
     where id=p_demand_id
       and state not in ('DELIVERED','CANCELLED');

    return v_attempt;
  end if;

  for v_seq in 1..cardinality(v_edges) loop
    v_edge := v_edges[v_seq];
    v_edge_origin := v_nodes[v_seq];
    v_edge_destination := v_nodes[v_seq+1];

    select x.state into v_edge_state
    from (
      select ese.state
      from public.logistics_edge_state_events ese
      where ese.edge_id=v_edge
        and ese.effective_at <= now()
      order by ese.effective_at desc,ese.created_at desc,ese.id desc
      limit 1
    ) x;

    v_trip := null;
    v_board := null;
    v_alight := null;

    if v_edge_state='OPEN' then
      select t.id,s1.stop_sequence,s2.stop_sequence
        into v_trip,v_board,v_alight
      from public.logistics_trips t
      join public.logistics_trip_stops s1
        on s1.trip_id=t.id
       and s1.operational_location_id=v_edge_origin
      join public.logistics_trip_stops s2
        on s2.trip_id=t.id
       and s2.operational_location_id=v_edge_destination
       and s2.stop_sequence>s1.stop_sequence
      join public.logistics_trip_capacity c
        on c.trip_id=t.id
      where t.state in ('PUBLISHED','ACCEPTING')
        and (not v_requires_cold or c.accepts_cold_chain)
        and (not v_requires_fragile or c.accepts_fragile)
        and (v_earliest is null or t.planned_departure_at >= v_earliest)
        and (
          v_latest is null
          or (
            t.planned_arrival_at is not null
            and t.planned_arrival_at <= v_latest
          )
        )
        and not exists (
          select 1
          from generate_series(s1.stop_sequence,s2.stop_sequence-1) seg(n)
          where
            (
              select coalesce(sum(r.reserved_weight_kg),0)
              from public.logistics_capacity_reservations r
              where r.trip_id=t.id
                and r.state in ('HELD','CONFIRMED')
                and r.board_stop_sequence <= seg.n
                and r.alight_stop_sequence > seg.n
            ) + v_demand_weight > c.declared_free_weight_kg
            or
            (
              select coalesce(sum(r.reserved_volume_m3),0)
              from public.logistics_capacity_reservations r
              where r.trip_id=t.id
                and r.state in ('HELD','CONFIRMED')
                and r.board_stop_sequence <= seg.n
                and r.alight_stop_sequence > seg.n
            ) + v_demand_volume > c.declared_free_volume_m3
            or
            (
              select coalesce(sum(r.reserved_packages),0)
              from public.logistics_capacity_reservations r
              where r.trip_id=t.id
                and r.state in ('HELD','CONFIRMED')
                and r.board_stop_sequence <= seg.n
                and r.alight_stop_sequence > seg.n
            ) + v_package_count > c.declared_free_packages
        )
      order by t.planned_departure_at,t.public_id,s1.stop_sequence,s2.stop_sequence
      limit 1;
    end if;

    v_trip_ids := array_append(v_trip_ids,v_trip);
    v_board_seqs := array_append(v_board_seqs,v_board);
    v_alight_seqs := array_append(v_alight_seqs,v_alight);
    v_edge_states := array_append(v_edge_states,coalesce(v_edge_state,'UNDECLARED'));

    if v_trip is null then
      v_all_current := false;
    end if;
  end loop;

  v_result := case when v_all_current then 'CURRENT_EXECUTABLE' else 'NO_TRIP_NOW' end;

  insert into public.logistics_routing_attempts(
    demand_id,routing_mode,result_code,
    structural_reachable,current_executable,no_trip_now,
    origin_operational_location_id,destination_operational_location_id,
    path_node_ids,hop_count,detail
  ) values(
    p_demand_id,v_mode,v_result,
    true,v_all_current,not v_all_current,
    v_origin,v_destination,v_nodes,v_hops,
    jsonb_build_object(
      'max_hops',p_max_hops,
      'private_final_destination',v_private_final,
      'network_egress_operational_location_id',
        case when v_private_final then v_destination else null end
    )
  ) returning id into v_attempt;

  for v_seq in 1..cardinality(v_edges) loop
    insert into public.logistics_routing_hops(
      routing_attempt_id,hop_sequence,edge_id,
      origin_operational_location_id,destination_operational_location_id,
      selected_trip_id,board_stop_sequence,alight_stop_sequence,
      availability_state,detail
    ) values(
      v_attempt,v_seq,v_edges[v_seq],
      v_nodes[v_seq],v_nodes[v_seq+1],
      v_trip_ids[v_seq],v_board_seqs[v_seq],v_alight_seqs[v_seq],
      case when v_trip_ids[v_seq] is null then 'NO_TRIP_NOW' else 'CURRENT_EXECUTABLE' end,
      jsonb_build_object('edge_runtime_state',v_edge_states[v_seq])
    );
  end loop;

  if v_all_current then
    update public.logistics_demands
       set routing_exception_code=null,
           routing_exception_detail=null,
           updated_at=now()
     where id=p_demand_id;
  end if;

  return v_attempt;
end;
$function$
;

revoke all on function public.tc_resolve_logistics_demand(uuid,text,integer)
  from public,anon,authenticated;
grant execute on function public.tc_resolve_logistics_demand(uuid,text,integer)
  to service_role;

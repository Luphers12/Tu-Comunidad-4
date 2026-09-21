
create table public.logistics_routing_attempts (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('RTA'),
  demand_id uuid not null references public.logistics_demands(id) on delete restrict,
  routing_mode text not null default 'NORMAL'
    check (routing_mode in ('NORMAL','RECOVERY','RETURN')),
  result_code text not null
    check (result_code in (
      'CURRENT_EXECUTABLE',
      'NO_TRIP_NOW',
      'STRUCTURAL_UNREACHABLE',
      'ADAPTER_REQUIRED',
      'LOOP_DETECTED',
      'ALREADY_AT_DESTINATION'
    )),
  structural_reachable boolean not null,
  current_executable boolean not null,
  no_trip_now boolean not null,
  origin_operational_location_id uuid references public.operational_locations(id) on delete restrict,
  destination_operational_location_id uuid references public.operational_locations(id) on delete restrict,
  path_node_ids uuid[] not null default '{}'::uuid[],
  hop_count integer not null default 0 check (hop_count >= 0),
  exception_code text,
  detail jsonb not null default '{}'::jsonb,
  attempted_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  check (public_id like 'RTA-%'),
  check (not no_trip_now or structural_reachable),
  check (not current_executable or structural_reachable),
  check (
    result_code not in ('STRUCTURAL_UNREACHABLE','LOOP_DETECTED')
    or exception_code is not null
  )
);

create table public.logistics_routing_hops (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('RHP'),
  routing_attempt_id uuid not null references public.logistics_routing_attempts(id) on delete restrict,
  hop_sequence integer not null check (hop_sequence > 0),
  edge_id uuid not null references public.logistics_edges(id) on delete restrict,
  origin_operational_location_id uuid not null references public.operational_locations(id) on delete restrict,
  destination_operational_location_id uuid not null references public.operational_locations(id) on delete restrict,
  selected_trip_id uuid references public.logistics_trips(id) on delete restrict,
  board_stop_sequence integer,
  alight_stop_sequence integer,
  availability_state text not null
    check (availability_state in ('CURRENT_EXECUTABLE','NO_TRIP_NOW')),
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (routing_attempt_id, hop_sequence),
  check (public_id like 'RHP-%'),
  check (
    (availability_state='CURRENT_EXECUTABLE'
      and selected_trip_id is not null
      and board_stop_sequence is not null
      and alight_stop_sequence is not null
      and board_stop_sequence < alight_stop_sequence)
    or
    (availability_state='NO_TRIP_NOW'
      and selected_trip_id is null
      and board_stop_sequence is null
      and alight_stop_sequence is null)
  )
);

create index logistics_routing_attempts_demand_idx
  on public.logistics_routing_attempts(demand_id, attempted_at desc);

create index logistics_routing_hops_attempt_idx
  on public.logistics_routing_hops(routing_attempt_id, hop_sequence);

create or replace function public.tc_routing_path_loop_code(
  p_path uuid[],
  p_mode text
)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_mode text := upper(btrim(coalesce(p_mode,'NORMAL')));
  i integer;
  j integer;
  v_count integer;
begin
  if p_path is null or cardinality(p_path) < 2 then
    return null;
  end if;

  if cardinality(p_path) >= 4 then
    for i in 1..cardinality(p_path)-3 loop
      if p_path[i]=p_path[i+2]
         and p_path[i+1]=p_path[i+3]
         and p_path[i]<>p_path[i+1] then
        return 'LOOP_DETECTED_OSCILLATION';
      end if;
    end loop;
  end if;

  for i in 1..cardinality(p_path) loop
    v_count := 0;
    for j in 1..cardinality(p_path) loop
      if p_path[j]=p_path[i] then
        v_count := v_count + 1;
      end if;
    end loop;

    if v_mode='NORMAL' and v_count > 1 then
      return 'LOOP_DETECTED_REVISIT';
    end if;

    if v_mode in ('RECOVERY','RETURN') and v_count > 2 then
      return 'LOOP_DETECTED_REPEATED_REVISIT';
    end if;
  end loop;

  return null;
end;
$$;

create or replace function public.tc_resolve_logistics_demand(
  p_demand_id uuid,
  p_mode text default 'NORMAL',
  p_max_hops integer default 8
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_mode text := upper(btrim(coalesce(p_mode,'NORMAL')));
  v_origin_kind text;
  v_destination_kind text;
  v_origin uuid;
  v_destination uuid;
  v_nodes uuid[];
  v_edges uuid[];
  v_hops integer;
  v_loop_code text;
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
        'destination_target_kind',v_destination_kind,
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
            from unnest(
              coalesce(e.required_capability_codes,'{}'::text[])
            ) req(code)
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
  order by depth, array_to_string(path_edges,',')
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

  v_loop_code := public.tc_routing_path_loop_code(v_nodes,v_mode);
  if v_loop_code is not null then
    insert into public.logistics_routing_attempts(
      demand_id,routing_mode,result_code,
      structural_reachable,current_executable,no_trip_now,
      origin_operational_location_id,destination_operational_location_id,
      path_node_ids,hop_count,exception_code
    ) values(
      p_demand_id,v_mode,'LOOP_DETECTED',
      true,false,false,
      v_origin,v_destination,v_nodes,v_hops,v_loop_code
    ) returning id into v_attempt;

    update public.logistics_demands
       set state='ROUTING_EXCEPTION',
           routing_exception_code='LOOP_DETECTED',
           routing_exception_detail=jsonb_build_object(
             'routing_attempt_id',v_attempt,
             'loop_code',v_loop_code,
             'path_node_ids',to_jsonb(v_nodes)
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
        and (v_latest is null or t.planned_arrival_at is null or t.planned_arrival_at <= v_latest)
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
    jsonb_build_object('max_hops',p_max_hops)
  ) returning id into v_attempt;

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
        and (v_latest is null or t.planned_arrival_at is null or t.planned_arrival_at <= v_latest)
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

    insert into public.logistics_routing_hops(
      routing_attempt_id,hop_sequence,edge_id,
      origin_operational_location_id,destination_operational_location_id,
      selected_trip_id,board_stop_sequence,alight_stop_sequence,
      availability_state,detail
    ) values(
      v_attempt,v_seq,v_edge,
      v_edge_origin,v_edge_destination,
      v_trip,v_board,v_alight,
      case when v_trip is null then 'NO_TRIP_NOW' else 'CURRENT_EXECUTABLE' end,
      jsonb_build_object('edge_runtime_state',coalesce(v_edge_state,'UNDECLARED'))
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
$$;

create trigger logistics_routing_attempts_append_only
before update or delete on public.logistics_routing_attempts
for each row execute function public.tc_guard_logistics_append_only();

create trigger logistics_routing_hops_append_only
before update or delete on public.logistics_routing_hops
for each row execute function public.tc_guard_logistics_append_only();

alter table public.logistics_routing_attempts enable row level security;
alter table public.logistics_routing_hops enable row level security;

revoke all on public.logistics_routing_attempts from public,anon,authenticated;
revoke all on public.logistics_routing_hops from public,anon,authenticated;
grant select,insert on public.logistics_routing_attempts to service_role;
grant select,insert on public.logistics_routing_hops to service_role;

revoke all on function public.tc_routing_path_loop_code(uuid[],text) from public,anon,authenticated;
revoke all on function public.tc_resolve_logistics_demand(uuid,text,integer) from public,anon,authenticated;
grant execute on function public.tc_routing_path_loop_code(uuid[],text) to service_role;
grant execute on function public.tc_resolve_logistics_demand(uuid,text,integer) to service_role;

comment on table public.logistics_routing_attempts is
'Append-only routing decision evidence. STRUCTURAL_UNREACHABLE/LOOP_DETECTED are hard routing exceptions; NO_TRIP_NOW is not a dead end.';
comment on table public.logistics_routing_hops is
'Resolved structural hops with an optional currently executable TRIP snapshot. A missing selected_trip_id means NO_TRIP_NOW, not structural failure.';

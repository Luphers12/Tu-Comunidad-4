
create or replace function public.tc_require_my_operational_node(
  p_node_public_id text,
  p_required_capability_code text default null
)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_active uuid;
  v_type text;
  v_node uuid;
  v_cap text:=nullif(upper(btrim(coalesce(p_required_capability_code,''))),'');
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
    raise exception using errcode='P0001', message='TC_NODE_ROLE_FORBIDDEN';
  end if;

  select o.id into v_node
  from public.operational_locations o
  where o.public_id=upper(btrim(coalesce(p_node_public_id,'')))
    and o.active
    and o.network_enabled
    and o.owner_profile_id=v_active;

  if v_node is null then
    raise exception using errcode='P0001', message='TC_NODE_FORBIDDEN';
  end if;

  if v_cap is not null then
    if not exists(
      select 1
      from public.operational_location_capabilities olc
      join public.logistics_capability_catalog c
        on c.id=olc.capability_id
      where olc.operational_location_id=v_node
        and olc.status='ENABLED'
        and c.active
        and c.code=v_cap
    ) then
      raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_REQUIRED';
    end if;
  end if;

  return v_node;
end;
$$;

revoke all on function public.tc_require_my_operational_node(text,text)
  from public,anon,authenticated,service_role;

create or replace function public.tc_node_my_context()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_active uuid;
  v_type text;
  v_public text;
  v_nodes jsonb;
begin
  v_active:=public.tc_active_profile_id();

  if v_active is null then
    raise exception using errcode='P0001', message='TC_ACTIVE_PROFILE_NOT_SELECTED';
  end if;

  select p.profile_type,p.public_id
    into v_type,v_public
  from public.profiles p
  where p.id=v_active
    and p.status='active';

  if v_type not in ('TIE','PTC') then
    raise exception using errcode='P0001', message='TC_NODE_ROLE_FORBIDDEN';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'node_public_id',o.public_id,
    'name',o.name,
    'purpose',o.purpose,
    'community_public_id',c.public_id,
    'community_name',c.name,
    'capabilities',coalesce((
      select jsonb_agg(cap.code order by cap.code)
      from public.operational_location_capabilities olc
      join public.logistics_capability_catalog cap on cap.id=olc.capability_id
      where olc.operational_location_id=o.id
        and olc.status='ENABLED'
        and cap.active
    ),'[]'::jsonb),
    'work',jsonb_build_object(
      'inbound_open',(
        select count(*)
        from public.movements mv
        where mv.destination_operational_location_id=o.id
          and mv.logistics_trip_id is not null
          and mv.state not in ('COMPLETED','CANCELLED')
      ),
      'outbound_open',(
        select count(*)
        from public.movements mv
        where mv.origin_operational_location_id=o.id
          and mv.logistics_trip_id is not null
          and mv.state not in ('COMPLETED','CANCELLED')
      ),
      'last_mile_open',(
        select count(*)
        from public.logistics_last_mile_tasks t
        where t.origin_operational_location_id=o.id
          and t.state not in ('DELIVERED','CANCELLED')
      )
    )
  ) order by o.name,o.public_id),'[]'::jsonb)
  into v_nodes
  from public.operational_locations o
  join public.communities c on c.id=o.community_id
  where o.owner_profile_id=v_active
    and o.active
    and o.network_enabled;

  return jsonb_build_object(
    'active_profile_public_id',v_public,
    'active_profile_type',v_type,
    'nodes',v_nodes
  );
end;
$$;

create or replace function public.tc_node_my_inbound(
  p_node_public_id text,
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_node uuid;
  v_limit integer;
  v_result jsonb;
begin
  v_node:=public.tc_require_my_operational_node(
    p_node_public_id,'RECEIVE_CARGO'
  );
  v_limit:=least(greatest(coalesce(p_limit,100),1),250);

  select coalesce(jsonb_agg(x.obj order by x.expected_to_at,x.movement_public_id),'[]'::jsonb)
  into v_result
  from (
    select
      mv.expected_to_at,
      mv.public_id as movement_public_id,
      jsonb_build_object(
        'movement_public_id',mv.public_id,
        'movement_state',mv.state,
        'expected_to_at',mv.expected_to_at,
        'arrived_at',mv.arrived_at,
        'trip_public_id',t.public_id,
        'con_public_id',con.public_id,
        'origin_node',jsonb_build_object(
          'node_public_id',orig.public_id,
          'name',orig.name
        ),
        'destination_node',jsonb_build_object(
          'node_public_id',dest.public_id,
          'name',dest.name
        ),
        'manifest_public_id',(
          select m.public_id
          from public.logistics_manifests m
          where m.trip_id=mv.logistics_trip_id
            and exists(
              select 1
              from public.logistics_manifest_segments s
              where s.manifest_id=m.id
                and s.movement_id=mv.id
            )
          order by m.version_no desc,m.id desc
          limit 1
        ),
        'reconciliation',(
          select jsonb_build_object(
            'run_public_id',r.public_id,
            'status',r.status,
            'expected_count',r.expected_count,
            'observed_expected_count',r.observed_expected_count,
            'missing_count',r.missing_count,
            'unexpected_count',r.unexpected_count
          )
          from public.logistics_movement_reconciliation_runs r
          where r.movement_id=mv.id
          order by r.run_no desc,r.id desc
          limit 1
        ),
        'packages',coalesce((
          select jsonb_agg(jsonb_build_object(
            'package_public_id',p.public_id,
            'state',p.state,
            'weight_kg',p.weight_kg,
            'volume_m3',p.volume_m3,
            'requires_cold_chain',p.requires_cold_chain,
            'requires_fragile_handling',p.requires_fragile_handling,
            'arrival_scan',exists(
              select 1
              from public.logistics_scan_events s
              where s.movement_id=mv.id
                and s.package_id=p.id
                and s.scan_type='ARRIVAL'
            ),
            'arrival_phase_status',(
              select h.status
              from public.logistics_movement_custody_phases h
              where h.movement_id=mv.id
                and h.package_id=p.id
                and h.phase='ARRIVAL'
              limit 1
            )
          ) order by p.public_id)
          from public.movement_packages mp
          join public.packages p on p.id=mp.package_id
          where mp.movement_id=mv.id
        ),'[]'::jsonb)
      ) as obj
    from public.movements mv
    join public.logistics_trips t on t.id=mv.logistics_trip_id
    join public.profiles con on con.id=t.driver_profile_id
    join public.operational_locations orig on orig.id=mv.origin_operational_location_id
    join public.operational_locations dest on dest.id=mv.destination_operational_location_id
    where mv.destination_operational_location_id=v_node
      and mv.logistics_trip_id is not null
      and mv.state not in ('COMPLETED','CANCELLED')
    order by mv.expected_to_at nulls last,mv.created_at,mv.id
    limit v_limit
  ) x;

  return v_result;
end;
$$;

create or replace function public.tc_node_my_outbound(
  p_node_public_id text,
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_node uuid;
  v_limit integer;
  v_result jsonb;
begin
  v_node:=public.tc_require_my_operational_node(
    p_node_public_id,'HANDOFF_CARGO'
  );
  v_limit:=least(greatest(coalesce(p_limit,100),1),250);

  select coalesce(jsonb_agg(x.obj order by x.expected_from_at,x.movement_public_id),'[]'::jsonb)
  into v_result
  from (
    select
      mv.expected_from_at,
      mv.public_id as movement_public_id,
      jsonb_build_object(
        'movement_public_id',mv.public_id,
        'movement_state',mv.state,
        'expected_from_at',mv.expected_from_at,
        'departed_at',mv.departed_at,
        'trip_public_id',t.public_id,
        'con_public_id',con.public_id,
        'origin_node',jsonb_build_object(
          'node_public_id',orig.public_id,
          'name',orig.name
        ),
        'destination_node',jsonb_build_object(
          'node_public_id',dest.public_id,
          'name',dest.name
        ),
        'manifest_public_id',(
          select m.public_id
          from public.logistics_manifests m
          where m.trip_id=mv.logistics_trip_id
            and exists(
              select 1
              from public.logistics_manifest_segments s
              where s.manifest_id=m.id
                and s.movement_id=mv.id
            )
          order by m.version_no desc,m.id desc
          limit 1
        ),
        'packages',coalesce((
          select jsonb_agg(jsonb_build_object(
            'package_public_id',p.public_id,
            'state',p.state,
            'weight_kg',p.weight_kg,
            'volume_m3',p.volume_m3,
            'load_scan',exists(
              select 1
              from public.logistics_scan_events s
              where s.movement_id=mv.id
                and s.package_id=p.id
                and s.scan_type='LOAD'
            ),
            'departure_phase_status',(
              select h.status
              from public.logistics_movement_custody_phases h
              where h.movement_id=mv.id
                and h.package_id=p.id
                and h.phase='DEPARTURE'
              limit 1
            )
          ) order by p.public_id)
          from public.movement_packages mp
          join public.packages p on p.id=mp.package_id
          where mp.movement_id=mv.id
        ),'[]'::jsonb)
      ) as obj
    from public.movements mv
    join public.logistics_trips t on t.id=mv.logistics_trip_id
    join public.profiles con on con.id=t.driver_profile_id
    join public.operational_locations orig on orig.id=mv.origin_operational_location_id
    join public.operational_locations dest on dest.id=mv.destination_operational_location_id
    where mv.origin_operational_location_id=v_node
      and mv.logistics_trip_id is not null
      and mv.state not in ('COMPLETED','CANCELLED')
    order by mv.expected_from_at nulls last,mv.created_at,mv.id
    limit v_limit
  ) x;

  return v_result;
end;
$$;

create or replace function public.tc_node_sort_board(
  p_node_public_id text,
  p_limit integer default 250
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_node uuid;
  v_active uuid;
  v_limit integer;
  v_result jsonb;
begin
  v_node:=public.tc_require_my_operational_node(
    p_node_public_id,'SORT_CARGO'
  );
  v_active:=public.tc_active_profile_id();
  v_limit:=least(greatest(coalesce(p_limit,250),1),500);

  select coalesce(jsonb_agg(x.obj order by x.package_public_id,x.hop_sequence),'[]'::jsonb)
  into v_result
  from (
    select distinct on (p.id,h.id)
      p.public_id as package_public_id,
      h.hop_sequence,
      jsonb_build_object(
        'package_public_id',p.public_id,
        'demand_public_id',d.public_id,
        'routing_attempt_public_id',ra.public_id,
        'routing_hop_public_id',h.public_id,
        'hop_sequence',h.hop_sequence,
        'movement_public_id',mv.public_id,
        'movement_state',mv.state,
        'trip_public_id',t.public_id,
        'expected_next_node',jsonb_build_object(
          'node_public_id',next_node.public_id,
          'name',next_node.name
        ),
        'current_custody_at_node',(p.current_custodian_id=v_active),
        'last_sort',(
          select jsonb_build_object(
            'result',se.result,
            'reason_code',se.reason_code,
            'actual_next_node_public_id',actual.public_id,
            'created_at',se.created_at
          )
          from public.logistics_sort_events se
          join public.logistics_scan_events sc on sc.id=se.scan_event_id
          left join public.operational_locations actual
            on actual.id=se.actual_next_operational_location_id
          where sc.package_id=p.id
            and se.routing_hop_id=h.id
          order by se.created_at desc,se.id desc
          limit 1
        )
      ) as obj
    from public.logistics_hop_executions he
    join public.logistics_execution_plans ep on ep.id=he.execution_plan_id
    join public.logistics_routing_hops h on h.id=he.routing_hop_id
    join public.logistics_routing_attempts ra on ra.id=h.routing_attempt_id
    join public.logistics_demands d on d.id=ep.demand_id
    join public.logistics_demand_packages dp on dp.demand_id=d.id
    join public.packages p on p.id=dp.package_id
    join public.movements mv on mv.id=he.movement_id
    join public.logistics_trips t on t.id=mv.logistics_trip_id
    join public.operational_locations next_node
      on next_node.id=h.destination_operational_location_id
    where h.origin_operational_location_id=v_node
      and p.current_custodian_id=v_active
      and mv.state in ('PLANNED','READY','TRANSFER_PENDING')
      and not exists(
        select 1
        from public.logistics_hop_executions newer
        where newer.supersedes_hop_execution_id=he.id
      )
    order by p.id,h.id,ra.attempt_seq desc,he.created_at desc,he.id desc
    limit v_limit
  ) x;

  return v_result;
end;
$$;

revoke all on function public.tc_node_my_context()
  from public,anon,authenticated,service_role;
revoke all on function public.tc_node_my_inbound(text,integer)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_node_my_outbound(text,integer)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_node_sort_board(text,integer)
  from public,anon,authenticated,service_role;

grant execute on function public.tc_node_my_context()
  to authenticated;
grant execute on function public.tc_node_my_inbound(text,integer)
  to authenticated;
grant execute on function public.tc_node_my_outbound(text,integer)
  to authenticated;
grant execute on function public.tc_node_sort_board(text,integer)
  to authenticated;

comment on function public.tc_node_my_context() is
'Active TIE/PTC operational NODE context with capabilities and workload counts. No private recipient data.';
comment on function public.tc_node_sort_board(text,integer) is
'Active exact NODE-owner sort board derived from effective hop executions. Shows expected next NODE and latest sort result without transferring custody.';

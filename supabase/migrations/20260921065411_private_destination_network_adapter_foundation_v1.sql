
alter table public.logistics_demands
  drop constraint logistics_demands_state_check;

alter table public.logistics_demands
  add constraint logistics_demands_state_check
  check (state = any(array[
    'CREATED'::text,
    'READY_FOR_ROUTING'::text,
    'ROUTING'::text,
    'PARTIALLY_ASSIGNED'::text,
    'ASSIGNED'::text,
    'IN_TRANSIT'::text,
    'AWAITING_LAST_MILE'::text,
    'LAST_MILE_ASSIGNED'::text,
    'DELIVERED'::text,
    'CANCELLED'::text,
    'ROUTING_EXCEPTION'::text
  ]));

alter table public.logistics_promise_evaluations
  drop constraint logistics_promise_evaluations_promise_state_check;

alter table public.logistics_promise_evaluations
  add constraint logistics_promise_evaluations_promise_state_check
  check (promise_state = any(array[
    'UNREACHABLE'::text,
    'ADAPTER_REQUIRED'::text,
    'STRUCTURAL_ONLY'::text,
    'CURRENT_EXECUTABLE'::text,
    'NETWORK_COMMITTED_LAST_MILE_PENDING'::text,
    'END_TO_END_COMMITTED'::text,
    'ROUTING_EXCEPTION'::text,
    'ALREADY_AT_DESTINATION'::text
  ]));

alter table public.logistics_runtime_outbox
  drop constraint logistics_runtime_outbox_event_type_check;

alter table public.logistics_runtime_outbox
  add constraint logistics_runtime_outbox_event_type_check
  check (event_type = any(array[
    'DEMAND_ROUTABLE'::text,
    'TRIP_AVAILABLE'::text,
    'MATCH_ACCEPTED'::text,
    'MOVEMENT_COMPLETED'::text,
    'ARRIVAL_MISMATCH'::text,
    'LAST_MILE_READY'::text
  ]));

create table public.logistics_private_destination_adapters (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('PDA'),
  demand_id uuid not null unique references public.logistics_demands(id) on delete restrict,
  final_destination_version_id uuid not null references public.logistics_destination_versions(id) on delete restrict,
  egress_operational_location_id uuid not null references public.operational_locations(id) on delete restrict,
  state text not null default 'PLANNED'
    check (state in (
      'PLANNED',
      'NETWORK_IN_PROGRESS',
      'AWAITING_LAST_MILE',
      'LAST_MILE_ASSIGNED',
      'COMPLETED',
      'RECOVERY'
    )),
  last_mile_task_id uuid references public.logistics_last_mile_tasks(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (public_id like 'PDA-%')
);

create table public.logistics_last_mile_task_demands (
  task_id uuid not null references public.logistics_last_mile_tasks(id) on delete restrict,
  demand_id uuid not null unique references public.logistics_demands(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (task_id,demand_id)
);

create index logistics_private_destination_adapters_egress_idx
  on public.logistics_private_destination_adapters(
    egress_operational_location_id,state
  );

create trigger logistics_private_destination_adapters_updated_at
before update on public.logistics_private_destination_adapters
for each row execute function public.tc_set_updated_at();

alter table public.logistics_private_destination_adapters enable row level security;
alter table public.logistics_last_mile_task_demands enable row level security;

revoke all on public.logistics_private_destination_adapters from public,anon,authenticated;
revoke all on public.logistics_last_mile_task_demands from public,anon,authenticated;

grant select,insert,update on public.logistics_private_destination_adapters to service_role;
grant select,insert on public.logistics_last_mile_task_demands to service_role;

create or replace function public.tc_ensure_private_destination_adapter(
  p_demand_id uuid,
  p_max_hops integer default 12
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_demand public.logistics_demands%rowtype;
  v_origin_kind text;
  v_final_kind text;
  v_origin uuid;
  v_final_destination uuid;
  v_final_community uuid;
  v_existing public.logistics_private_destination_adapters%rowtype;
  v_egress uuid;
begin
  if p_max_hops<0 or p_max_hops>12 then
    raise exception using errcode='P0001', message='TC_ADAPTER_MAX_HOPS_INVALID';
  end if;

  select * into v_demand
  from public.logistics_demands d
  where d.id=p_demand_id
  for update;

  if v_demand.id is null then
    raise exception using errcode='P0001', message='TC_LOGISTICS_DEMAND_NOT_FOUND';
  end if;

  select
    ov.target_kind,
    dv.target_kind,
    ov.operational_location_id,
    dv.id,
    dv.community_id
  into
    v_origin_kind,
    v_final_kind,
    v_origin,
    v_final_destination,
    v_final_community
  from public.logistics_destination_versions ov
  join public.logistics_destination_versions dv
    on dv.id=v_demand.destination_version_id
  where ov.id=v_demand.origin_destination_version_id;

  if v_origin_kind<>'OPERATIONAL_NODE'
     or v_origin is null
     or v_final_kind<>'PRIVATE_LOCATION'
     or v_final_community is null then
    return null;
  end if;

  select * into v_existing
  from public.logistics_private_destination_adapters a
  where a.demand_id=v_demand.id
  for update;

  if v_existing.id is not null then
    if v_existing.final_destination_version_id is distinct from v_final_destination then
      raise exception using errcode='P0001', message='TC_PRIVATE_DESTINATION_ADAPTER_DESTINATION_CHANGED';
    end if;

    if not exists(
      select 1
      from public.operational_locations o
      where o.id=v_existing.egress_operational_location_id
        and o.active
        and o.network_enabled
        and o.owner_profile_id is not null
    ) then
      raise exception using errcode='P0001', message='TC_PRIVATE_DESTINATION_ADAPTER_STALE';
    end if;

    return v_existing.egress_operational_location_id;
  end if;

  if not exists(
    select 1
    from public.service_coverage sc
    where sc.community_id=v_final_community
      and sc.is_active
      and sc.home_delivery_available
  ) then
    return null;
  end if;

  with recursive paths as (
    select
      v_origin as current_node,
      array[v_origin]::uuid[] as path_nodes,
      0 as depth

    union all

    select
      e.destination_operational_location_id,
      p.path_nodes||e.destination_operational_location_id,
      p.depth+1
    from paths p
    join public.logistics_edges e
      on e.origin_operational_location_id=p.current_node
     and e.structural_status='ACTIVE'
    join public.operational_locations o
      on o.id=e.destination_operational_location_id
     and o.active
     and o.network_enabled
    where p.depth<p_max_hops
      and not (e.destination_operational_location_id=any(p.path_nodes))
      and not exists(
        select 1
        from public.logistics_demand_packages dp
        join public.packages pkg on pkg.id=dp.package_id
        where dp.demand_id=v_demand.id
          and (
            (e.max_single_package_weight_kg is not null
             and pkg.weight_kg>e.max_single_package_weight_kg)
            or
            (e.max_single_package_volume_m3 is not null
             and pkg.volume_m3>e.max_single_package_volume_m3)
          )
      )
      and (
        exists(
          select 1
          from public.operational_location_capabilities olc
          join public.logistics_capability_catalog cap
            on cap.id=olc.capability_id
          where olc.operational_location_id=e.destination_operational_location_id
            and olc.status='ENABLED'
            and cap.active
            and cap.code='RECEIVE_CARGO'
        )
        and exists(
          select 1
          from public.operational_location_capabilities olc
          join public.logistics_capability_catalog cap
            on cap.id=olc.capability_id
          where olc.operational_location_id=e.destination_operational_location_id
            and olc.status='ENABLED'
            and cap.active
            and cap.code='HANDOFF_CARGO'
        )
      )
  )
  select p.current_node into v_egress
  from paths p
  join public.operational_locations o
    on o.id=p.current_node
   and o.community_id=v_final_community
   and o.active
   and o.network_enabled
   and o.owner_profile_id is not null
  where exists(
    select 1
    from public.operational_location_capabilities olc
    join public.logistics_capability_catalog cap
      on cap.id=olc.capability_id
    where olc.operational_location_id=o.id
      and olc.status='ENABLED'
      and cap.active
      and cap.code='LAST_MILE_ORIGIN'
  )
    and exists(
      select 1
      from public.operational_location_capabilities olc
      join public.logistics_capability_catalog cap
        on cap.id=olc.capability_id
      where olc.operational_location_id=o.id
        and olc.status='ENABLED'
        and cap.active
        and cap.code='RECEIVE_CARGO'
    )
    and exists(
      select 1
      from public.operational_location_capabilities olc
      join public.logistics_capability_catalog cap
        on cap.id=olc.capability_id
      where olc.operational_location_id=o.id
        and olc.status='ENABLED'
        and cap.active
        and cap.code='HANDOFF_CARGO'
    )
  order by p.depth,o.public_id
  limit 1;

  if v_egress is null then
    return null;
  end if;

  insert into public.logistics_private_destination_adapters(
    demand_id,
    final_destination_version_id,
    egress_operational_location_id,
    state
  ) values(
    v_demand.id,
    v_final_destination,
    v_egress,
    'PLANNED'
  );

  return v_egress;
end;
$$;

revoke all on function public.tc_ensure_private_destination_adapter(uuid,integer)
  from public,anon,authenticated;
grant execute on function public.tc_ensure_private_destination_adapter(uuid,integer)
  to service_role;

comment on table public.logistics_private_destination_adapters is
'Maps one private-final-destination LGD to the structurally reachable LAST_MILE_ORIGIN NODE used as network egress. Final destination remains unchanged on the LGD.';

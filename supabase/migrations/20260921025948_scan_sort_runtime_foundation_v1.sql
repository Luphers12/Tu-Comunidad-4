
create table public.logistics_scan_events (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('SCN'),
  package_id uuid not null references public.packages(id) on delete restrict,
  operational_location_id uuid not null references public.operational_locations(id) on delete restrict,
  scan_type text not null
    check (scan_type in ('ARRIVAL','SORT','LOAD','UNLOAD','EXCEPTION')),
  routing_attempt_id uuid references public.logistics_routing_attempts(id) on delete restrict,
  routing_hop_id uuid references public.logistics_routing_hops(id) on delete restrict,
  trip_id uuid references public.logistics_trips(id) on delete restrict,
  movement_id uuid references public.movements(id) on delete restrict,
  manifest_id uuid references public.logistics_manifests(id) on delete restrict,
  actor_profile_id uuid references public.profiles(id) on delete set null,
  device_ref text,
  metadata jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  check (public_id like 'SCN-%')
);

create table public.logistics_sort_events (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('SRT'),
  scan_event_id uuid not null unique references public.logistics_scan_events(id) on delete restrict,
  routing_attempt_id uuid not null references public.logistics_routing_attempts(id) on delete restrict,
  routing_hop_id uuid not null references public.logistics_routing_hops(id) on delete restrict,
  expected_next_operational_location_id uuid not null references public.operational_locations(id) on delete restrict,
  actual_next_operational_location_id uuid references public.operational_locations(id) on delete restrict,
  result text not null
    check (result in ('CORRECT_ROUTE','WRONG_DESTINATION','HOP_MISMATCH','PACKAGE_NOT_IN_DEMAND')),
  reason_code text,
  created_at timestamptz not null default now(),
  check (public_id like 'SRT-%'),
  check (
    (result='CORRECT_ROUTE'
      and actual_next_operational_location_id=expected_next_operational_location_id)
    or
    (result<>'CORRECT_ROUTE')
  )
);

create index logistics_scan_events_package_idx
  on public.logistics_scan_events(package_id,occurred_at desc);

create index logistics_scan_events_location_idx
  on public.logistics_scan_events(operational_location_id,occurred_at desc);

create index logistics_sort_events_attempt_idx
  on public.logistics_sort_events(routing_attempt_id,routing_hop_id);

create or replace function public.tc_record_logistics_sort_scan(
  p_package_id uuid,
  p_routing_attempt_id uuid,
  p_hop_sequence integer,
  p_current_operational_location_id uuid,
  p_actual_next_operational_location_id uuid,
  p_actor_profile_id uuid default null,
  p_device_ref text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_hop public.logistics_routing_hops%rowtype;
  v_demand uuid;
  v_scan uuid;
  v_sort uuid;
  v_result text;
  v_reason text;
begin
  select h.* into v_hop
  from public.logistics_routing_hops h
  where h.routing_attempt_id=p_routing_attempt_id
    and h.hop_sequence=p_hop_sequence;

  if v_hop.id is null then
    raise exception using errcode='P0001', message='TC_SORT_HOP_NOT_FOUND';
  end if;

  select a.demand_id into v_demand
  from public.logistics_routing_attempts a
  where a.id=p_routing_attempt_id;

  if not exists (
    select 1
    from public.logistics_demand_packages dp
    where dp.demand_id=v_demand
      and dp.package_id=p_package_id
  ) then
    v_result := 'PACKAGE_NOT_IN_DEMAND';
    v_reason := 'PACKAGE_NOT_IN_DEMAND';
  elsif v_hop.origin_operational_location_id is distinct from p_current_operational_location_id then
    v_result := 'HOP_MISMATCH';
    v_reason := 'CURRENT_NODE_DOES_NOT_MATCH_HOP_ORIGIN';
  elsif v_hop.destination_operational_location_id is distinct from p_actual_next_operational_location_id then
    v_result := 'WRONG_DESTINATION';
    v_reason := 'TORO_EN_CORRAL_DESTINATION_MISMATCH';
  else
    v_result := 'CORRECT_ROUTE';
    v_reason := null;
  end if;

  insert into public.logistics_scan_events(
    package_id,operational_location_id,scan_type,
    routing_attempt_id,routing_hop_id,trip_id,
    actor_profile_id,device_ref,metadata
  ) values(
    p_package_id,p_current_operational_location_id,'SORT',
    p_routing_attempt_id,v_hop.id,v_hop.selected_trip_id,
    p_actor_profile_id,nullif(btrim(coalesce(p_device_ref,'')),''),
    coalesce(p_metadata,'{}'::jsonb)
  ) returning id into v_scan;

  insert into public.logistics_sort_events(
    scan_event_id,routing_attempt_id,routing_hop_id,
    expected_next_operational_location_id,
    actual_next_operational_location_id,
    result,reason_code
  ) values(
    v_scan,p_routing_attempt_id,v_hop.id,
    v_hop.destination_operational_location_id,
    p_actual_next_operational_location_id,
    v_result,v_reason
  ) returning id into v_sort;

  return jsonb_build_object(
    'scan_event_id',v_scan,
    'sort_event_id',v_sort,
    'result',v_result,
    'reason_code',v_reason,
    'expected_next_operational_location_id',v_hop.destination_operational_location_id,
    'actual_next_operational_location_id',p_actual_next_operational_location_id
  );
end;
$$;

create trigger logistics_scan_events_append_only
before update or delete on public.logistics_scan_events
for each row execute function public.tc_guard_logistics_append_only();

create trigger logistics_sort_events_append_only
before update or delete on public.logistics_sort_events
for each row execute function public.tc_guard_logistics_append_only();

alter table public.logistics_scan_events enable row level security;
alter table public.logistics_sort_events enable row level security;

revoke all on public.logistics_scan_events from public,anon,authenticated;
revoke all on public.logistics_sort_events from public,anon,authenticated;
grant select,insert on public.logistics_scan_events to service_role;
grant select,insert on public.logistics_sort_events to service_role;

revoke all on function public.tc_record_logistics_sort_scan(uuid,uuid,integer,uuid,uuid,uuid,text,jsonb)
  from public,anon,authenticated;
grant execute on function public.tc_record_logistics_sort_scan(uuid,uuid,integer,uuid,uuid,uuid,text,jsonb)
  to service_role;

comment on table public.logistics_scan_events is
'Append-only operational scan evidence. No recipient/private destination data is stored here.';
comment on table public.logistics_sort_events is
'Append-only sort decision evidence. CORRECT_ROUTE is permitted only when actual next node equals the resolved hop destination (toro en corral). These events do not transfer custody.';

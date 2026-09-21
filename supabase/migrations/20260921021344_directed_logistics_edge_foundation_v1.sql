
create table public.logistics_edges (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('EDG'),
  origin_operational_location_id uuid not null references public.operational_locations(id) on delete restrict,
  destination_operational_location_id uuid not null references public.operational_locations(id) on delete restrict,
  edge_class text not null default 'GENERAL',
  transport_mode text not null default 'UNSPECIFIED',
  structural_status text not null default 'ACTIVE'
    check (structural_status in ('ACTIVE','RETIRED')),
  required_capability_codes text[] not null default '{}'::text[],
  max_single_package_weight_kg numeric,
  max_single_package_volume_m3 numeric,
  requirements jsonb not null default '{}'::jsonb,
  created_by_person_id uuid references public.persons(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (origin_operational_location_id, destination_operational_location_id, edge_class, transport_mode),
  check (public_id like 'EDG-%'),
  check (origin_operational_location_id <> destination_operational_location_id),
  check (btrim(edge_class) <> ''),
  check (btrim(transport_mode) <> ''),
  check (max_single_package_weight_kg is null or max_single_package_weight_kg > 0),
  check (max_single_package_volume_m3 is null or max_single_package_volume_m3 > 0)
);

create table public.logistics_edge_state_events (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('ESE'),
  edge_id uuid not null references public.logistics_edges(id) on delete restrict,
  state text not null check (state in ('OPEN','CLOSED','RESTRICTED')),
  reason_code text,
  note text,
  restriction jsonb not null default '{}'::jsonb,
  effective_at timestamptz not null default now(),
  created_by_person_id uuid references public.persons(id) on delete set null,
  created_at timestamptz not null default now(),
  check (public_id like 'ESE-%')
);

create index logistics_edges_origin_idx
  on public.logistics_edges(origin_operational_location_id)
  where structural_status='ACTIVE';

create index logistics_edges_destination_idx
  on public.logistics_edges(destination_operational_location_id)
  where structural_status='ACTIVE';

create index logistics_edge_state_events_latest_idx
  on public.logistics_edge_state_events(edge_id, effective_at desc, created_at desc);

create trigger logistics_edges_set_updated_at
before update on public.logistics_edges
for each row execute function public.tc_set_updated_at();

create trigger logistics_edge_state_events_append_only
before update or delete on public.logistics_edge_state_events
for each row execute function public.tc_guard_logistics_append_only();

alter table public.logistics_edges enable row level security;
alter table public.logistics_edge_state_events enable row level security;

revoke all on public.logistics_edges from public, anon, authenticated;
revoke all on public.logistics_edge_state_events from public, anon, authenticated;
grant select,insert,update on public.logistics_edges to service_role;
grant select,insert on public.logistics_edge_state_events to service_role;

comment on table public.logistics_edges is
'Directed structural network edge A→B. It is not a TRIP, driver assignment, MOV, or runtime-capacity declaration.';
comment on table public.logistics_edge_state_events is
'Append-only runtime state events for a structural edge. Absence of an OPEN event must not be interpreted as executable availability.';

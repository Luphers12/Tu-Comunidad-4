
create table public.logistics_execution_plans (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('EXP'),
  routing_attempt_id uuid not null unique references public.logistics_routing_attempts(id) on delete restrict,
  demand_id uuid not null references public.logistics_demands(id) on delete restrict,
  state text not null default 'ACTIVE'
    check (state in ('ACTIVE','COMPLETED','CANCELLED')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (public_id like 'EXP-%')
);

create table public.logistics_hop_executions (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('HEX'),
  execution_plan_id uuid not null references public.logistics_execution_plans(id) on delete restrict,
  routing_hop_id uuid not null unique references public.logistics_routing_hops(id) on delete restrict,
  match_id uuid not null unique references public.logistics_matches(id) on delete restrict,
  capacity_reservation_id uuid not null references public.logistics_capacity_reservations(id) on delete restrict,
  movement_id uuid not null references public.movements(id) on delete restrict,
  created_at timestamptz not null default now(),
  check (public_id like 'HEX-%')
);

create table public.logistics_execution_manifests (
  execution_plan_id uuid not null references public.logistics_execution_plans(id) on delete restrict,
  trip_id uuid not null references public.logistics_trips(id) on delete restrict,
  manifest_id uuid not null unique references public.logistics_manifests(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (execution_plan_id,trip_id)
);

create table public.logistics_manifest_segments (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('MNS'),
  manifest_id uuid not null references public.logistics_manifests(id) on delete restrict,
  package_id uuid not null references public.packages(id) on delete restrict,
  demand_id uuid not null references public.logistics_demands(id) on delete restrict,
  routing_hop_id uuid not null references public.logistics_routing_hops(id) on delete restrict,
  match_id uuid not null references public.logistics_matches(id) on delete restrict,
  capacity_reservation_id uuid not null references public.logistics_capacity_reservations(id) on delete restrict,
  board_stop_sequence integer not null,
  alight_stop_sequence integer not null,
  movement_id uuid references public.movements(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (manifest_id,routing_hop_id,package_id),
  check (public_id like 'MNS-%'),
  check (board_stop_sequence < alight_stop_sequence)
);

create index logistics_hop_executions_plan_idx
  on public.logistics_hop_executions(execution_plan_id,routing_hop_id);

create index logistics_hop_executions_movement_idx
  on public.logistics_hop_executions(movement_id);

create index logistics_manifest_segments_manifest_idx
  on public.logistics_manifest_segments(manifest_id,board_stop_sequence,alight_stop_sequence);

create index logistics_manifest_segments_package_idx
  on public.logistics_manifest_segments(package_id,manifest_id);

create trigger logistics_execution_plans_set_updated_at
before update on public.logistics_execution_plans
for each row execute function public.tc_set_updated_at();

create trigger logistics_hop_executions_append_only
before update or delete on public.logistics_hop_executions
for each row execute function public.tc_guard_logistics_append_only();

create trigger logistics_execution_manifests_append_only
before update or delete on public.logistics_execution_manifests
for each row execute function public.tc_guard_logistics_append_only();

create trigger logistics_manifest_segments_append_only
before update or delete on public.logistics_manifest_segments
for each row execute function public.tc_guard_logistics_append_only();

alter table public.logistics_execution_plans enable row level security;
alter table public.logistics_hop_executions enable row level security;
alter table public.logistics_execution_manifests enable row level security;
alter table public.logistics_manifest_segments enable row level security;

revoke all on public.logistics_execution_plans from public,anon,authenticated;
revoke all on public.logistics_hop_executions from public,anon,authenticated;
revoke all on public.logistics_execution_manifests from public,anon,authenticated;
revoke all on public.logistics_manifest_segments from public,anon,authenticated;

grant select,insert,update on public.logistics_execution_plans to service_role;
grant select,insert on public.logistics_hop_executions to service_role;
grant select,insert on public.logistics_execution_manifests to service_role;
grant select,insert on public.logistics_manifest_segments to service_role;

comment on table public.logistics_execution_plans is
'Idempotent materialization record for one committed routing attempt. It turns accepted capacity commitments into planned MOV/manifest artifacts without transferring custody.';
comment on table public.logistics_hop_executions is
'Immutable HOP→MATCH→reservation→MOV materialization evidence. Multiple demands may reference the same MOV when trip/edge/segment are compatible.';
comment on table public.logistics_execution_manifests is
'Execution-plan reference to the immutable full-trip manifest snapshot created during materialization.';
comment on table public.logistics_manifest_segments is
'Canonical multi-segment manifest detail. A PKG may appear on multiple HOP segments while preserving one PKG identity. This does not transfer custody.';

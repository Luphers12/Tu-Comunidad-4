
alter table public.logistics_hop_executions
  drop constraint logistics_hop_executions_routing_hop_id_key;

alter table public.logistics_hop_executions
  add column supersedes_hop_execution_id uuid
    references public.logistics_hop_executions(id) on delete restrict,
  add column replacement_reason text;

create unique index logistics_hop_executions_one_replacement_uidx
  on public.logistics_hop_executions(supersedes_hop_execution_id)
  where supersedes_hop_execution_id is not null;

create index logistics_hop_executions_routing_hop_history_idx
  on public.logistics_hop_executions(routing_hop_id,created_at,id);

alter table public.logistics_hop_executions
  add constraint logistics_hop_executions_not_self_supersede
  check (supersedes_hop_execution_id is null or supersedes_hop_execution_id<>id);

create table public.logistics_continuation_events (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('CTE'),
  execution_plan_id uuid not null references public.logistics_execution_plans(id) on delete restrict,
  completed_movement_id uuid not null references public.movements(id) on delete restrict,
  next_hop_execution_id uuid references public.logistics_hop_executions(id) on delete restrict,
  next_movement_id uuid references public.movements(id) on delete restrict,
  action text not null check (action in (
    'CONTINUE_READY',
    'WAITING_FOR_PACKAGES',
    'RECANDIDATE_REQUIRED',
    'RECOVERY_REQUIRED',
    'PLAN_COMPLETE',
    'ALREADY_IN_PROGRESS'
  )),
  reason_code text,
  idempotency_key text not null unique,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  check (public_id like 'CTE-%')
);

create table public.logistics_recovery_cases (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('RCV'),
  case_key text not null unique,
  case_type text not null check (case_type in (
    'MATERIALIZED_CANDIDATE_FAILED',
    'ARRIVAL_MISMATCH',
    'CHAIN_DISCONTINUITY',
    'NEXT_HOP_UNAVAILABLE'
  )),
  movement_id uuid references public.movements(id) on delete restrict,
  execution_plan_id uuid references public.logistics_execution_plans(id) on delete restrict,
  routing_hop_id uuid references public.logistics_routing_hops(id) on delete restrict,
  manifest_id uuid references public.logistics_manifests(id) on delete restrict,
  created_at timestamptz not null default now(),
  check (public_id like 'RCV-%')
);

create table public.logistics_recovery_events (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('RVE'),
  recovery_case_id uuid not null references public.logistics_recovery_cases(id) on delete restrict,
  event_type text not null check (event_type in (
    'OPENED',
    'CANDIDATE_RELEASED',
    'REPLACEMENT_ACCEPTED',
    'OBSERVATION_RESOLVED',
    'CLOSED',
    'ESCALATED',
    'NOTE'
  )),
  actor_profile_id uuid references public.profiles(id) on delete set null,
  reason_code text,
  metadata jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  check (public_id like 'RVE-%')
);

create table public.logistics_reconciliation_resolutions (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('RRS'),
  recovery_case_id uuid not null references public.logistics_recovery_cases(id) on delete restrict,
  scan_event_id uuid not null unique references public.logistics_scan_events(id) on delete restrict,
  resolution_type text not null check (resolution_type in (
    'REMOVED_FROM_FLOW',
    'IDENTIFIED_OTHER_FLOW',
    'AUTHORIZED_FALSE_POSITIVE'
  )),
  actor_profile_id uuid not null references public.profiles(id) on delete restrict,
  note text,
  created_at timestamptz not null default now(),
  check (public_id like 'RRS-%')
);

create index logistics_continuation_events_plan_idx
  on public.logistics_continuation_events(execution_plan_id,created_at desc);

create index logistics_recovery_events_case_idx
  on public.logistics_recovery_events(recovery_case_id,occurred_at,created_at);

create index logistics_recovery_cases_movement_idx
  on public.logistics_recovery_cases(movement_id,created_at desc);

create trigger logistics_continuation_events_append_only
before update or delete on public.logistics_continuation_events
for each row execute function public.tc_guard_logistics_append_only();

create trigger logistics_recovery_cases_append_only
before update or delete on public.logistics_recovery_cases
for each row execute function public.tc_guard_logistics_append_only();

create trigger logistics_recovery_events_append_only
before update or delete on public.logistics_recovery_events
for each row execute function public.tc_guard_logistics_append_only();

create trigger logistics_reconciliation_resolutions_append_only
before update or delete on public.logistics_reconciliation_resolutions
for each row execute function public.tc_guard_logistics_append_only();

alter table public.logistics_continuation_events enable row level security;
alter table public.logistics_recovery_cases enable row level security;
alter table public.logistics_recovery_events enable row level security;
alter table public.logistics_reconciliation_resolutions enable row level security;

revoke all on public.logistics_continuation_events from public,anon,authenticated;
revoke all on public.logistics_recovery_cases from public,anon,authenticated;
revoke all on public.logistics_recovery_events from public,anon,authenticated;
revoke all on public.logistics_reconciliation_resolutions from public,anon,authenticated;

grant select,insert on public.logistics_continuation_events to service_role;
grant select,insert on public.logistics_recovery_cases to service_role;
grant select,insert on public.logistics_recovery_events to service_role;
grant select,insert on public.logistics_reconciliation_resolutions to service_role;

comment on table public.logistics_hop_executions is
'Immutable materialization history. A routing HOP may have replacement executions; the effective current execution is the row not superseded by another row.';
comment on table public.logistics_recovery_cases is
'Stable recovery identity only. Recovery state/history is represented by append-only logistics_recovery_events.';

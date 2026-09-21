
create table public.logistics_runtime_outbox (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('RTO'),
  event_key text not null unique,
  event_type text not null check (event_type in (
    'DEMAND_ROUTABLE',
    'TRIP_AVAILABLE',
    'MATCH_ACCEPTED',
    'MOVEMENT_COMPLETED',
    'ARRIVAL_MISMATCH'
  )),
  entity_type text not null,
  entity_id uuid not null,
  demand_id uuid references public.logistics_demands(id) on delete restrict,
  trip_id uuid references public.logistics_trips(id) on delete restrict,
  match_id uuid references public.logistics_matches(id) on delete restrict,
  movement_id uuid references public.movements(id) on delete restrict,
  reconciliation_run_id uuid references public.logistics_movement_reconciliation_runs(id) on delete restrict,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'PENDING'
    check (status in ('PENDING','PROCESSING','SUCCEEDED','RETRY','DEAD')),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  max_attempts integer not null default 8 check (max_attempts between 1 and 50),
  available_at timestamptz not null default now(),
  locked_at timestamptz,
  processed_at timestamptz,
  last_error text,
  result jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (public_id like 'RTO-%')
);

create table public.logistics_runtime_attempts (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('RTAW'),
  outbox_id uuid not null references public.logistics_runtime_outbox(id) on delete restrict,
  attempt_no integer not null check (attempt_no >= 1),
  outcome text not null check (outcome in ('SUCCEEDED','RETRY','DEAD')),
  result jsonb,
  error_code text,
  error_message text,
  started_at timestamptz not null,
  finished_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (outbox_id,attempt_no),
  check (public_id like 'RTAW-%')
);

create index logistics_runtime_outbox_ready_idx
  on public.logistics_runtime_outbox(status,available_at,created_at)
  where status in ('PENDING','RETRY');

create index logistics_runtime_outbox_entity_idx
  on public.logistics_runtime_outbox(entity_type,entity_id,created_at desc);

create index logistics_runtime_attempts_outbox_idx
  on public.logistics_runtime_attempts(outbox_id,attempt_no);

create trigger logistics_runtime_outbox_updated_at
before update on public.logistics_runtime_outbox
for each row execute function public.tc_set_updated_at();

create trigger logistics_runtime_attempts_append_only
before update or delete on public.logistics_runtime_attempts
for each row execute function public.tc_guard_logistics_append_only();

alter table public.logistics_runtime_outbox enable row level security;
alter table public.logistics_runtime_attempts enable row level security;

revoke all on public.logistics_runtime_outbox from public,anon,authenticated;
revoke all on public.logistics_runtime_attempts from public,anon,authenticated;

grant select,insert,update on public.logistics_runtime_outbox to service_role;
grant select,insert on public.logistics_runtime_attempts to service_role;

comment on table public.logistics_runtime_outbox is
'Transactional outbox for asynchronous logistics orchestration. Business triggers enqueue only; the runtime worker performs routing/materialization/continuation after commit.';
comment on table public.logistics_runtime_attempts is
'Append-only worker-attempt evidence for logistics runtime outbox processing.';

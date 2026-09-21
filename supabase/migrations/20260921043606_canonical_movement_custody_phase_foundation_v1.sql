
create table public.logistics_movement_custody_phases (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('CHP'),
  movement_id uuid not null references public.movements(id) on delete restrict,
  package_id uuid not null references public.packages(id) on delete restrict,
  phase text not null check (phase in ('DEPARTURE','ARRIVAL')),
  from_profile_id uuid not null references public.profiles(id) on delete restrict,
  to_profile_id uuid not null references public.profiles(id) on delete restrict,
  status text not null default 'PLANNED'
    check (status in ('PLANNED','RELEASED','RECEIVED','CANCELLED','CONFLICT')),
  release_event_id text references public.event_inbox(event_id) on delete restrict,
  receive_event_id text references public.event_inbox(event_id) on delete restrict,
  release_occurred_at timestamptz,
  receive_occurred_at timestamptz,
  version bigint not null default 0 check (version >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (movement_id,package_id,phase),
  check (public_id like 'CHP-%'),
  check (from_profile_id <> to_profile_id),
  check (
    (status='PLANNED' and release_event_id is null and receive_event_id is null)
    or
    (status='RELEASED' and release_event_id is not null and receive_event_id is null)
    or
    (status='RECEIVED' and release_event_id is not null and receive_event_id is not null)
    or
    (status in ('CANCELLED','CONFLICT'))
  )
);

create table public.logistics_movement_reconciliation_runs (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('RCR'),
  movement_id uuid not null references public.movements(id) on delete restrict,
  manifest_id uuid not null references public.logistics_manifests(id) on delete restrict,
  run_no bigint not null check (run_no >= 1),
  status text not null check (status in ('MATCHED','MISMATCH')),
  expected_count integer not null check (expected_count >= 0),
  observed_expected_count integer not null check (observed_expected_count >= 0),
  missing_count integer not null check (missing_count >= 0),
  unexpected_count integer not null check (unexpected_count >= 0),
  created_at timestamptz not null default now(),
  unique (movement_id,manifest_id,run_no),
  check (public_id like 'RCR-%')
);

alter table public.logistics_scan_events
  add column idempotency_key text;

create unique index logistics_scan_events_idempotency_uidx
  on public.logistics_scan_events(idempotency_key)
  where idempotency_key is not null;

create index logistics_custody_phases_movement_phase_idx
  on public.logistics_movement_custody_phases(movement_id,phase,status);

create index logistics_reconciliation_runs_movement_idx
  on public.logistics_movement_reconciliation_runs(movement_id,created_at desc);

create trigger logistics_movement_custody_phases_updated_at
before update on public.logistics_movement_custody_phases
for each row execute function public.tc_set_updated_at();

create trigger logistics_movement_reconciliation_runs_append_only
before update or delete on public.logistics_movement_reconciliation_runs
for each row execute function public.tc_guard_logistics_append_only();

alter table public.logistics_movement_custody_phases enable row level security;
alter table public.logistics_movement_reconciliation_runs enable row level security;

revoke all on public.logistics_movement_custody_phases from public,anon,authenticated;
revoke all on public.logistics_movement_reconciliation_runs from public,anon,authenticated;

grant select,insert,update on public.logistics_movement_custody_phases to service_role;
grant select,insert on public.logistics_movement_reconciliation_runs to service_role;

comment on table public.logistics_movement_custody_phases is
'Canonical NODE_TO_NODE handshake coordination for two physical handoffs: DEPARTURE node-owner→CON and ARRIVAL CON→destination-node-owner. custody_events remains the append-only custody transfer ledger.';
comment on table public.logistics_movement_reconciliation_runs is
'Append-only comparison of expected movement packages against observed ARRIVAL/EXCEPTION scans for one manifest snapshot.';
comment on column public.logistics_scan_events.idempotency_key is
'Optional event idempotency key for canonical operational scans.';

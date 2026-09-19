begin;

create table if not exists public.tc_minor_protection_disclosure_requests (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('MDR'),
  signal_id uuid not null references public.tc_minor_protection_signals(id) on delete restrict,
  requested_by_profile_id uuid not null references public.profiles(id) on delete restrict,
  request_reason text not null,
  requested_scope jsonb not null default '{}'::jsonb,
  status text not null default 'PENDING' check (status in ('PENDING','APPROVED','REJECTED','EXPIRED','REVOKED')),
  approved_by_profile_id uuid null references public.profiles(id) on delete restrict,
  approval_reason text null,
  approved_scope jsonb not null default '{}'::jsonb,
  approved_at timestamptz null,
  expires_at timestamptz null,
  revoked_at timestamptz null,
  created_at timestamptz not null default now(),
  constraint tc_minor_disclosure_not_self_approved check (
    approved_by_profile_id is null or approved_by_profile_id <> requested_by_profile_id
  )
);

create table if not exists public.tc_minor_protection_disclosure_events (
  id uuid primary key default gen_random_uuid(),
  disclosure_request_id uuid not null references public.tc_minor_protection_disclosure_requests(id) on delete restrict,
  actor_profile_id uuid null references public.profiles(id) on delete restrict,
  event_type text not null,
  event_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.tc_minor_protection_disclosure_requests enable row level security;
alter table public.tc_minor_protection_disclosure_events enable row level security;

revoke all on public.tc_minor_protection_disclosure_requests from anon, authenticated;
revoke all on public.tc_minor_protection_disclosure_events from anon, authenticated;

create or replace function public.tc_guard_minor_disclosure_request()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_severity text;
begin
  select s.severity into v_severity
  from public.tc_minor_protection_signals s
  where s.id = new.signal_id;

  if v_severity is null then
    raise exception 'MINOR_PROTECTION_SIGNAL_NOT_FOUND';
  end if;

  if v_severity not in ('HIGH','CRITICAL') then
    raise exception 'MINOR_DATA_DISCLOSURE_ONLY_FOR_HIGH_OR_CRITICAL_RISK';
  end if;

  if tg_op = 'INSERT' then
    if new.status <> 'PENDING' then
      raise exception 'MINOR_DISCLOSURE_REQUEST_MUST_START_PENDING';
    end if;
    if new.approved_by_profile_id is not null or new.approved_at is not null then
      raise exception 'MINOR_DISCLOSURE_CANNOT_BE_PREAPPROVED';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_tc_minor_disclosure_request_guard on public.tc_minor_protection_disclosure_requests;
create trigger trg_tc_minor_disclosure_request_guard
before insert or update on public.tc_minor_protection_disclosure_requests
for each row execute function public.tc_guard_minor_disclosure_request();

create or replace function public.tc_block_minor_disclosure_event_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'MINOR_PROTECTION_DISCLOSURE_HISTORY_IS_IMMUTABLE';
end;
$$;

drop trigger if exists trg_tc_minor_disclosure_events_immutable on public.tc_minor_protection_disclosure_events;
create trigger trg_tc_minor_disclosure_events_immutable
before update or delete on public.tc_minor_protection_disclosure_events
for each row execute function public.tc_block_minor_disclosure_event_mutation();

insert into public.tc_feature_gates (
  feature_key, domain, display_name,
  source_status, backend_status, safety_status, legal_status, cultural_status, approval_status,
  is_enabled, source_reference, notes
)
values (
  'safety.minor_high_risk_disclosure',
  'SAFETY',
  'Acceso controlado a datos protegidos del menor en riesgo alto/crítico',
  'VERIFIED','VERIFIED','PENDING','PENDING','NOT_REQUIRED','PENDING',
  false,
  'TC minor protection policy',
  'Solo HIGH/CRITICAL. No concede acceso automático. Requiere autorización independiente, alcance mínimo, expiración y auditoría antes de habilitarse.'
)
on conflict (feature_key) do update set
  display_name = excluded.display_name,
  backend_status = 'VERIFIED',
  safety_status = 'PENDING',
  legal_status = 'PENDING',
  approval_status = 'PENDING',
  is_enabled = false,
  notes = excluded.notes,
  updated_at = now();

commit;
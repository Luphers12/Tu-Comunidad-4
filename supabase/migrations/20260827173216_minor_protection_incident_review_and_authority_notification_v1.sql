begin;

create table if not exists public.tc_minor_protection_incidents (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('MINC'),
  signal_id uuid not null references public.tc_minor_protection_signals(id) on delete restrict,
  community_id uuid null references public.communities(id) on delete set null,
  incident_status text not null default 'OPEN' check (incident_status in ('OPEN','TRIAGE','MONITORING','PROTECTED_REVIEW','ESCALATION_REVIEW','RESOLVED','NO_ACTION')),
  current_severity text not null check (current_severity in ('LOW','MEDIUM','HIGH','CRITICAL')),
  review_summary text null,
  external_notification_decision text not null default 'NOT_REVIEWED' check (external_notification_decision in ('NOT_REVIEWED','NOT_NEEDED','CONSIDER','APPROVED')),
  decision_reason text null,
  reviewed_by_profile_id uuid null references public.profiles(id) on delete set null,
  reviewed_at timestamptz null,
  resolved_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(signal_id)
);

create table if not exists public.tc_minor_protection_incident_events (
  id uuid primary key default gen_random_uuid(),
  incident_id uuid not null references public.tc_minor_protection_incidents(id) on delete restrict,
  actor_profile_id uuid null references public.profiles(id) on delete set null,
  event_type text not null check (event_type in ('CREATED','TRIAGED','SEVERITY_CHANGED','REVIEWED','MONITORING_STARTED','ESCALATION_REVIEW_STARTED','NOTIFICATION_DECISION','RESOLVED','NO_ACTION','NOTE')),
  event_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.tc_minor_protection_authority_notifications (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('MAN'),
  incident_id uuid not null references public.tc_minor_protection_incidents(id) on delete restrict,
  notification_mode text not null check (notification_mode in ('TERRITORIAL_ALERT','INDIVIDUAL_PROTECTED_REPORT')),
  authority_scope text not null default 'LOCAL_COMPETENT_AUTHORITY',
  authority_reference text null,
  territorial_summary jsonb not null default '{}'::jsonb,
  approved_scope jsonb not null default '{}'::jsonb,
  status text not null default 'DRAFT' check (status in ('DRAFT','APPROVED','SENT','CANCELLED','FAILED')),
  approved_by_profile_id uuid null references public.profiles(id) on delete set null,
  approved_at timestamptz null,
  sent_at timestamptz null,
  delivery_reference text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.tc_guard_minor_authority_notification()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_decision text;
  v_severity text;
begin
  select external_notification_decision, current_severity
    into v_decision, v_severity
  from public.tc_minor_protection_incidents
  where id = new.incident_id;

  if v_decision is distinct from 'APPROVED' then
    raise exception 'Authority notification requires reviewed incident with APPROVED external notification decision';
  end if;

  if new.notification_mode = 'INDIVIDUAL_PROTECTED_REPORT' and v_severity not in ('HIGH','CRITICAL') then
    raise exception 'Individual protected report is allowed only for HIGH or CRITICAL incidents';
  end if;

  if new.notification_mode = 'TERRITORIAL_ALERT' then
    if jsonb_typeof(new.territorial_summary) is distinct from 'object' then
      raise exception 'territorial_summary must be a JSON object';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_minor_authority_notification_guard on public.tc_minor_protection_authority_notifications;
create trigger trg_minor_authority_notification_guard
before insert or update of incident_id, notification_mode, status
on public.tc_minor_protection_authority_notifications
for each row execute function public.tc_guard_minor_authority_notification();

create or replace function public.tc_block_minor_incident_event_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'Minor protection incident events are immutable';
end;
$$;

drop trigger if exists trg_minor_incident_events_immutable on public.tc_minor_protection_incident_events;
create trigger trg_minor_incident_events_immutable
before update or delete on public.tc_minor_protection_incident_events
for each row execute function public.tc_block_minor_incident_event_mutation();

alter table public.tc_minor_protection_incidents enable row level security;
alter table public.tc_minor_protection_incident_events enable row level security;
alter table public.tc_minor_protection_authority_notifications enable row level security;

revoke all on public.tc_minor_protection_incidents from anon, authenticated;
revoke all on public.tc_minor_protection_incident_events from anon, authenticated;
revoke all on public.tc_minor_protection_authority_notifications from anon, authenticated;

grant select on public.tc_minor_protection_incidents to authenticated;
grant select on public.tc_minor_protection_incident_events to authenticated;
grant select on public.tc_minor_protection_authority_notifications to authenticated;

insert into public.tc_feature_gates (
  feature_key, domain, parent_feature_key, display_name,
  source_status, backend_status, safety_status, legal_status, cultural_status, approval_status,
  is_enabled, notes
)
values (
  'safety.minor_authority_notification', 'SAFETY', 'safety.minor_escalation',
  'Notificación revisada a autoridades por protección de menores',
  'PENDING','VERIFIED','PENDING','PENDING','NOT_REQUIRED','PENDING',
  false,
  'Una señal nunca notifica automáticamente. Debe existir un incidente revisado y una decisión humana documentada. La alerta territorial no incluye identidad del menor; un reporte individual protegido solo puede considerarse para HIGH/CRITICAL y bajo alcance mínimo necesario.'
)
on conflict (feature_key) do update set
  display_name = excluded.display_name,
  backend_status = excluded.backend_status,
  is_enabled = false,
  notes = excluded.notes,
  updated_at = now();

commit;
create table if not exists public.child_wellbeing_checkins (
  id uuid primary key default gen_random_uuid(),
  student_person_id uuid not null references public.persons(id) on delete cascade,
  learning_session_id uuid null references public.learning_media_sessions(id) on delete set null,
  checkin_type text not null check (checkin_type in ('ROUTINE','TRIGGERED','DISCLOSURE_FOLLOWUP')),
  prompt_key text not null,
  response_mode text not null default 'OPTIONAL' check (response_mode in ('OPTIONAL','VOICE','TEXT','CHOICE')),
  response_summary text null,
  distress_signal_level text not null default 'NONE' check (distress_signal_level in ('NONE','LOW','MODERATE','HIGH','IMMEDIATE')),
  created_at timestamptz not null default now()
);

create table if not exists public.child_safeguarding_cases (
  id uuid primary key default gen_random_uuid(),
  public_id text unique,
  student_person_id uuid not null references public.persons(id) on delete cascade,
  source_checkin_id uuid null references public.child_wellbeing_checkins(id) on delete set null,
  source_type text not null check (source_type in ('SELF_DISCLOSURE','WELLBEING_SIGNAL','TEACHER_REPORT','GUARDIAN_REPORT','CONTENT_REPORT','OTHER')),
  risk_level text not null check (risk_level in ('LOW','MODERATE','HIGH','IMMEDIATE')),
  case_status text not null default 'OPEN' check (case_status in ('OPEN','TRIAGE','ESCALATED','REFERRED','CLOSED')),
  suspected_harm_types text[] not null default '{}',
  summary text null,
  requires_human_review boolean not null default true,
  do_not_notify_guardian_automatically boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.child_safeguarding_actions (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.child_safeguarding_cases(id) on delete cascade,
  action_type text not null check (action_type in ('HUMAN_REVIEW','SAFE_MESSAGE','GUARDIAN_CONTACT','PROTECTIVE_CONTACT','PGN_REFERRAL','EMERGENCY_REFERRAL','DOCUMENT_PRESERVATION','OTHER')),
  actor_person_id uuid null references public.persons(id) on delete set null,
  notes text null,
  occurred_at timestamptz not null default now()
);

create index if not exists idx_child_checkins_student_created on public.child_wellbeing_checkins(student_person_id, created_at desc);
create index if not exists idx_child_cases_student_status on public.child_safeguarding_cases(student_person_id, case_status, created_at desc);
create index if not exists idx_child_actions_case_time on public.child_safeguarding_actions(case_id, occurred_at desc);

alter table public.child_wellbeing_checkins enable row level security;
alter table public.child_safeguarding_cases enable row level security;
alter table public.child_safeguarding_actions enable row level security;

revoke all on public.child_wellbeing_checkins from anon, authenticated;
revoke all on public.child_safeguarding_cases from anon, authenticated;
revoke all on public.child_safeguarding_actions from anon, authenticated;

grant select, insert on public.child_wellbeing_checkins to service_role;
grant select, insert, update on public.child_safeguarding_cases to service_role;
grant select, insert on public.child_safeguarding_actions to service_role;

comment on table public.child_wellbeing_checkins is 'Optional, non-leading wellbeing check-ins for minors. Never use as autonomous diagnosis or interrogation.';
comment on table public.child_safeguarding_cases is 'Human-review safeguarding workflow for suspected harm to minors. No autonomous abuse determination.';
comment on table public.child_safeguarding_actions is 'Auditable actions taken for child safeguarding cases.';
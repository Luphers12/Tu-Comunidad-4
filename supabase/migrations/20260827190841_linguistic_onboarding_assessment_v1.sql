begin;

create table if not exists public.linguistic_onboarding_sessions (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('LONB'),
  contributor_id uuid not null references public.linguistic_contributors(id) on delete cascade,
  language_id uuid not null references public.languages(id) on delete restrict,
  variant_id uuid null references public.language_variants(id) on delete restrict,
  community_id uuid null references public.communities(id) on delete set null,
  status text not null default 'STARTED' check (status in ('STARTED','INTERVIEW_COMPLETED','ASSESSMENT_REQUIRED','UNDER_REVIEW','VERIFIED','NEEDS_MORE_EVIDENCE','REJECTED','WITHDRAWN')),
  self_reported_proficiency text null,
  can_speak_self_reported boolean not null default false,
  can_understand_self_reported boolean not null default false,
  can_read_self_reported boolean not null default false,
  can_write_self_reported boolean not null default false,
  interested_roles text[] not null default '{}',
  experience_summary text null,
  community_knowledge_summary text null,
  availability_preferences jsonb not null default '{}'::jsonb,
  accessibility_preferences jsonb not null default '{}'::jsonb,
  interview_answers jsonb not null default '{}'::jsonb,
  completed_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (contributor_id, language_id, variant_id)
);

create table if not exists public.linguistic_assessment_templates (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('LAST'),
  template_code text not null unique,
  language_id uuid not null references public.languages(id) on delete restrict,
  variant_id uuid null references public.language_variants(id) on delete restrict,
  title text not null,
  description text not null,
  version integer not null default 1 check (version >= 1),
  status text not null default 'DRAFT' check (status in ('DRAFT','REVIEWED','APPROVED','RETIRED')),
  minimum_independent_reviews integer not null default 2 check (minimum_independent_reviews >= 1),
  allow_ai_assistance boolean not null default false,
  legal_status text not null default 'PENDING' check (legal_status in ('PENDING','APPROVED','BLOCKED','NOT_REQUIRED')),
  cultural_status text not null default 'PENDING' check (cultural_status in ('PENDING','APPROVED','BLOCKED','NOT_REQUIRED')),
  safety_status text not null default 'PENDING' check (safety_status in ('PENDING','APPROVED','BLOCKED','NOT_REQUIRED')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.linguistic_assessment_template_items (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null references public.linguistic_assessment_templates(id) on delete cascade,
  item_order integer not null check (item_order >= 1),
  competency text not null check (competency in ('SPEAK','UNDERSTAND','READ','WRITE','TRANSLATE','ORTHOGRAPHY','REVIEW','TRANSCRIBE','VOICE','CULTURAL_VALIDATE','TERMINOLOGY','UI_QA')),
  prompt_type text not null check (prompt_type in ('TEXT_RESPONSE','MULTIPLE_CHOICE','AUDIO_RESPONSE','CORRECTION','TRANSLATION','CONTEXT_JUDGMENT')),
  source_text text null,
  prompt_text text not null,
  context_note text null,
  rubric jsonb not null default '{}'::jsonb,
  max_score numeric(8,2) not null default 1 check (max_score > 0),
  is_required boolean not null default true,
  created_at timestamptz not null default now(),
  unique (template_id, item_order)
);

create table if not exists public.linguistic_assessment_attempts (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('LATT'),
  onboarding_session_id uuid not null references public.linguistic_onboarding_sessions(id) on delete cascade,
  template_id uuid not null references public.linguistic_assessment_templates(id) on delete restrict,
  contributor_id uuid not null references public.linguistic_contributors(id) on delete cascade,
  status text not null default 'IN_PROGRESS' check (status in ('IN_PROGRESS','SUBMITTED','UNDER_REVIEW','CHANGES_REQUIRED','PASSED','PARTIAL_PASS','NOT_PASSED','WITHDRAWN')),
  ai_assistance_used boolean not null default false,
  ai_assistance_details text null,
  started_at timestamptz not null default now(),
  submitted_at timestamptz null,
  finalized_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.linguistic_assessment_responses (
  id uuid primary key default gen_random_uuid(),
  attempt_id uuid not null references public.linguistic_assessment_attempts(id) on delete cascade,
  template_item_id uuid not null references public.linguistic_assessment_template_items(id) on delete restrict,
  response_text text null,
  audio_id uuid null references public.linguistic_audios(id) on delete set null,
  response_json jsonb not null default '{}'::jsonb,
  submitted_at timestamptz not null default now(),
  unique (attempt_id, template_item_id),
  check (response_text is not null or audio_id is not null or response_json <> '{}'::jsonb)
);

create table if not exists public.linguistic_assessment_reviews (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('LARV'),
  attempt_id uuid not null references public.linguistic_assessment_attempts(id) on delete cascade,
  reviewer_contributor_id uuid not null references public.linguistic_contributors(id) on delete restrict,
  review_role_code text not null,
  verdict text not null check (verdict in ('PASS','PARTIAL_PASS','MORE_EVIDENCE','NOT_PASS','CONFLICT')),
  competency_scores jsonb not null default '{}'::jsonb,
  verified_competencies text[] not null default '{}',
  observation text null,
  independent_attested boolean not null default false,
  conflict_of_interest_declared boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (attempt_id, reviewer_contributor_id, review_role_code)
);

create table if not exists public.linguistic_assessment_outcomes (
  id uuid primary key default gen_random_uuid(),
  attempt_id uuid not null unique references public.linguistic_assessment_attempts(id) on delete cascade,
  contributor_id uuid not null references public.linguistic_contributors(id) on delete cascade,
  language_id uuid not null references public.languages(id) on delete restrict,
  variant_id uuid null references public.language_variants(id) on delete restrict,
  status text not null default 'PENDING' check (status in ('PENDING','VERIFIED','PARTIALLY_VERIFIED','NEEDS_MORE_EVIDENCE','NOT_VERIFIED')),
  verified_competencies text[] not null default '{}',
  qualification_id uuid null references public.linguistic_contributor_qualifications(id) on delete set null,
  finalized_by_person_id uuid null references public.persons(id) on delete set null,
  finalized_at timestamptz null,
  rationale text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.tc_block_self_linguistic_assessment_review()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_owner uuid;
begin
  select contributor_id into v_owner
  from public.linguistic_assessment_attempts
  where id = new.attempt_id;

  if v_owner is null then
    raise exception 'ASSESSMENT_ATTEMPT_NOT_FOUND';
  end if;

  if new.reviewer_contributor_id = v_owner then
    raise exception 'SELF_REVIEW_NOT_ALLOWED';
  end if;

  if not new.independent_attested then
    raise exception 'INDEPENDENT_REVIEW_ATTESTATION_REQUIRED';
  end if;

  if new.conflict_of_interest_declared then
    raise exception 'CONFLICTED_REVIEW_CANNOT_COUNT';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_linguistic_assessment_review_independence on public.linguistic_assessment_reviews;
create trigger trg_linguistic_assessment_review_independence
before insert or update on public.linguistic_assessment_reviews
for each row execute function public.tc_block_self_linguistic_assessment_review();

create or replace function public.tc_guard_linguistic_task_activation()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.can_receive_tasks = true and old.can_receive_tasks = false then
    if not exists (
      select 1
      from public.linguistic_contributor_qualifications q
      where q.contributor_id = new.contributor_id
        and q.verification_status in ('VERIFIED','COMMUNITY_VERIFIED','EXPERT_VERIFIED')
    ) then
      raise exception 'VERIFIED_LINGUISTIC_QUALIFICATION_REQUIRED';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_linguistic_profile_task_activation on public.linguistic_profiles;
create trigger trg_linguistic_profile_task_activation
before update of can_receive_tasks on public.linguistic_profiles
for each row execute function public.tc_guard_linguistic_task_activation();

alter table public.linguistic_onboarding_sessions enable row level security;
alter table public.linguistic_assessment_templates enable row level security;
alter table public.linguistic_assessment_template_items enable row level security;
alter table public.linguistic_assessment_attempts enable row level security;
alter table public.linguistic_assessment_responses enable row level security;
alter table public.linguistic_assessment_reviews enable row level security;
alter table public.linguistic_assessment_outcomes enable row level security;

revoke all on public.linguistic_onboarding_sessions from anon, authenticated;
revoke all on public.linguistic_assessment_templates from anon, authenticated;
revoke all on public.linguistic_assessment_template_items from anon, authenticated;
revoke all on public.linguistic_assessment_attempts from anon, authenticated;
revoke all on public.linguistic_assessment_responses from anon, authenticated;
revoke all on public.linguistic_assessment_reviews from anon, authenticated;
revoke all on public.linguistic_assessment_outcomes from anon, authenticated;

insert into public.tc_feature_gates (
  feature_key, domain, parent_feature_key, display_name,
  source_status, backend_status, safety_status, legal_status, cultural_status, approval_status,
  is_enabled, notes
)
values
('linguistics.onboarding','LINGUISTICS','linguistics.work_program','Onboarding de contribuyentes lingüísticos','VERIFIED','VERIFIED','PENDING','PENDING','PENDING','PENDING',false,'Entrevista, selección de idioma/variante y preferencias. No habilita trabajo por sí sola.'),
('linguistics.assessment','LINGUISTICS','linguistics.work_program','Evaluación lingüística independiente','VERIFIED','VERIFIED','PENDING','PENDING','PENDING','PENDING',false,'Pruebas y revisión independiente. La persona no puede auto-validarse.'),
('linguistics.task_eligibility','LINGUISTICS','linguistics.work_program','Elegibilidad para recibir tareas lingüísticas','VERIFIED','VERIFIED','PENDING','PENDING','PENDING','PENDING',false,'Requiere calificación lingüística verificada antes de can_receive_tasks=true.')
on conflict (feature_key) do update
set display_name = excluded.display_name,
    backend_status = excluded.backend_status,
    notes = excluded.notes,
    updated_at = now();

commit;
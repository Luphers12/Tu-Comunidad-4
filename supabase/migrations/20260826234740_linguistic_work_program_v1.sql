begin;

create sequence if not exists public.ljob_seq;
create sequence if not exists public.ljterm_seq;
create sequence if not exists public.lqual_seq;
create sequence if not exists public.ljapp_seq;
create sequence if not exists public.ltask_seq;
create sequence if not exists public.lasn_seq;
create sequence if not exists public.lsub_seq;
create sequence if not exists public.lauth_seq;
create sequence if not exists public.lrwd_seq;
create sequence if not exists public.lwev_seq;

create table if not exists public.linguistic_jobs (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default ('LJOB-' || lpad(nextval('public.ljob_seq')::text, 4, '0')),
  job_code text not null unique,
  title text not null,
  description text not null,
  target_language_id uuid not null references public.languages(id) on delete restrict,
  target_variant_id uuid null,
  community_id uuid null references public.communities(id) on delete restrict,
  status text not null default 'DRAFT' check (status in ('DRAFT','OPEN','PAUSED','CLOSED','ARCHIVED')),
  engagement_model text not null default 'COMMUNITY_CONTRIBUTION' check (engagement_model in ('COMMUNITY_CONTRIBUTION','PAID_TASK_PENDING_LEGAL','TC_CREDITS_PENDING','EMPLOYMENT_PENDING')),
  compensation_mode text not null default 'NONE' check (compensation_mode in ('NONE','TC_CREDITS','MONEY','MIXED')),
  compensation_status text not null default 'DISABLED' check (compensation_status in ('DISABLED','PENDING_LEGAL','PENDING_APPROVAL','APPROVED')),
  minimum_age integer null check (minimum_age is null or minimum_age >= 0),
  requires_identity_verification boolean not null default false,
  requires_variant_selection boolean not null default true,
  human_validation_required boolean not null default true,
  minimum_independent_reviews integer not null default 2 check (minimum_independent_reviews >= 1),
  legal_review_status text not null default 'PENDING' check (legal_review_status in ('PENDING','IN_REVIEW','APPROVED','BLOCKED')),
  cultural_review_status text not null default 'PENDING' check (cultural_review_status in ('PENDING','IN_REVIEW','APPROVED','BLOCKED')),
  safety_review_status text not null default 'PENDING' check (safety_review_status in ('PENDING','IN_REVIEW','APPROVED','BLOCKED')),
  opens_at timestamptz null,
  closes_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint linguistic_jobs_variant_fk foreign key (target_language_id, target_variant_id)
    references public.language_variants(language_id, id) on delete restrict,
  constraint linguistic_jobs_dates_ck check (closes_at is null or opens_at is null or closes_at >= opens_at)
);

create table if not exists public.linguistic_job_terms (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default ('LJTERM-' || lpad(nextval('public.ljterm_seq')::text, 4, '0')),
  job_id uuid not null references public.linguistic_jobs(id) on delete restrict,
  version integer not null check (version >= 1),
  status text not null default 'DRAFT' check (status in ('DRAFT','ACTIVE','RETIRED')),
  requirements jsonb not null default '{}'::jsonb,
  rules jsonb not null default '{}'::jsonb,
  rights_notice jsonb not null default '{}'::jsonb,
  required_grants jsonb not null default '{}'::jsonb,
  optional_grants jsonb not null default '{}'::jsonb,
  retention_notice jsonb not null default '{}'::jsonb,
  privacy_notice jsonb not null default '{}'::jsonb,
  compensation_notice jsonb not null default '{}'::jsonb,
  effective_at timestamptz null,
  created_at timestamptz not null default now(),
  unique (job_id, version)
);

create table if not exists public.linguistic_contributor_qualifications (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default ('LQUAL-' || lpad(nextval('public.lqual_seq')::text, 4, '0')),
  contributor_id uuid not null references public.linguistic_contributors(id) on delete restrict,
  language_id uuid not null references public.languages(id) on delete restrict,
  variant_id uuid null,
  proficiency text not null check (proficiency in ('NATIVE_SELF_REPORTED','FLUENT_SELF_REPORTED','HERITAGE_SPEAKER','COMMUNITY_VALIDATED','PROFESSIONAL_VALIDATED','LEARNER')),
  can_translate boolean not null default false,
  can_review boolean not null default false,
  can_record_audio boolean not null default false,
  can_transcribe boolean not null default false,
  can_cultural_validate boolean not null default false,
  verification_status text not null default 'SELF_REPORTED' check (verification_status in ('SELF_REPORTED','PENDING','VERIFIED','REJECTED')),
  evidence_note text null,
  verified_by_person_id uuid null references public.persons(id) on delete restrict,
  verified_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint linguistic_contributor_qualifications_variant_fk foreign key (language_id, variant_id)
    references public.language_variants(language_id, id) on delete restrict
);
create unique index if not exists uq_lqual_variant on public.linguistic_contributor_qualifications(contributor_id, language_id, variant_id) where variant_id is not null;
create unique index if not exists uq_lqual_language_general on public.linguistic_contributor_qualifications(contributor_id, language_id) where variant_id is null;

create table if not exists public.linguistic_job_applications (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default ('LJAPP-' || lpad(nextval('public.ljapp_seq')::text, 4, '0')),
  job_id uuid not null references public.linguistic_jobs(id) on delete restrict,
  contributor_id uuid not null references public.linguistic_contributors(id) on delete restrict,
  terms_id uuid not null references public.linguistic_job_terms(id) on delete restrict,
  status text not null default 'APPLIED' check (status in ('APPLIED','SCREENING','APPROVED','REJECTED','WITHDRAWN','SUSPENDED')),
  answers jsonb not null default '{}'::jsonb,
  age_requirement_attested boolean not null default false,
  rules_acknowledged boolean not null default false,
  rights_notice_acknowledged boolean not null default false,
  privacy_notice_acknowledged boolean not null default false,
  submitted_at timestamptz not null default now(),
  reviewed_by_person_id uuid null references public.persons(id) on delete restrict,
  reviewed_at timestamptz null,
  review_note text null,
  updated_at timestamptz not null default now(),
  unique (job_id, contributor_id)
);

create table if not exists public.linguistic_tasks (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default ('LTASK-' || lpad(nextval('public.ltask_seq')::text, 5, '0')),
  job_id uuid not null references public.linguistic_jobs(id) on delete restrict,
  source_key text null,
  ui_key_id uuid null references public.ui_interface_keys(id) on delete restrict,
  concept_id uuid null references public.master_concepts(id) on delete restrict,
  task_type text not null check (task_type in ('TRANSLATE_UI','REVIEW_TRANSLATION','RECORD_AUDIO','REVIEW_AUDIO','TRANSCRIBE','TERMINOLOGY','CULTURAL_VALIDATE')),
  source_language_tag text not null default 'es-GT',
  source_text text not null,
  context_note text null,
  target_language_id uuid not null references public.languages(id) on delete restrict,
  target_variant_id uuid null,
  status text not null default 'DRAFT' check (status in ('DRAFT','READY','OPEN','ASSIGNED','IN_REVIEW','APPROVED','REJECTED','PAUSED','ARCHIVED')),
  priority integer not null default 100,
  sensitivity text not null default 'NORMAL' check (sensitivity in ('NORMAL','IDENTITY','PAYMENT','LEGAL','SAFETY','CHILD')),
  required_submission_count integer not null default 1 check (required_submission_count >= 1),
  required_review_count integer not null default 2 check (required_review_count >= 1),
  max_assignments integer not null default 3 check (max_assignments >= 1),
  allow_ai_assistance boolean not null default false,
  requires_ai_disclosure boolean not null default true,
  requires_source_citation boolean not null default false,
  requires_audio boolean not null default false,
  due_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(job_id, source_key),
  constraint linguistic_tasks_variant_fk foreign key (target_language_id, target_variant_id)
    references public.language_variants(language_id, id) on delete restrict
);

create table if not exists public.linguistic_task_assignments (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default ('LASN-' || lpad(nextval('public.lasn_seq')::text, 5, '0')),
  task_id uuid not null references public.linguistic_tasks(id) on delete restrict,
  contributor_id uuid not null references public.linguistic_contributors(id) on delete restrict,
  assignment_role text not null check (assignment_role in ('TRANSLATOR','REVIEWER','SPEAKER','TRANSCRIBER','CULTURAL_VALIDATOR')),
  status text not null default 'ASSIGNED' check (status in ('ASSIGNED','ACCEPTED','SUBMITTED','CHANGES_REQUESTED','APPROVED','REJECTED','CANCELED','EXPIRED')),
  assigned_by_person_id uuid null references public.persons(id) on delete restrict,
  assigned_at timestamptz not null default now(),
  accepted_at timestamptz null,
  due_at timestamptz null,
  completed_at timestamptz null,
  updated_at timestamptz not null default now(),
  unique(task_id, contributor_id, assignment_role)
);

create table if not exists public.linguistic_task_submissions (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default ('LSUB-' || lpad(nextval('public.lsub_seq')::text, 5, '0')),
  assignment_id uuid not null references public.linguistic_task_assignments(id) on delete restrict,
  version integer not null default 1 check (version >= 1),
  submitted_text text null,
  translation_proposal_id uuid null references public.translation_proposals(id) on delete restrict,
  audio_id uuid null references public.linguistic_audios(id) on delete restrict,
  variant_usage_note text null,
  ai_assistance_disclosed boolean not null default false,
  ai_assistance_details text null,
  sources_consulted jsonb not null default '[]'::jsonb,
  contributor_note text null,
  status text not null default 'SUBMITTED' check (status in ('SUBMITTED','IN_REVIEW','CHANGES_REQUESTED','APPROVED','REJECTED','WITHDRAWN')),
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz null,
  updated_at timestamptz not null default now(),
  unique(assignment_id, version),
  constraint linguistic_task_submissions_content_ck check (submitted_text is not null or translation_proposal_id is not null or audio_id is not null)
);

create table if not exists public.linguistic_contribution_authorizations (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default ('LAUTH-' || lpad(nextval('public.lauth_seq')::text, 5, '0')),
  submission_id uuid not null references public.linguistic_task_submissions(id) on delete restrict,
  contributor_id uuid not null references public.linguistic_contributors(id) on delete restrict,
  consent_id uuid null references public.linguistic_consents(id) on delete restrict,
  authorization_version integer not null default 1 check (authorization_version >= 1),
  status text not null default 'GRANTED' check (status in ('GRANTED','REVOKED','EXPIRED')),
  internal_review_allowed boolean not null default true,
  app_ui_publication_allowed boolean not null default false,
  derivative_formatting_allowed boolean not null default false,
  commercial_use_allowed boolean not null default false,
  public_attribution_allowed boolean not null default false,
  marketing_allowed boolean not null default false,
  research_sharing_allowed boolean not null default false,
  third_party_sharing_allowed boolean not null default false,
  ai_training_allowed boolean not null default false,
  voice_modeling_allowed boolean not null default false,
  public_audio_allowed boolean not null default false,
  cultural_archive_allowed boolean not null default false,
  archive_access_level text not null default 'DO_NOT_ARCHIVE' check (archive_access_level in ('DO_NOT_ARCHIVE','INTERNAL','COMMUNITY','PUBLIC','RESTRICTED')),
  attribution_preference text not null default 'ANONYMOUS' check (attribution_preference in ('ANONYMOUS','PUBLIC_ID','DISPLAY_NAME','COMMUNITY_ONLY')),
  attribution_display_name text null,
  license_type text not null default 'LIMITED_PERMISSION',
  geographic_scope text not null default 'TU_COMUNIDAD_SERVICES',
  expires_at timestamptz null,
  granted_at timestamptz not null default now(),
  revoked_at timestamptz null,
  revocation_reason text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(submission_id, authorization_version),
  constraint linguistic_contribution_authorizations_revoke_ck check (revoked_at is null or revoked_at >= granted_at),
  constraint linguistic_contribution_authorizations_name_ck check (attribution_preference <> 'DISPLAY_NAME' or attribution_display_name is not null)
);

create table if not exists public.linguistic_work_rewards (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default ('LRWD-' || lpad(nextval('public.lrwd_seq')::text, 5, '0')),
  submission_id uuid not null unique references public.linguistic_task_submissions(id) on delete restrict,
  reward_type text not null default 'NONE' check (reward_type in ('NONE','TC_CREDITS','MONEY')),
  amount numeric(14,2) null check (amount is null or amount >= 0),
  currency text null,
  status text not null default 'PENDING_REVIEW' check (status in ('NOT_ELIGIBLE','PENDING_REVIEW','PENDING_LEGAL','PENDING_APPROVAL','APPROVED','ISSUED','CANCELED')),
  external_reference text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint linguistic_work_rewards_currency_ck check ((reward_type='MONEY' and currency is not null) or reward_type <> 'MONEY')
);

create table if not exists public.linguistic_work_events (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default ('LWEV-' || lpad(nextval('public.lwev_seq')::text, 6, '0')),
  entity_type text not null check (entity_type in ('JOB','TERMS','APPLICATION','TASK','ASSIGNMENT','SUBMISSION','AUTHORIZATION','REWARD','QUALIFICATION')),
  entity_id uuid not null,
  event_type text not null,
  actor_person_id uuid null references public.persons(id) on delete restrict,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create or replace function public.tc_linguistic_touch_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create or replace function public.tc_linguistic_submission_guard()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Linguistic submissions are append-only; deletion is not allowed';
  end if;
  if new.assignment_id is distinct from old.assignment_id
     or new.version is distinct from old.version
     or new.submitted_text is distinct from old.submitted_text
     or new.variant_usage_note is distinct from old.variant_usage_note
     or new.ai_assistance_disclosed is distinct from old.ai_assistance_disclosed
     or new.ai_assistance_details is distinct from old.ai_assistance_details
     or new.sources_consulted is distinct from old.sources_consulted
     or new.contributor_note is distinct from old.contributor_note then
    raise exception 'Submitted linguistic content is immutable; create a new submission version';
  end if;
  return new;
end;
$$;

create or replace function public.tc_linguistic_authorization_guard()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Linguistic authorization history cannot be deleted';
  end if;
  if new.submission_id is distinct from old.submission_id
     or new.contributor_id is distinct from old.contributor_id
     or new.authorization_version is distinct from old.authorization_version
     or new.internal_review_allowed is distinct from old.internal_review_allowed
     or new.app_ui_publication_allowed is distinct from old.app_ui_publication_allowed
     or new.derivative_formatting_allowed is distinct from old.derivative_formatting_allowed
     or new.commercial_use_allowed is distinct from old.commercial_use_allowed
     or new.public_attribution_allowed is distinct from old.public_attribution_allowed
     or new.marketing_allowed is distinct from old.marketing_allowed
     or new.research_sharing_allowed is distinct from old.research_sharing_allowed
     or new.third_party_sharing_allowed is distinct from old.third_party_sharing_allowed
     or new.ai_training_allowed is distinct from old.ai_training_allowed
     or new.voice_modeling_allowed is distinct from old.voice_modeling_allowed
     or new.public_audio_allowed is distinct from old.public_audio_allowed
     or new.cultural_archive_allowed is distinct from old.cultural_archive_allowed
     or new.archive_access_level is distinct from old.archive_access_level
     or new.attribution_preference is distinct from old.attribution_preference
     or new.attribution_display_name is distinct from old.attribution_display_name
     or new.license_type is distinct from old.license_type
     or new.geographic_scope is distinct from old.geographic_scope then
    raise exception 'Authorization grants are immutable; create a new authorization version';
  end if;
  return new;
end;
$$;

create or replace function public.tc_linguistic_event_guard()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  raise exception 'Linguistic work events are append-only';
end;
$$;

do $$
declare r record;
begin
  for r in select unnest(array[
    'linguistic_jobs','linguistic_contributor_qualifications','linguistic_job_applications','linguistic_tasks',
    'linguistic_task_assignments','linguistic_task_submissions','linguistic_contribution_authorizations','linguistic_work_rewards'
  ]) as tbl loop
    execute format('drop trigger if exists trg_%I_touch on public.%I', r.tbl, r.tbl);
    execute format('create trigger trg_%I_touch before update on public.%I for each row execute function public.tc_linguistic_touch_updated_at()', r.tbl, r.tbl);
  end loop;
end $$;

drop trigger if exists trg_linguistic_task_submissions_guard on public.linguistic_task_submissions;
create trigger trg_linguistic_task_submissions_guard
before update or delete on public.linguistic_task_submissions
for each row execute function public.tc_linguistic_submission_guard();

drop trigger if exists trg_linguistic_contribution_authorizations_guard on public.linguistic_contribution_authorizations;
create trigger trg_linguistic_contribution_authorizations_guard
before update or delete on public.linguistic_contribution_authorizations
for each row execute function public.tc_linguistic_authorization_guard();

drop trigger if exists trg_linguistic_work_events_guard on public.linguistic_work_events;
create trigger trg_linguistic_work_events_guard
before update or delete on public.linguistic_work_events
for each row execute function public.tc_linguistic_event_guard();

alter table public.linguistic_jobs enable row level security;
alter table public.linguistic_job_terms enable row level security;
alter table public.linguistic_contributor_qualifications enable row level security;
alter table public.linguistic_job_applications enable row level security;
alter table public.linguistic_tasks enable row level security;
alter table public.linguistic_task_assignments enable row level security;
alter table public.linguistic_task_submissions enable row level security;
alter table public.linguistic_contribution_authorizations enable row level security;
alter table public.linguistic_work_rewards enable row level security;
alter table public.linguistic_work_events enable row level security;

revoke all on public.linguistic_jobs from anon, authenticated;
revoke all on public.linguistic_job_terms from anon, authenticated;
revoke all on public.linguistic_contributor_qualifications from anon, authenticated;
revoke all on public.linguistic_job_applications from anon, authenticated;
revoke all on public.linguistic_tasks from anon, authenticated;
revoke all on public.linguistic_task_assignments from anon, authenticated;
revoke all on public.linguistic_task_submissions from anon, authenticated;
revoke all on public.linguistic_contribution_authorizations from anon, authenticated;
revoke all on public.linguistic_work_rewards from anon, authenticated;
revoke all on public.linguistic_work_events from anon, authenticated;

grant all on public.linguistic_jobs to service_role;
grant all on public.linguistic_job_terms to service_role;
grant all on public.linguistic_contributor_qualifications to service_role;
grant all on public.linguistic_job_applications to service_role;
grant all on public.linguistic_tasks to service_role;
grant all on public.linguistic_task_assignments to service_role;
grant all on public.linguistic_task_submissions to service_role;
grant all on public.linguistic_contribution_authorizations to service_role;
grant all on public.linguistic_work_rewards to service_role;
grant all on public.linguistic_work_events to service_role;

create or replace function public.tc_list_open_linguistic_jobs()
returns table(
  public_id text,
  job_code text,
  title text,
  description text,
  language_name text,
  variant_name text,
  engagement_model text,
  compensation_mode text,
  opens_at timestamptz,
  closes_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select j.public_id, j.job_code, j.title, j.description,
         l.name, lv.name, j.engagement_model, j.compensation_mode, j.opens_at, j.closes_at
    from public.linguistic_jobs j
    join public.languages l on l.id=j.target_language_id
    left join public.language_variants lv on lv.id=j.target_variant_id
   where j.status='OPEN'
     and j.legal_review_status='APPROVED'
     and j.cultural_review_status='APPROVED'
     and j.safety_review_status='APPROVED'
     and (j.opens_at is null or j.opens_at <= now())
     and (j.closes_at is null or j.closes_at >= now())
   order by j.created_at, j.public_id;
$$;

create or replace function public.tc_apply_linguistic_job(
  p_job_public_id text,
  p_answers jsonb default '{}'::jsonb,
  p_age_requirement_attested boolean default false,
  p_rules_acknowledged boolean default false,
  p_rights_notice_acknowledged boolean default false,
  p_privacy_notice_acknowledged boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_person_id uuid;
  v_contributor_id uuid;
  v_job public.linguistic_jobs%rowtype;
  v_terms_id uuid;
  v_application_id uuid;
  v_application_public_id text;
begin
  select p.id into v_person_id from public.persons p where p.auth_user_id = auth.uid();
  if v_person_id is null then
    raise exception 'Authenticated person profile required';
  end if;

  select * into v_job from public.linguistic_jobs where public_id=p_job_public_id;
  if v_job.id is null or v_job.status <> 'OPEN' then
    raise exception 'Linguistic job is not open';
  end if;
  if v_job.legal_review_status <> 'APPROVED' or v_job.cultural_review_status <> 'APPROVED' or v_job.safety_review_status <> 'APPROVED' then
    raise exception 'Linguistic job is not approved for applications';
  end if;
  if v_job.minimum_age is not null and not p_age_requirement_attested then
    raise exception 'Age requirement acknowledgement is required';
  end if;
  if not p_rules_acknowledged or not p_rights_notice_acknowledged or not p_privacy_notice_acknowledged then
    raise exception 'Rules, rights, and privacy notices must be acknowledged';
  end if;

  select id into v_terms_id
    from public.linguistic_job_terms
   where job_id=v_job.id and status='ACTIVE'
   order by version desc limit 1;
  if v_terms_id is null then
    raise exception 'No active terms for this linguistic job';
  end if;

  insert into public.linguistic_contributors(person_id)
  values (v_person_id)
  on conflict (person_id) do update set is_active=true
  returning id into v_contributor_id;

  insert into public.linguistic_job_applications(
    job_id, contributor_id, terms_id, answers, age_requirement_attested,
    rules_acknowledged, rights_notice_acknowledged, privacy_notice_acknowledged
  ) values (
    v_job.id, v_contributor_id, v_terms_id, coalesce(p_answers,'{}'::jsonb), p_age_requirement_attested,
    p_rules_acknowledged, p_rights_notice_acknowledged, p_privacy_notice_acknowledged
  )
  on conflict (job_id, contributor_id) do update
    set terms_id=excluded.terms_id,
        answers=excluded.answers,
        age_requirement_attested=excluded.age_requirement_attested,
        rules_acknowledged=excluded.rules_acknowledged,
        rights_notice_acknowledged=excluded.rights_notice_acknowledged,
        privacy_notice_acknowledged=excluded.privacy_notice_acknowledged,
        status=case when public.linguistic_job_applications.status='WITHDRAWN' then 'APPLIED' else public.linguistic_job_applications.status end,
        updated_at=now()
  returning id, public_id into v_application_id, v_application_public_id;

  insert into public.linguistic_work_events(entity_type,entity_id,event_type,actor_person_id,payload)
  values ('APPLICATION',v_application_id,'APPLIED',v_person_id,jsonb_build_object('job_public_id',p_job_public_id,'terms_id',v_terms_id));

  return jsonb_build_object('success',true,'application_public_id',v_application_public_id,'status','APPLIED');
end;
$$;

create or replace function public.tc_list_my_linguistic_applications()
returns table(
  application_public_id text,
  job_public_id text,
  title text,
  status text,
  language_name text,
  variant_name text,
  submitted_at timestamptz,
  updated_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select a.public_id, j.public_id, j.title, a.status, l.name, lv.name, a.submitted_at, a.updated_at
    from public.linguistic_job_applications a
    join public.linguistic_contributors c on c.id=a.contributor_id
    join public.persons p on p.id=c.person_id
    join public.linguistic_jobs j on j.id=a.job_id
    join public.languages l on l.id=j.target_language_id
    left join public.language_variants lv on lv.id=j.target_variant_id
   where p.auth_user_id=auth.uid()
   order by a.submitted_at desc;
$$;

insert into public.tc_feature_gates(feature_key,domain,parent_feature_key,display_name,source_status,backend_status,safety_status,legal_status,cultural_status,approval_status,is_enabled,notes)
values
 ('linguistics.work_program','LINGUISTICS',null,'Programa de trabajo lingüístico','VERIFIED','VERIFIED','PENDING','PENDING','PENDING','PENDING',false,'Raíz del dominio lingüístico. Fail-closed: habilita solo tras aprobación de seguridad, legal y cultural.')
on conflict(feature_key) do update set
 backend_status='VERIFIED',
 updated_at=now();

revoke all on function public.tc_list_open_linguistic_jobs() from public;
revoke all on function public.tc_apply_linguistic_job(text,jsonb,boolean,boolean,boolean,boolean) from public;
revoke all on function public.tc_list_my_linguistic_applications() from public;
grant execute on function public.tc_list_open_linguistic_jobs() to anon, authenticated;
grant execute on function public.tc_apply_linguistic_job(text,jsonb,boolean,boolean,boolean,boolean) to authenticated;
grant execute on function public.tc_list_my_linguistic_applications() to authenticated;

commit;
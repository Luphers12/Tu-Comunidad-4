begin;

alter table public.linguistic_tasks
  add column if not exists required_role_code text,
  add column if not exists context_name text,
  add column if not exists requires_exact_variant boolean not null default true,
  add column if not exists requires_verified_domain boolean not null default false,
  add column if not exists assignment_mode text not null default 'SUGGESTED';

do $$ begin
  alter table public.linguistic_tasks
    add constraint linguistic_tasks_required_role_code_check
    check (required_role_code is null or required_role_code = any (array[
      'TRANSLATOR','ORTHOGRAPHY_CORRECTOR','PEER_REVIEWER','LINGUISTIC_VALIDATOR',
      'CULTURAL_VALIDATOR','TERMINOLOGY_SPECIALIST','TRANSCRIBER','VOICE_SPEAKER',
      'UI_QA','FINAL_REVIEWER'
    ]));
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.linguistic_tasks
    add constraint linguistic_tasks_assignment_mode_check
    check (assignment_mode = any (array['MANUAL','SUGGESTED','AUTO_PENDING_APPROVAL']));
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.linguistic_tasks
    add constraint linguistic_tasks_context_name_fkey
    foreign key (context_name) references public.linguistic_context_policies(context_name) on delete restrict;
exception when duplicate_object then null; end $$;

update public.linguistic_tasks
set required_role_code = case task_type
  when 'TRANSLATE_UI' then 'TRANSLATOR'
  when 'REVIEW_TRANSLATION' then 'PEER_REVIEWER'
  when 'RECORD_AUDIO' then 'VOICE_SPEAKER'
  when 'REVIEW_AUDIO' then 'LINGUISTIC_VALIDATOR'
  when 'TRANSCRIBE' then 'TRANSCRIBER'
  when 'TERMINOLOGY' then 'TERMINOLOGY_SPECIALIST'
  when 'CULTURAL_VALIDATE' then 'CULTURAL_VALIDATOR'
  else required_role_code
end
where required_role_code is null;

update public.linguistic_tasks
set context_name = case sensitivity
  when 'NORMAL' then 'NORMAL_UI'
  when 'IDENTITY' then 'IDENTITY'
  when 'PAYMENT' then 'PAYMENT'
  when 'LEGAL' then 'LEGAL'
  when 'SAFETY' then 'SAFETY'
  when 'CHILD' then 'SAFETY'
  else 'NORMAL_UI'
end
where context_name is null;

update public.linguistic_tasks
set requires_verified_domain = case
  when sensitivity in ('IDENTITY','PAYMENT','LEGAL','SAFETY','CHILD') then true
  else false
end;

alter table public.linguistic_profiles
  add column if not exists max_active_assignments integer not null default 5;

do $$ begin
  alter table public.linguistic_profiles
    add constraint linguistic_profiles_max_active_assignments_check
    check (max_active_assignments between 1 and 50);
exception when duplicate_object then null; end $$;

create sequence if not exists linguistic_match_run_seq;
create table if not exists public.linguistic_task_match_runs (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default ('LMRUN-' || lpad(nextval('linguistic_match_run_seq')::text, 6, '0')),
  task_id uuid not null references public.linguistic_tasks(id) on delete restrict,
  requested_role_code text not null,
  status text not null default 'CALCULATED' check (status = any (array['CALCULATED','REVIEWED','EXPIRED','CANCELED'])),
  candidate_count integer not null default 0 check (candidate_count >= 0),
  generated_by_person_id uuid null references public.persons(id) on delete set null,
  generated_at timestamptz not null default now(),
  expires_at timestamptz null,
  notes text null
);

create table if not exists public.linguistic_task_match_candidates (
  id uuid primary key default gen_random_uuid(),
  match_run_id uuid not null references public.linguistic_task_match_runs(id) on delete cascade,
  contributor_id uuid not null references public.linguistic_contributors(id) on delete restrict,
  rank_position integer not null check (rank_position >= 1),
  score numeric(8,2) not null,
  active_assignment_count integer not null default 0 check (active_assignment_count >= 0),
  exact_variant_match boolean not null,
  domain_verified boolean not null,
  reputation_weight numeric(5,2) not null default 1.00,
  conflict_detected boolean not null default false,
  eligibility_snapshot jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (match_run_id, contributor_id),
  unique (match_run_id, rank_position)
);

create sequence if not exists linguistic_match_suggestion_seq;
create table if not exists public.linguistic_task_assignment_suggestions (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default ('LMSUG-' || lpad(nextval('linguistic_match_suggestion_seq')::text, 6, '0')),
  match_run_id uuid not null references public.linguistic_task_match_runs(id) on delete restrict,
  task_id uuid not null references public.linguistic_tasks(id) on delete restrict,
  contributor_id uuid not null references public.linguistic_contributors(id) on delete restrict,
  assignment_role text not null,
  status text not null default 'SUGGESTED' check (status = any (array['SUGGESTED','APPROVED','REJECTED','EXPIRED','ASSIGNED'])),
  approved_by_person_id uuid null references public.persons(id) on delete set null,
  approved_at timestamptz null,
  rejection_reason text null,
  created_at timestamptz not null default now(),
  unique (match_run_id, task_id, contributor_id, assignment_role)
);

alter table public.linguistic_task_match_runs enable row level security;
alter table public.linguistic_task_match_candidates enable row level security;
alter table public.linguistic_task_assignment_suggestions enable row level security;

revoke all on public.linguistic_task_match_runs from anon, authenticated;
revoke all on public.linguistic_task_match_candidates from anon, authenticated;
revoke all on public.linguistic_task_assignment_suggestions from anon, authenticated;

grant select on public.linguistic_task_match_runs to authenticated;
grant select on public.linguistic_task_match_candidates to authenticated;
grant select on public.linguistic_task_assignment_suggestions to authenticated;

insert into public.capabilities(name)
select 'linguistic.task.match'
where not exists (select 1 from public.capabilities where name='linguistic.task.match');

insert into public.capabilities(name)
select 'linguistic.task.assign'
where not exists (select 1 from public.capabilities where name='linguistic.task.assign');

insert into public.tc_feature_gates(
  feature_key, domain, display_name, source_status, backend_status,
  safety_status, legal_status, cultural_status, approval_status, is_enabled, notes
)
select
  'linguistics.task_matching','LINGUISTICS','Matching de tareas lingüísticas',
  'VERIFIED','VERIFIED','PENDING','PENDING','PENDING','PENDING',false,
  'Calcula candidatos elegibles; no asigna trabajo por sí solo. Matching exacto por rol, idioma/variante, dominio, disponibilidad, carga y conflicto.'
where not exists (select 1 from public.tc_feature_gates where feature_key='linguistics.task_matching');

insert into public.tc_feature_gates(
  feature_key, domain, display_name, source_status, backend_status,
  safety_status, legal_status, cultural_status, approval_status, is_enabled, notes
)
select
  'linguistics.task_auto_assignment','LINGUISTICS','Autoasignación de tareas lingüísticas',
  'VERIFIED','VERIFIED','PENDING','PENDING','PENDING','PENDING',false,
  'Permanece desactivado. Cualquier autoasignación futura requerirá aprobación explícita y mantendrá reglas anti-conflicto.'
where not exists (select 1 from public.tc_feature_gates where feature_key='linguistics.task_auto_assignment');

create or replace function public.tc_linguistic_task_candidates(p_task_id uuid)
returns table (
  contributor_id uuid,
  contributor_public_id text,
  role_code text,
  exact_variant_match boolean,
  domain_verified boolean,
  active_assignment_count integer,
  reputation_weight numeric,
  match_score numeric,
  conflict_detected boolean
)
language sql
security definer
set search_path = public
as $$
with task as (
  select t.*
  from public.linguistic_tasks t
  where t.id=p_task_id
),
base as (
  select
    lc.id as contributor_id,
    lc.public_id as contributor_public_id,
    rc.role_code,
    (lcr.variant_id is not distinct from t.target_variant_id) as exact_variant_match,
    case when t.requires_verified_domain then exists (
      select 1
      from public.linguistic_domain_qualifications dq
      where dq.contributor_id=lc.id
        and dq.language_id=t.target_language_id
        and (dq.variant_id is not distinct from t.target_variant_id)
        and dq.context_name=t.context_name
        and dq.verification_status='VERIFIED'
    ) else true end as domain_verified,
    (
      select count(*)::int
      from public.linguistic_task_assignments a
      where a.contributor_id=lc.id
        and a.status = any(array['ASSIGNED','ACCEPTED','SUBMITTED','CHANGES_REQUESTED'])
    ) as active_assignment_count,
    coalesce((
      select avg(rm.weight)
      from public.linguistic_reputation_matrix rm
      where rm.contributor_id=lc.id
        and rm.language_id=t.target_language_id
        and (rm.variant_id is not distinct from t.target_variant_id)
    ),1.00)::numeric as reputation_weight,
    exists (
      select 1
      from public.linguistic_task_assignments prior
      where prior.task_id=t.id
        and prior.contributor_id=lc.id
        and (
          (t.required_role_code = any(array['PEER_REVIEWER','LINGUISTIC_VALIDATOR','CULTURAL_VALIDATOR','UI_QA','FINAL_REVIEWER'])
           and prior.assignment_role = any(array['TRANSLATOR','ORTHOGRAPHY_CORRECTOR','TERMINOLOGY_SPECIALIST','TRANSCRIBER','VOICE_SPEAKER']))
          or
          (t.required_role_code = any(array['TRANSLATOR','ORTHOGRAPHY_CORRECTOR','TERMINOLOGY_SPECIALIST','TRANSCRIBER','VOICE_SPEAKER'])
           and prior.assignment_role = any(array['PEER_REVIEWER','LINGUISTIC_VALIDATOR','CULTURAL_VALIDATOR','UI_QA','FINAL_REVIEWER']))
        )
    ) as conflict_detected,
    lp.max_active_assignments,
    t.*
  from task t
  join public.linguistic_contributor_roles lcr
    on lcr.language_id=t.target_language_id
   and lcr.status='VERIFIED'
  join public.linguistic_role_catalog rc
    on rc.id=lcr.role_id
   and rc.role_code=t.required_role_code
   and rc.is_active=true
  join public.linguistic_contributors lc
    on lc.id=lcr.contributor_id and lc.is_active=true
  join public.linguistic_profiles lp
    on lp.contributor_id=lc.id
   and lp.can_receive_tasks=true
   and lp.availability_status='AVAILABLE'
  where
    (not t.requires_exact_variant or lcr.variant_id is not distinct from t.target_variant_id)
    and (t.target_variant_id is not null or lcr.variant_id is null or not t.requires_exact_variant)
)
select
  b.contributor_id,
  b.contributor_public_id,
  b.role_code,
  b.exact_variant_match,
  b.domain_verified,
  b.active_assignment_count,
  b.reputation_weight,
  (
    100
    + case when b.exact_variant_match then 20 else 0 end
    + case when b.domain_verified then 20 else 0 end
    + least(greatest((b.reputation_weight-1.00)*50, -12.5), 15)
    - (b.active_assignment_count*5)
  )::numeric(8,2) as match_score,
  b.conflict_detected
from base b
where b.domain_verified=true
  and b.conflict_detected=false
  and b.active_assignment_count < b.max_active_assignments
  and not exists (
    select 1 from public.linguistic_task_assignments x
    where x.task_id=p_task_id and x.contributor_id=b.contributor_id and x.assignment_role=b.required_role_code
  )
order by match_score desc, b.active_assignment_count asc, b.contributor_public_id;
$$;

revoke all on function public.tc_linguistic_task_candidates(uuid) from public, anon;
grant execute on function public.tc_linguistic_task_candidates(uuid) to authenticated;

commit;
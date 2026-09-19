begin;

-- Canonical assignment roles. Legacy generic REVIEWER/SPEAKER are replaced before launch.
alter table public.linguistic_task_assignments
  drop constraint if exists linguistic_task_assignments_assignment_role_check;
alter table public.linguistic_task_assignments
  add constraint linguistic_task_assignments_assignment_role_check
  check (assignment_role = any (array[
    'TRANSLATOR','ORTHOGRAPHY_CORRECTOR','PEER_REVIEWER','LINGUISTIC_VALIDATOR',
    'CULTURAL_VALIDATOR','TERMINOLOGY_SPECIALIST','TRANSCRIBER','VOICE_SPEAKER',
    'UI_QA','FINAL_REVIEWER'
  ]::text[]));

create or replace function public.tc_linguistic_role_class(p_role text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_role in ('TRANSLATOR','ORTHOGRAPHY_CORRECTOR','TERMINOLOGY_SPECIALIST','TRANSCRIBER','VOICE_SPEAKER') then 'AUTHORING'
    when p_role in ('PEER_REVIEWER','LINGUISTIC_VALIDATOR','CULTURAL_VALIDATOR','UI_QA','FINAL_REVIEWER') then 'REVIEW'
    else 'UNKNOWN'
  end;
$$;

create unique index if not exists uq_las_one_review_role_per_person_task
on public.linguistic_task_assignments(task_id, contributor_id)
where assignment_role in ('PEER_REVIEWER','LINGUISTIC_VALIDATOR','CULTURAL_VALIDATOR','UI_QA','FINAL_REVIEWER');

create or replace function public.tc_guard_linguistic_assignment_independence()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_language_id uuid;
  v_variant_id uuid;
  v_owner_person_id uuid;
  v_role_class text;
  v_requires_verified boolean;
begin
  select t.target_language_id,t.target_variant_id into v_language_id,v_variant_id
  from public.linguistic_tasks t where t.id=new.task_id;
  if v_language_id is null then raise exception 'LINGUISTIC_TASK_NOT_FOUND'; end if;

  if not exists (
    select 1
    from public.linguistic_role_catalog rc
    join public.linguistic_contributor_roles cr on cr.role_id=rc.id
    where cr.contributor_id=new.contributor_id
      and cr.language_id=v_language_id
      and cr.variant_id is not distinct from v_variant_id
      and cr.status='VERIFIED'
      and (cr.expires_at is null or cr.expires_at>now())
      and rc.role_code=new.assignment_role
      and rc.is_active=true
  ) then raise exception 'VERIFIED_LINGUISTIC_ROLE_REQUIRED'; end if;

  v_role_class := public.tc_linguistic_role_class(new.assignment_role);
  if v_role_class='UNKNOWN' then raise exception 'UNKNOWN_LINGUISTIC_ASSIGNMENT_ROLE'; end if;

  select c.person_id into v_owner_person_id
  from public.linguistic_contributors c where c.id=new.contributor_id;

  if v_role_class='REVIEW' and new.assigned_by_person_id is not null
     and new.assigned_by_person_id=v_owner_person_id then
    raise exception 'SELF_ASSIGN_REVIEW_FORBIDDEN';
  end if;

  if v_role_class='REVIEW' and exists (
    select 1 from public.linguistic_task_assignments a
    where a.task_id=new.task_id and a.contributor_id=new.contributor_id
      and a.id is distinct from new.id
      and public.tc_linguistic_role_class(a.assignment_role)='AUTHORING'
      and a.status not in ('CANCELED','EXPIRED')
  ) then raise exception 'AUTHOR_CANNOT_REVIEW_SAME_TASK'; end if;

  if v_role_class='AUTHORING' and exists (
    select 1 from public.linguistic_task_assignments a
    where a.task_id=new.task_id and a.contributor_id=new.contributor_id
      and a.id is distinct from new.id
      and public.tc_linguistic_role_class(a.assignment_role)='REVIEW'
      and a.status not in ('CANCELED','EXPIRED')
  ) then raise exception 'REVIEWER_CANNOT_AUTHOR_SAME_TASK'; end if;

  if new.assignment_role='FINAL_REVIEWER' and exists (
    select 1 from public.linguistic_task_assignments a
    where a.task_id=new.task_id and a.contributor_id=new.contributor_id
      and a.id is distinct from new.id
      and a.status not in ('CANCELED','EXPIRED')
  ) then raise exception 'FINAL_REVIEWER_MUST_BE_FULLY_INDEPENDENT'; end if;

  return new;
end;
$$;

drop trigger if exists trg_linguistic_assignment_independence on public.linguistic_task_assignments;
create trigger trg_linguistic_assignment_independence
before insert or update of task_id,contributor_id,assignment_role,assigned_by_person_id
on public.linguistic_task_assignments
for each row execute function public.tc_guard_linguistic_assignment_independence();

-- A contributor cannot validate their own qualification/role/domain expertise.
create or replace function public.tc_guard_linguistic_qualification_verification()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_owner uuid;
begin
  if new.verification_status='VERIFIED' then
    select c.person_id into v_owner from public.linguistic_contributors c where c.id=new.contributor_id;
    if new.verified_by_person_id is null then raise exception 'INDEPENDENT_VERIFIER_REQUIRED'; end if;
    if new.verified_by_person_id=v_owner then raise exception 'SELF_QUALIFICATION_VERIFICATION_FORBIDDEN'; end if;
    if new.verified_at is null then new.verified_at:=now(); end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_linguistic_qualification_independent_verifier on public.linguistic_contributor_qualifications;
create trigger trg_linguistic_qualification_independent_verifier
before insert or update of verification_status,verified_by_person_id,verified_at
on public.linguistic_contributor_qualifications
for each row execute function public.tc_guard_linguistic_qualification_verification();

create or replace function public.tc_guard_linguistic_role_verification()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_owner uuid;
  v_requires_verified boolean;
begin
  if new.status='VERIFIED' then
    select c.person_id into v_owner from public.linguistic_contributors c where c.id=new.contributor_id;
    if new.granted_by_person_id is null then raise exception 'INDEPENDENT_ROLE_VERIFIER_REQUIRED'; end if;
    if new.granted_by_person_id=v_owner then raise exception 'SELF_ROLE_VERIFICATION_FORBIDDEN'; end if;
    if new.granted_at is null then new.granted_at:=now(); end if;

    select rc.requires_verified_qualification into v_requires_verified
    from public.linguistic_role_catalog rc where rc.id=new.role_id;
    if coalesce(v_requires_verified,false) and not exists (
      select 1 from public.linguistic_contributor_qualifications q
      where q.contributor_id=new.contributor_id
        and q.language_id=new.language_id
        and q.variant_id is not distinct from new.variant_id
        and q.verification_status='VERIFIED'
    ) then raise exception 'VERIFIED_LANGUAGE_VARIANT_QUALIFICATION_REQUIRED'; end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_linguistic_role_independent_verifier on public.linguistic_contributor_roles;
create trigger trg_linguistic_role_independent_verifier
before insert or update of status,granted_by_person_id,granted_at
on public.linguistic_contributor_roles
for each row execute function public.tc_guard_linguistic_role_verification();

create or replace function public.tc_guard_linguistic_domain_verification()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_owner uuid;
begin
  if new.verification_status='VERIFIED' then
    select c.person_id into v_owner from public.linguistic_contributors c where c.id=new.contributor_id;
    if new.verified_by_person_id is null then raise exception 'INDEPENDENT_DOMAIN_VERIFIER_REQUIRED'; end if;
    if new.verified_by_person_id=v_owner then raise exception 'SELF_DOMAIN_VERIFICATION_FORBIDDEN'; end if;
    if new.verified_at is null then new.verified_at:=now(); end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_linguistic_domain_independent_verifier on public.linguistic_domain_qualifications;
create trigger trg_linguistic_domain_independent_verifier
before insert or update of verification_status,verified_by_person_id,verified_at
on public.linguistic_domain_qualifications
for each row execute function public.tc_guard_linguistic_domain_verification();

-- Once work has been assigned, freeze the linguistic source contract. Create a new task/version instead.
create or replace function public.tc_guard_linguistic_task_source_freeze()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if exists(select 1 from public.linguistic_task_assignments a where a.task_id=old.id)
     and (
       new.job_id is distinct from old.job_id or
       new.source_key is distinct from old.source_key or
       new.ui_key_id is distinct from old.ui_key_id or
       new.concept_id is distinct from old.concept_id or
       new.task_type is distinct from old.task_type or
       new.source_language_tag is distinct from old.source_language_tag or
       new.source_text is distinct from old.source_text or
       new.context_note is distinct from old.context_note or
       new.target_language_id is distinct from old.target_language_id or
       new.target_variant_id is distinct from old.target_variant_id or
       new.sensitivity is distinct from old.sensitivity or
       new.allow_ai_assistance is distinct from old.allow_ai_assistance or
       new.requires_ai_disclosure is distinct from old.requires_ai_disclosure or
       new.requires_source_citation is distinct from old.requires_source_citation or
       new.requires_audio is distinct from old.requires_audio
     ) then
    raise exception 'LINGUISTIC_TASK_SOURCE_LOCKED_AFTER_ASSIGNMENT';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_linguistic_task_source_freeze on public.linguistic_tasks;
create trigger trg_linguistic_task_source_freeze
before update on public.linguistic_tasks
for each row execute function public.tc_guard_linguistic_task_source_freeze();

-- Only authoring roles may submit new linguistic content. Validators review; they do not rewrite and then grade it.
create or replace function public.tc_guard_linguistic_submission_author_role()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_role text;
begin
  select a.assignment_role into v_role
  from public.linguistic_task_assignments a where a.id=new.assignment_id;
  if public.tc_linguistic_role_class(v_role) <> 'AUTHORING' then
    raise exception 'REVIEW_ROLE_CANNOT_SUBMIT_AUTHORING_CONTENT';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_linguistic_submission_author_role on public.linguistic_task_submissions;
create trigger trg_linguistic_submission_author_role
before insert on public.linguistic_task_submissions
for each row execute function public.tc_guard_linguistic_submission_author_role();

-- Translation proposal content is immutable. Corrections are new proposals/versions, never silent edits.
create or replace function public.tc_guard_translation_proposal_material_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.concept_id is distinct from old.concept_id
     or new.language_id is distinct from old.language_id
     or new.variant_id is distinct from old.variant_id
     or new.orthography_version_id is distinct from old.orthography_version_id
     or new.texto_original is distinct from old.texto_original
     or new.texto_clean_input is distinct from old.texto_clean_input
     or new.texto_normalized_unicode is distinct from old.texto_normalized_unicode
     or new.texto_search_folded is distinct from old.texto_search_folded
     or new.normalization_transformations is distinct from old.normalization_transformations
     or new.created_by_person_id is distinct from old.created_by_person_id then
    raise exception 'TRANSLATION_PROPOSAL_MATERIAL_IMMUTABLE_CREATE_NEW_VERSION';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_translation_proposal_material_immutable on public.translation_proposals;
create trigger trg_translation_proposal_material_immutable
before update on public.translation_proposals
for each row execute function public.tc_guard_translation_proposal_material_immutable();

-- Strengthen legacy translation/audio review guard beyond direct owner self-review.
create or replace function public.tc_guard_review_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_owner uuid;
  v_reviewer_contributor uuid;
begin
  select c.id into v_reviewer_contributor
  from public.linguistic_contributors c where c.person_id=new.reviewer_person_id;

  if new.translation_id is not null then
    select t.created_by_person_id into v_owner from public.translation_proposals t where t.id=new.translation_id;
    if v_owner is not null and v_owner=new.reviewer_person_id then raise exception 'SELF_REVIEW_FORBIDDEN'; end if;

    if v_reviewer_contributor is not null and exists (
      select 1
      from public.linguistic_task_submissions s
      join public.linguistic_task_assignments own_a on own_a.id=s.assignment_id
      join public.linguistic_task_assignments any_a on any_a.task_id=own_a.task_id
      where s.translation_proposal_id=new.translation_id
        and any_a.contributor_id=v_reviewer_contributor
        and public.tc_linguistic_role_class(any_a.assignment_role)='AUTHORING'
        and any_a.status not in ('CANCELED','EXPIRED')
    ) then raise exception 'PARTICIPANT_REVIEW_FORBIDDEN'; end if;
  else
    select a.speaker_person_id into v_owner from public.linguistic_audios a where a.id=new.audio_id;
    if v_owner is not null and v_owner=new.reviewer_person_id then raise exception 'SELF_REVIEW_FORBIDDEN'; end if;
  end if;
  return new;
end;
$$;

create unique index if not exists uq_linguistic_review_active_translation_person
on public.linguistic_reviews(translation_id,reviewer_person_id)
where translation_id is not null and is_withdrawn=false;
create unique index if not exists uq_linguistic_review_active_audio_person
on public.linguistic_reviews(audio_id,reviewer_person_id)
where audio_id is not null and is_withdrawn=false;

create or replace function public.tc_review_history_append()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_person uuid;
begin
  select p.id into v_person from public.persons p where p.auth_user_id=auth.uid();
  insert into public.linguistic_reviews_history(review_id,version,verdict,observation,is_withdrawn,changed_by)
  values(new.id,new.version,new.verdict,new.observation,new.is_withdrawn,v_person);
  return new;
end;
$$;

commit;
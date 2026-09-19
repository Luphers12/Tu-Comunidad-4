begin;

-- Every corrected/derived submission can point to the exact source submission it modifies.
alter table public.linguistic_task_submissions
  add column if not exists parent_submission_id uuid null references public.linguistic_task_submissions(id) on delete restrict;

alter table public.linguistic_task_submissions
  add constraint linguistic_task_submissions_not_own_parent
  check (parent_submission_id is null or parent_submission_id <> id);

create index if not exists idx_linguistic_submissions_parent
on public.linguistic_task_submissions(parent_submission_id)
where parent_submission_id is not null;

create or replace function public.tc_guard_linguistic_submission_parent()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_child_task uuid;
  v_parent_task uuid;
  v_child_contributor uuid;
  v_parent_contributor uuid;
  v_role text;
begin
  select a.task_id,a.contributor_id,a.assignment_role
    into v_child_task,v_child_contributor,v_role
  from public.linguistic_task_assignments a where a.id=new.assignment_id;

  if v_role='ORTHOGRAPHY_CORRECTOR' and new.parent_submission_id is null then
    raise exception 'CORRECTION_MUST_REFERENCE_PARENT_SUBMISSION';
  end if;

  if new.parent_submission_id is not null then
    select pa.task_id,pa.contributor_id into v_parent_task,v_parent_contributor
    from public.linguistic_task_submissions ps
    join public.linguistic_task_assignments pa on pa.id=ps.assignment_id
    where ps.id=new.parent_submission_id;
    if v_parent_task is null then raise exception 'PARENT_SUBMISSION_NOT_FOUND'; end if;
    if v_parent_task is distinct from v_child_task then raise exception 'PARENT_SUBMISSION_TASK_MISMATCH'; end if;
    if v_role='ORTHOGRAPHY_CORRECTOR' and v_parent_contributor=v_child_contributor then
      raise exception 'INDEPENDENT_CORRECTOR_REQUIRED';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_linguistic_submission_parent on public.linguistic_task_submissions;
create trigger trg_linguistic_submission_parent
before insert or update of assignment_id,parent_submission_id
on public.linguistic_task_submissions
for each row execute function public.tc_guard_linguistic_submission_parent();

-- Fix append-only guard: linkage fields are also material and may not be attached/changed later.
create or replace function public.tc_linguistic_submission_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op='DELETE' then
    raise exception 'Linguistic submissions are append-only; deletion is not allowed';
  end if;
  if new.assignment_id is distinct from old.assignment_id
     or new.version is distinct from old.version
     or new.parent_submission_id is distinct from old.parent_submission_id
     or new.submitted_text is distinct from old.submitted_text
     or new.translation_proposal_id is distinct from old.translation_proposal_id
     or new.audio_id is distinct from old.audio_id
     or new.variant_usage_note is distinct from old.variant_usage_note
     or new.ai_assistance_disclosed is distinct from old.ai_assistance_disclosed
     or new.ai_assistance_details is distinct from old.ai_assistance_details
     or new.sources_consulted is distinct from old.sources_consulted
     or new.contributor_note is distinct from old.contributor_note
     or new.submitted_at is distinct from old.submitted_at then
    raise exception 'Submitted linguistic content is immutable; create a new submission version';
  end if;
  return new;
end;
$$;

-- Review requirements are explicit and context-sensitive.
create table if not exists public.linguistic_review_policies (
  context_name text primary key references public.linguistic_context_policies(context_name) on delete restrict,
  min_independent_reviewers integer not null check (min_independent_reviewers>=1),
  required_role_codes text[] not null default '{}'::text[],
  required_domain_level text null check (required_domain_level is null or required_domain_level in ('GENERAL','SPECIALIZED','EXPERT')),
  block_ai_assisted_approval boolean not null default false,
  requires_publication_authorization boolean not null default true,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.linguistic_review_policies(context_name,min_independent_reviewers,required_role_codes,required_domain_level,block_ai_assisted_approval)
values
 ('NORMAL_UI',2,array['LINGUISTIC_VALIDATOR','UI_QA'],null,false),
 ('MARKETPLACE',2,array['LINGUISTIC_VALIDATOR','UI_QA'],null,false),
 ('IDENTITY',3,array['LINGUISTIC_VALIDATOR','UI_QA','FINAL_REVIEWER'],'SPECIALIZED',true),
 ('PAYMENT',4,array['LINGUISTIC_VALIDATOR','PEER_REVIEWER','UI_QA','FINAL_REVIEWER'],'SPECIALIZED',true),
 ('LEGAL',4,array['LINGUISTIC_VALIDATOR','PEER_REVIEWER','UI_QA','FINAL_REVIEWER'],'EXPERT',true),
 ('SAFETY',4,array['LINGUISTIC_VALIDATOR','CULTURAL_VALIDATOR','UI_QA','FINAL_REVIEWER'],'SPECIALIZED',true),
 ('COMPLIANCE',4,array['LINGUISTIC_VALIDATOR','PEER_REVIEWER','UI_QA','FINAL_REVIEWER'],'EXPERT',true)
on conflict(context_name) do update set
 min_independent_reviewers=excluded.min_independent_reviewers,
 required_role_codes=excluded.required_role_codes,
 required_domain_level=excluded.required_domain_level,
 block_ai_assisted_approval=excluded.block_ai_assisted_approval,
 updated_at=now();

alter table public.linguistic_review_policies enable row level security;
revoke all on public.linguistic_review_policies from anon,authenticated;

create or replace function public.tc_linguistic_effective_task_context(p_task_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
 select case
   when t.sensitivity='CHILD' then 'SAFETY'
   when t.sensitivity in ('IDENTITY','PAYMENT','LEGAL','SAFETY') then t.sensitivity
   else coalesce(k.context_name,'NORMAL_UI')
 end
 from public.linguistic_tasks t
 left join public.ui_interface_keys k on k.id=t.ui_key_id
 where t.id=p_task_id;
$$;

create sequence if not exists public.lsrv_seq;
create table if not exists public.linguistic_submission_reviews (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default ('LSRV-' || lpad(nextval('public.lsrv_seq')::text,5,'0')),
  submission_id uuid not null references public.linguistic_task_submissions(id) on delete restrict,
  reviewer_contributor_id uuid not null references public.linguistic_contributors(id) on delete restrict,
  review_role_code text not null references public.linguistic_role_catalog(role_code) on delete restrict,
  context_name text not null references public.linguistic_context_policies(context_name) on delete restrict,
  verdict text not null check (verdict in ('APPROVE','APPROVE_VARIANT','CHANGES_REQUIRED','NEEDS_CONTEXT','CONFLICT','REJECT')),
  observation text null,
  independent_attested boolean not null default false,
  conflict_of_interest_declared boolean not null default false,
  conflict_note text null,
  domain_qualification_id uuid null references public.linguistic_domain_qualifications(id) on delete restrict,
  is_withdrawn boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(submission_id, reviewer_contributor_id)
);

alter table public.linguistic_submission_reviews enable row level security;
revoke all on public.linguistic_submission_reviews from anon,authenticated;
create index if not exists idx_linguistic_submission_reviews_submission on public.linguistic_submission_reviews(submission_id,is_withdrawn,verdict);

create or replace function public.tc_domain_level_rank(p_level text)
returns integer
language sql
immutable
set search_path = ''
as $$
 select case p_level when 'GENERAL' then 1 when 'SPECIALIZED' then 2 when 'EXPERT' then 3 else 0 end;
$$;

create or replace function public.tc_guard_linguistic_submission_review_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_task_id uuid;
  v_language_id uuid;
  v_variant_id uuid;
  v_author_contributor uuid;
  v_context text;
  v_policy public.linguistic_review_policies%rowtype;
  v_domain_id uuid;
  v_required_count integer;
  v_approved_count integer;
  v_negative_count integer;
  v_missing_nonfinal integer;
begin
  if not new.independent_attested then raise exception 'INDEPENDENCE_ATTESTATION_REQUIRED'; end if;
  if new.conflict_of_interest_declared then raise exception 'REVIEWER_MUST_ABSTAIN_ON_CONFLICT'; end if;
  if new.review_role_code not in ('PEER_REVIEWER','LINGUISTIC_VALIDATOR','CULTURAL_VALIDATOR','UI_QA','FINAL_REVIEWER') then
    raise exception 'INVALID_REVIEW_ROLE';
  end if;

  select a.task_id,a.contributor_id,t.target_language_id,t.target_variant_id
    into v_task_id,v_author_contributor,v_language_id,v_variant_id
  from public.linguistic_task_submissions s
  join public.linguistic_task_assignments a on a.id=s.assignment_id
  join public.linguistic_tasks t on t.id=a.task_id
  where s.id=new.submission_id;
  if v_task_id is null then raise exception 'SUBMISSION_NOT_FOUND'; end if;

  -- Reviews only apply to the newest version of that assignment.
  if exists(
    select 1 from public.linguistic_task_submissions s0
    join public.linguistic_task_submissions s1 on s1.assignment_id=s0.assignment_id and s1.version>s0.version
    where s0.id=new.submission_id
  ) then raise exception 'STALE_SUBMISSION_REVIEW_FORBIDDEN'; end if;

  if new.reviewer_contributor_id=v_author_contributor then raise exception 'SELF_REVIEW_FORBIDDEN'; end if;

  -- Any material participant on this task is excluded from grading it.
  if exists(
    select 1 from public.linguistic_task_assignments a
    where a.task_id=v_task_id and a.contributor_id=new.reviewer_contributor_id
      and public.tc_linguistic_role_class(a.assignment_role)='AUTHORING'
      and a.status not in ('CANCELED','EXPIRED')
  ) then raise exception 'PARTICIPANT_REVIEW_FORBIDDEN'; end if;

  if not exists(
    select 1
    from public.linguistic_role_catalog rc
    join public.linguistic_contributor_roles cr on cr.role_id=rc.id
    where cr.contributor_id=new.reviewer_contributor_id
      and cr.language_id=v_language_id
      and cr.variant_id is not distinct from v_variant_id
      and cr.status='VERIFIED'
      and (cr.expires_at is null or cr.expires_at>now())
      and rc.role_code=new.review_role_code
      and rc.is_active=true
  ) then raise exception 'VERIFIED_REVIEW_ROLE_REQUIRED'; end if;

  v_context:=public.tc_linguistic_effective_task_context(v_task_id);
  new.context_name:=v_context;
  select * into v_policy from public.linguistic_review_policies p where p.context_name=v_context and p.is_active=true;
  if v_policy.context_name is null then raise exception 'REVIEW_POLICY_NOT_FOUND'; end if;

  -- Attach a verified domain qualification when available.
  select dq.id into v_domain_id
  from public.linguistic_domain_qualifications dq
  where dq.contributor_id=new.reviewer_contributor_id
    and dq.language_id=v_language_id
    and dq.variant_id is not distinct from v_variant_id
    and dq.context_name=v_context
    and dq.verification_status='VERIFIED'
  order by public.tc_domain_level_rank(dq.qualification_level) desc
  limit 1;
  new.domain_qualification_id:=v_domain_id;

  -- Final reviewer is an independent last gate, not another author/editor.
  if new.review_role_code='FINAL_REVIEWER' then
    select greatest(t.required_review_count,v_policy.min_independent_reviewers)
      into v_required_count from public.linguistic_tasks t where t.id=v_task_id;

    select count(distinct r.reviewer_contributor_id),
           count(*) filter(where r.verdict not in ('APPROVE','APPROVE_VARIANT'))
      into v_approved_count,v_negative_count
    from public.linguistic_submission_reviews r
    where r.submission_id=new.submission_id and not r.is_withdrawn;

    if v_negative_count>0 then raise exception 'FINAL_REVIEW_BLOCKED_BY_UNRESOLVED_REVIEW'; end if;
    if v_approved_count < v_required_count-1 then raise exception 'FINAL_REVIEW_PRECONDITIONS_NOT_MET'; end if;

    select count(*) into v_missing_nonfinal
    from unnest(v_policy.required_role_codes) rr(role_code)
    where rr.role_code<>'FINAL_REVIEWER'
      and not exists(
        select 1 from public.linguistic_submission_reviews r
        where r.submission_id=new.submission_id and not r.is_withdrawn
          and r.verdict in ('APPROVE','APPROVE_VARIANT') and r.review_role_code=rr.role_code
      );
    if v_missing_nonfinal>0 then raise exception 'FINAL_REVIEW_REQUIRED_ROLES_INCOMPLETE'; end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_linguistic_submission_review_insert_guard on public.linguistic_submission_reviews;
create trigger trg_linguistic_submission_review_insert_guard
before insert on public.linguistic_submission_reviews
for each row execute function public.tc_guard_linguistic_submission_review_insert();

create or replace function public.tc_guard_linguistic_submission_review_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.submission_id is distinct from old.submission_id
     or new.reviewer_contributor_id is distinct from old.reviewer_contributor_id
     or new.review_role_code is distinct from old.review_role_code
     or new.context_name is distinct from old.context_name
     or new.verdict is distinct from old.verdict
     or new.observation is distinct from old.observation
     or new.independent_attested is distinct from old.independent_attested
     or new.conflict_of_interest_declared is distinct from old.conflict_of_interest_declared
     or new.conflict_note is distinct from old.conflict_note
     or new.domain_qualification_id is distinct from old.domain_qualification_id
     or new.created_at is distinct from old.created_at then
    raise exception 'LINGUISTIC_REVIEW_IMMUTABLE_WITHDRAW_OR_CREATE_NEW_REVIEW';
  end if;
  if old.is_withdrawn and not new.is_withdrawn then raise exception 'WITHDRAWN_REVIEW_CANNOT_BE_REACTIVATED'; end if;
  new.updated_at:=now();
  return new;
end;
$$;

drop trigger if exists trg_linguistic_submission_review_update_guard on public.linguistic_submission_reviews;
create trigger trg_linguistic_submission_review_update_guard
before update on public.linguistic_submission_reviews
for each row execute function public.tc_guard_linguistic_submission_review_update();

create or replace function public.tc_block_linguistic_submission_review_delete()
returns trigger
language plpgsql
set search_path = ''
as $$ begin raise exception 'LINGUISTIC_REVIEW_DELETE_FORBIDDEN'; end; $$;
drop trigger if exists trg_linguistic_submission_review_delete_block on public.linguistic_submission_reviews;
create trigger trg_linguistic_submission_review_delete_block
before delete on public.linguistic_submission_reviews
for each row execute function public.tc_block_linguistic_submission_review_delete();

-- Release readiness checks independent humans, required roles, domain expertise, AI restrictions and rights from every material ancestor.
create or replace function public.tc_linguistic_submission_readiness(p_submission_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path = ''
as $$
declare
  v_task_id uuid;
  v_context text;
  v_policy public.linguistic_review_policies%rowtype;
  v_required integer;
  v_approved integer;
  v_negative integer;
  v_missing_roles text[];
  v_domain_ok boolean;
  v_ai_ok boolean;
  v_auth_ok boolean;
  v_final_ok boolean;
begin
  select a.task_id into v_task_id
  from public.linguistic_task_submissions s join public.linguistic_task_assignments a on a.id=s.assignment_id
  where s.id=p_submission_id;
  if v_task_id is null then return jsonb_build_object('ready',false,'error','SUBMISSION_NOT_FOUND'); end if;

  v_context:=public.tc_linguistic_effective_task_context(v_task_id);
  select * into v_policy from public.linguistic_review_policies where context_name=v_context and is_active=true;
  select greatest(t.required_review_count,v_policy.min_independent_reviewers) into v_required
  from public.linguistic_tasks t where t.id=v_task_id;

  select count(distinct r.reviewer_contributor_id),
         count(*) filter(where r.verdict not in ('APPROVE','APPROVE_VARIANT'))
    into v_approved,v_negative
  from public.linguistic_submission_reviews r
  where r.submission_id=p_submission_id and not r.is_withdrawn
    and (r.verdict in ('APPROVE','APPROVE_VARIANT') or r.verdict not in ('APPROVE','APPROVE_VARIANT'));

  select coalesce(array_agg(req.role_code order by req.role_code),'{}'::text[])
    into v_missing_roles
  from unnest(v_policy.required_role_codes) req(role_code)
  where not exists(
    select 1 from public.linguistic_submission_reviews r
    where r.submission_id=p_submission_id and not r.is_withdrawn
      and r.verdict in ('APPROVE','APPROVE_VARIANT') and r.review_role_code=req.role_code
  );

  v_final_ok := not ('FINAL_REVIEWER'=any(v_policy.required_role_codes)) or exists(
    select 1 from public.linguistic_submission_reviews r
    where r.submission_id=p_submission_id and not r.is_withdrawn
      and r.review_role_code='FINAL_REVIEWER' and r.verdict in ('APPROVE','APPROVE_VARIANT')
  );

  if v_policy.required_domain_level is null then v_domain_ok:=true;
  else
    select exists(
      select 1 from public.linguistic_submission_reviews r
      join public.linguistic_domain_qualifications dq on dq.id=r.domain_qualification_id
      where r.submission_id=p_submission_id and not r.is_withdrawn
        and r.verdict in ('APPROVE','APPROVE_VARIANT')
        and dq.verification_status='VERIFIED'
        and public.tc_domain_level_rank(dq.qualification_level)>=public.tc_domain_level_rank(v_policy.required_domain_level)
    ) into v_domain_ok;
  end if;

  select not (v_policy.block_ai_assisted_approval and s.ai_assistance_disclosed)
    into v_ai_ok from public.linguistic_task_submissions s where s.id=p_submission_id;

  with recursive material_submissions(id,parent_submission_id) as (
    select s.id,s.parent_submission_id from public.linguistic_task_submissions s where s.id=p_submission_id
    union all
    select p.id,p.parent_submission_id
    from public.linguistic_task_submissions p
    join material_submissions m on p.id=m.parent_submission_id
  ), auth_state as (
    select m.id,
      (select (a.status='GRANTED' and a.app_ui_publication_allowed
               and (a.expires_at is null or a.expires_at>now()))
       from public.linguistic_contribution_authorizations a
       where a.submission_id=m.id
       order by a.authorization_version desc limit 1) as allowed
    from material_submissions m
  )
  select coalesce(bool_and(coalesce(allowed,false)),false) into v_auth_ok from auth_state;

  return jsonb_build_object(
    'ready',(v_approved>=v_required and v_negative=0 and cardinality(v_missing_roles)=0 and v_domain_ok and v_ai_ok and v_auth_ok and v_final_ok),
    'context',v_context,
    'required_independent_reviewers',v_required,
    'approved_independent_reviewers',v_approved,
    'unresolved_reviews',v_negative,
    'missing_roles',v_missing_roles,
    'domain_requirement_met',v_domain_ok,
    'ai_requirement_met',v_ai_ok,
    'publication_authorizations_complete',v_auth_ok,
    'final_review_complete',v_final_ok
  );
end;
$$;

create or replace function public.tc_submit_linguistic_submission_review(
  p_submission_public_id text,
  p_review_role_code text,
  p_verdict text,
  p_observation text default null,
  p_independent_attested boolean default false,
  p_conflict_of_interest_declared boolean default false,
  p_conflict_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_person uuid;
  v_contributor uuid;
  v_submission uuid;
  v_review_id uuid;
  v_public_id text;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.tc_is_feature_enabled('linguistics.work_program') then raise exception 'LINGUISTICS_WORK_PROGRAM_DISABLED'; end if;
  if p_verdict not in ('APPROVE','APPROVE_VARIANT','CHANGES_REQUIRED','NEEDS_CONTEXT','CONFLICT','REJECT') then raise exception 'INVALID_REVIEW_VERDICT'; end if;

  select p.id,c.id into v_person,v_contributor
  from public.persons p join public.linguistic_contributors c on c.person_id=p.id and c.is_active=true
  where p.auth_user_id=auth.uid();
  if v_contributor is null then raise exception 'LINGUISTIC_CONTRIBUTOR_REQUIRED'; end if;

  select s.id into v_submission from public.linguistic_task_submissions s where s.public_id=p_submission_public_id;
  if v_submission is null then raise exception 'SUBMISSION_NOT_FOUND'; end if;

  insert into public.linguistic_submission_reviews(
    submission_id,reviewer_contributor_id,review_role_code,context_name,verdict,observation,
    independent_attested,conflict_of_interest_declared,conflict_note
  ) values (
    v_submission,v_contributor,p_review_role_code,'NORMAL_UI',p_verdict,nullif(btrim(coalesce(p_observation,'')),''),
    p_independent_attested,p_conflict_of_interest_declared,nullif(btrim(coalesce(p_conflict_note,'')),'')
  ) returning id,public_id into v_review_id,v_public_id;

  insert into public.linguistic_work_events(entity_type,entity_id,event_type,actor_person_id,payload)
  values('SUBMISSION_REVIEW',v_review_id,'REVIEW_SUBMITTED',v_person,jsonb_build_object('submission_public_id',p_submission_public_id,'role',p_review_role_code,'verdict',p_verdict));

  return jsonb_build_object('success',true,'review_public_id',v_public_id,'readiness',public.tc_linguistic_submission_readiness(v_submission));
end;
$$;

create or replace function public.tc_withdraw_my_linguistic_submission_review(p_review_public_id text,p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_person uuid;
  v_contributor uuid;
  v_review uuid;
  v_submission uuid;
begin
  select p.id,c.id into v_person,v_contributor
  from public.persons p join public.linguistic_contributors c on c.person_id=p.id
  where p.auth_user_id=auth.uid();
  if v_contributor is null then raise exception 'LINGUISTIC_CONTRIBUTOR_REQUIRED'; end if;

  select r.id,r.submission_id into v_review,v_submission
  from public.linguistic_submission_reviews r
  where r.public_id=p_review_public_id and r.reviewer_contributor_id=v_contributor
  for update;
  if v_review is null then raise exception 'REVIEW_NOT_FOUND'; end if;

  update public.linguistic_submission_reviews set is_withdrawn=true where id=v_review and not is_withdrawn;
  insert into public.linguistic_work_events(entity_type,entity_id,event_type,actor_person_id,payload)
  values('SUBMISSION_REVIEW',v_review,'REVIEW_WITHDRAWN',v_person,jsonb_build_object('reason',p_reason));
  return jsonb_build_object('success',true,'review_public_id',p_review_public_id,'readiness',public.tc_linguistic_submission_readiness(v_submission));
end;
$$;

create or replace function public.tc_get_linguistic_submission_readiness(p_submission_public_id text)
returns jsonb
language plpgsql
stable security definer
set search_path = ''
as $$
declare
  v_contributor uuid;
  v_submission uuid;
  v_task uuid;
begin
  select c.id into v_contributor
  from public.persons p join public.linguistic_contributors c on c.person_id=p.id
  where p.auth_user_id=auth.uid();
  if v_contributor is null then raise exception 'LINGUISTIC_CONTRIBUTOR_REQUIRED'; end if;

  select s.id,a.task_id into v_submission,v_task
  from public.linguistic_task_submissions s join public.linguistic_task_assignments a on a.id=s.assignment_id
  where s.public_id=p_submission_public_id;
  if v_submission is null then raise exception 'SUBMISSION_NOT_FOUND'; end if;
  if not exists(select 1 from public.linguistic_task_assignments a where a.task_id=v_task and a.contributor_id=v_contributor) then
    raise exception 'NOT_AUTHORIZED_FOR_TASK';
  end if;
  return public.tc_linguistic_submission_readiness(v_submission);
end;
$$;

-- Independent corrections keep an explicit lineage to the original submission.
create or replace function public.tc_submit_linguistic_correction(
  p_assignment_public_id text,
  p_parent_submission_public_id text,
  p_corrected_text text,
  p_variant_usage_note text default null,
  p_sources_consulted jsonb default '[]'::jsonb,
  p_contributor_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_person uuid;
  v_contributor uuid;
  v_assignment uuid;
  v_task uuid;
  v_status text;
  v_role text;
  v_parent uuid;
  v_version integer;
  v_submission uuid;
  v_submission_public text;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.tc_is_feature_enabled('linguistics.work_program') then raise exception 'LINGUISTICS_WORK_PROGRAM_DISABLED'; end if;
  if p_corrected_text is null or btrim(p_corrected_text)='' then raise exception 'CORRECTED_TEXT_REQUIRED'; end if;
  if jsonb_typeof(coalesce(p_sources_consulted,'[]'::jsonb))<>'array' then raise exception 'sources_consulted must be a JSON array'; end if;

  select p.id,c.id into v_person,v_contributor
  from public.persons p join public.linguistic_contributors c on c.person_id=p.id
  where p.auth_user_id=auth.uid();

  select a.id,a.task_id,a.status,a.assignment_role into v_assignment,v_task,v_status,v_role
  from public.linguistic_task_assignments a
  where a.public_id=p_assignment_public_id and a.contributor_id=v_contributor
  for update;
  if v_assignment is null then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
  if v_role not in ('ORTHOGRAPHY_CORRECTOR','TERMINOLOGY_SPECIALIST') then raise exception 'CORRECTION_ROLE_REQUIRED'; end if;
  if v_status not in ('ACCEPTED','CHANGES_REQUESTED') then raise exception 'ASSIGNMENT_NOT_READY'; end if;

  select s.id into v_parent
  from public.linguistic_task_submissions s
  join public.linguistic_task_assignments a on a.id=s.assignment_id
  where s.public_id=p_parent_submission_public_id and a.task_id=v_task;
  if v_parent is null then raise exception 'PARENT_SUBMISSION_NOT_FOUND_FOR_TASK'; end if;

  select coalesce(max(version),0)+1 into v_version from public.linguistic_task_submissions where assignment_id=v_assignment;
  insert into public.linguistic_task_submissions(
    assignment_id,version,parent_submission_id,submitted_text,variant_usage_note,sources_consulted,contributor_note,status
  ) values(
    v_assignment,v_version,v_parent,btrim(p_corrected_text),nullif(btrim(coalesce(p_variant_usage_note,'')),''),
    coalesce(p_sources_consulted,'[]'::jsonb),nullif(btrim(coalesce(p_contributor_note,'')),''),'SUBMITTED'
  ) returning id,public_id into v_submission,v_submission_public;

  insert into public.linguistic_contribution_authorizations(
    submission_id,contributor_id,authorization_version,status,internal_review_allowed,
    app_ui_publication_allowed,derivative_formatting_allowed,commercial_use_allowed,public_attribution_allowed,
    marketing_allowed,research_sharing_allowed,third_party_sharing_allowed,ai_training_allowed,voice_modeling_allowed,
    public_audio_allowed,cultural_archive_allowed,archive_access_level,attribution_preference,license_type,geographic_scope
  ) values(
    v_submission,v_contributor,1,'GRANTED',true,false,false,false,false,false,false,false,false,false,false,false,
    'DO_NOT_ARCHIVE','ANONYMOUS','INTERNAL_REVIEW_ONLY','TU_COMUNIDAD_INTERNAL_REVIEW'
  );

  update public.linguistic_task_assignments set status='SUBMITTED',completed_at=now(),updated_at=now() where id=v_assignment;
  update public.linguistic_tasks set status='IN_REVIEW',updated_at=now() where id=v_task and status in ('OPEN','ASSIGNED','READY');
  insert into public.linguistic_work_events(entity_type,entity_id,event_type,actor_person_id,payload)
  values('SUBMISSION',v_submission,'CORRECTION_SUBMITTED',v_person,jsonb_build_object('parent_submission_public_id',p_parent_submission_public_id,'version',v_version));

  return jsonb_build_object('success',true,'submission_public_id',v_submission_public,'version',v_version,'parent_submission_public_id',p_parent_submission_public_id);
end;
$$;

revoke all on function public.tc_submit_linguistic_submission_review(text,text,text,text,boolean,boolean,text) from public,anon;
grant execute on function public.tc_submit_linguistic_submission_review(text,text,text,text,boolean,boolean,text) to authenticated;
revoke all on function public.tc_withdraw_my_linguistic_submission_review(text,text) from public,anon;
grant execute on function public.tc_withdraw_my_linguistic_submission_review(text,text) to authenticated;
revoke all on function public.tc_get_linguistic_submission_readiness(text) from public,anon;
grant execute on function public.tc_get_linguistic_submission_readiness(text) to authenticated;
revoke all on function public.tc_submit_linguistic_correction(text,text,text,text,jsonb,text) from public,anon;
grant execute on function public.tc_submit_linguistic_correction(text,text,text,text,jsonb,text) to authenticated;
revoke all on function public.tc_linguistic_submission_readiness(uuid) from public,anon,authenticated;

commit;
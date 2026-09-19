begin;

insert into public.tc_feature_gates(
  feature_key,domain,display_name,source_status,backend_status,safety_status,legal_status,cultural_status,approval_status,is_enabled,notes
)
values(
  'linguistics.submission_approval','LINGUISTICS','Aprobación final de entregas lingüísticas',
  'NOT_REQUIRED','VERIFIED','PENDING','PENDING','PENDING','PENDING',false,
  'Cierre humano final de una entrega lingüística. No publica contenido por sí mismo.'
)
on conflict (feature_key) do update set
  display_name=excluded.display_name,
  backend_status='VERIFIED',
  is_enabled=false,
  notes=excluded.notes,
  updated_at=now();

create table if not exists public.linguistic_submission_approval_decisions(
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('LAPR'),
  submission_id uuid not null unique references public.linguistic_task_submissions(id) on delete restrict,
  decided_by_contributor_id uuid not null references public.linguistic_contributors(id) on delete restrict,
  finalization_role_code text not null references public.linguistic_role_catalog(role_code) on delete restrict,
  decision text not null check (decision in ('APPROVED')),
  readiness_snapshot jsonb not null default '{}'::jsonb,
  rationale text,
  created_at timestamptz not null default now()
);

alter table public.linguistic_submission_approval_decisions enable row level security;
revoke all on public.linguistic_submission_approval_decisions from anon, authenticated;

create or replace function public.tc_linguistic_submission_approval_readiness(p_submission_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  v_task_id uuid;
  v_assignment_id uuid;
  v_author_contributor uuid;
  v_language_id uuid;
  v_variant_id uuid;
  v_context text;
  v_submission_status text;
  v_version integer;
  v_latest_version integer;
  v_policy public.linguistic_review_policies%rowtype;
  v_required integer;
  v_approved integer;
  v_negative integer;
  v_missing_roles text[];
  v_domain_ok boolean;
  v_ai_ok boolean;
  v_latest_ok boolean;
begin
  select a.task_id,a.id,a.contributor_id,t.target_language_id,t.target_variant_id,s.status,s.version
    into v_task_id,v_assignment_id,v_author_contributor,v_language_id,v_variant_id,v_submission_status,v_version
  from public.linguistic_task_submissions s
  join public.linguistic_task_assignments a on a.id=s.assignment_id
  join public.linguistic_tasks t on t.id=a.task_id
  where s.id=p_submission_id;

  if v_task_id is null then
    return jsonb_build_object('approval_ready',false,'error','SUBMISSION_NOT_FOUND');
  end if;

  select max(s.version) into v_latest_version
  from public.linguistic_task_submissions s
  where s.assignment_id=v_assignment_id;
  v_latest_ok := (v_version=v_latest_version);

  v_context:=public.tc_linguistic_effective_task_context(v_task_id);
  select * into v_policy
  from public.linguistic_review_policies
  where context_name=v_context and is_active=true;

  if v_policy.context_name is null then
    return jsonb_build_object('approval_ready',false,'error','ACTIVE_REVIEW_POLICY_NOT_FOUND','context',v_context);
  end if;

  select greatest(t.required_review_count,v_policy.min_independent_reviewers)
    into v_required
  from public.linguistic_tasks t where t.id=v_task_id;

  with valid_positive as (
    select r.*
    from public.linguistic_submission_reviews r
    join public.linguistic_role_catalog rc
      on rc.role_code=r.review_role_code and rc.is_active
    join public.linguistic_contributor_roles cr
      on cr.role_id=rc.id
     and cr.contributor_id=r.reviewer_contributor_id
     and cr.language_id=v_language_id
     and cr.variant_id is not distinct from v_variant_id
     and cr.status='VERIFIED'
     and (cr.expires_at is null or cr.expires_at>now())
    where r.submission_id=p_submission_id
      and not r.is_withdrawn
      and r.verdict in ('APPROVE','APPROVE_VARIANT')
      and r.independent_attested=true
      and r.conflict_of_interest_declared=false
      and r.context_name=v_context
      and r.reviewer_contributor_id<>v_author_contributor
  )
  select count(distinct reviewer_contributor_id)
    into v_approved
  from valid_positive;

  select count(*) into v_negative
  from public.linguistic_submission_reviews r
  where r.submission_id=p_submission_id
    and not r.is_withdrawn
    and (
      r.verdict not in ('APPROVE','APPROVE_VARIANT')
      or r.independent_attested=false
      or r.conflict_of_interest_declared=true
      or r.context_name<>v_context
    );

  with valid_positive as (
    select r.*
    from public.linguistic_submission_reviews r
    join public.linguistic_role_catalog rc
      on rc.role_code=r.review_role_code and rc.is_active
    join public.linguistic_contributor_roles cr
      on cr.role_id=rc.id
     and cr.contributor_id=r.reviewer_contributor_id
     and cr.language_id=v_language_id
     and cr.variant_id is not distinct from v_variant_id
     and cr.status='VERIFIED'
     and (cr.expires_at is null or cr.expires_at>now())
    where r.submission_id=p_submission_id
      and not r.is_withdrawn
      and r.verdict in ('APPROVE','APPROVE_VARIANT')
      and r.independent_attested=true
      and r.conflict_of_interest_declared=false
      and r.context_name=v_context
      and r.reviewer_contributor_id<>v_author_contributor
  )
  select coalesce(array_agg(req.role_code order by req.role_code),'{}'::text[])
    into v_missing_roles
  from unnest(v_policy.required_role_codes) req(role_code)
  where not exists(
    select 1 from valid_positive r where r.review_role_code=req.role_code
  );

  if v_policy.required_domain_level is null then
    v_domain_ok:=true;
  else
    select exists(
      select 1
      from public.linguistic_submission_reviews r
      join public.linguistic_domain_qualifications dq on dq.id=r.domain_qualification_id
      join public.linguistic_role_catalog rc on rc.role_code=r.review_role_code and rc.is_active
      join public.linguistic_contributor_roles cr
        on cr.role_id=rc.id
       and cr.contributor_id=r.reviewer_contributor_id
       and cr.language_id=v_language_id
       and cr.variant_id is not distinct from v_variant_id
       and cr.status='VERIFIED'
       and (cr.expires_at is null or cr.expires_at>now())
      where r.submission_id=p_submission_id
        and not r.is_withdrawn
        and r.verdict in ('APPROVE','APPROVE_VARIANT')
        and r.independent_attested=true
        and r.conflict_of_interest_declared=false
        and r.context_name=v_context
        and r.reviewer_contributor_id<>v_author_contributor
        and dq.contributor_id=r.reviewer_contributor_id
        and dq.language_id=v_language_id
        and dq.variant_id is not distinct from v_variant_id
        and dq.context_name=v_context
        and dq.verification_status='VERIFIED'
        and public.tc_domain_level_rank(dq.qualification_level)>=public.tc_domain_level_rank(v_policy.required_domain_level)
    ) into v_domain_ok;
  end if;

  select not (v_policy.block_ai_assisted_approval and s.ai_assistance_disclosed)
    into v_ai_ok
  from public.linguistic_task_submissions s
  where s.id=p_submission_id;

  return jsonb_build_object(
    'approval_ready',(
      v_latest_ok
      and v_submission_status not in ('REJECTED','WITHDRAWN')
      and coalesce(v_approved,0)>=v_required
      and coalesce(v_negative,0)=0
      and cardinality(v_missing_roles)=0
      and v_domain_ok
      and v_ai_ok
    ),
    'context',v_context,
    'latest_version',v_latest_ok,
    'required_independent_reviewers',v_required,
    'approved_independent_reviewers',coalesce(v_approved,0),
    'unresolved_or_invalid_reviews',coalesce(v_negative,0),
    'missing_roles',v_missing_roles,
    'domain_requirement_met',v_domain_ok,
    'ai_requirement_met',v_ai_ok
  );
end;
$$;

create or replace function public.tc_linguistic_submission_readiness(p_submission_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  v_approval jsonb;
  v_assignment_id uuid;
  v_auth_ok boolean;
  v_final_decision boolean;
  v_submission_approved boolean;
begin
  v_approval:=public.tc_linguistic_submission_approval_readiness(p_submission_id);

  select s.assignment_id,(s.status='APPROVED')
    into v_assignment_id,v_submission_approved
  from public.linguistic_task_submissions s
  where s.id=p_submission_id;

  if v_assignment_id is null then
    return jsonb_build_object('ready',false,'error','SUBMISSION_NOT_FOUND');
  end if;

  select exists(
    select 1 from public.linguistic_submission_approval_decisions d
    where d.submission_id=p_submission_id and d.decision='APPROVED'
  ) into v_final_decision;

  with recursive material_submissions(id,parent_submission_id) as (
    select s.id,s.parent_submission_id
    from public.linguistic_task_submissions s
    where s.id=p_submission_id
    union all
    select p.id,p.parent_submission_id
    from public.linguistic_task_submissions p
    join material_submissions m on p.id=m.parent_submission_id
  ), auth_state as (
    select m.id,
      (select (a.status='GRANTED'
               and a.app_ui_publication_allowed
               and (a.expires_at is null or a.expires_at>now()))
       from public.linguistic_contribution_authorizations a
       where a.submission_id=m.id
       order by a.authorization_version desc limit 1) as allowed
    from material_submissions m
  )
  select coalesce(bool_and(coalesce(allowed,false)),false)
    into v_auth_ok
  from auth_state;

  return v_approval || jsonb_build_object(
    'ready',(
      coalesce((v_approval->>'approval_ready')::boolean,false)
      and v_submission_approved
      and v_final_decision
      and v_auth_ok
    ),
    'linguistically_approved',v_submission_approved,
    'human_final_decision_complete',v_final_decision,
    'publication_authorizations_complete',v_auth_ok
  );
end;
$$;

create or replace function public.tc_finalize_linguistic_submission_approval(
  p_submission_public_id text,
  p_rationale text default null
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_person uuid;
  v_contributor uuid;
  v_submission uuid;
  v_assignment uuid;
  v_task uuid;
  v_author_contributor uuid;
  v_context text;
  v_policy public.linguistic_review_policies%rowtype;
  v_required_final_role text;
  v_ready jsonb;
  v_decision_public_id text;
  v_required_submissions integer;
  v_approved_submissions integer;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.tc_is_feature_enabled('linguistics.submission_approval') then
    raise exception 'LINGUISTIC_SUBMISSION_APPROVAL_DISABLED';
  end if;

  select p.id,c.id into v_person,v_contributor
  from public.persons p
  join public.linguistic_contributors c on c.person_id=p.id and c.is_active=true
  where p.auth_user_id=auth.uid();
  if v_contributor is null then raise exception 'LINGUISTIC_CONTRIBUTOR_REQUIRED'; end if;

  select s.id,a.id,a.task_id,a.contributor_id
    into v_submission,v_assignment,v_task,v_author_contributor
  from public.linguistic_task_submissions s
  join public.linguistic_task_assignments a on a.id=s.assignment_id
  where s.public_id=p_submission_public_id
  for update of s,a;

  if v_submission is null then raise exception 'SUBMISSION_NOT_FOUND'; end if;
  if v_contributor=v_author_contributor then raise exception 'SELF_APPROVAL_FORBIDDEN'; end if;

  v_context:=public.tc_linguistic_effective_task_context(v_task);
  select * into v_policy
  from public.linguistic_review_policies
  where context_name=v_context and is_active=true;
  if v_policy.context_name is null then raise exception 'ACTIVE_REVIEW_POLICY_NOT_FOUND'; end if;

  v_required_final_role := case
    when 'FINAL_REVIEWER'=any(v_policy.required_role_codes) then 'FINAL_REVIEWER'
    else 'LINGUISTIC_VALIDATOR'
  end;

  if not exists(
    select 1
    from public.linguistic_submission_reviews r
    join public.linguistic_role_catalog rc on rc.role_code=r.review_role_code and rc.is_active
    join public.linguistic_contributor_roles cr
      on cr.role_id=rc.id
     and cr.contributor_id=r.reviewer_contributor_id
     and cr.status='VERIFIED'
     and (cr.expires_at is null or cr.expires_at>now())
    where r.submission_id=v_submission
      and r.reviewer_contributor_id=v_contributor
      and r.review_role_code=v_required_final_role
      and r.verdict in ('APPROVE','APPROVE_VARIANT')
      and r.independent_attested=true
      and r.conflict_of_interest_declared=false
      and not r.is_withdrawn
      and r.context_name=v_context
  ) then
    raise exception 'FINALIZER_MUST_HAVE_VALID_POSITIVE_REVIEW:%',v_required_final_role;
  end if;

  v_ready:=public.tc_linguistic_submission_approval_readiness(v_submission);
  if coalesce((v_ready->>'approval_ready')::boolean,false) is not true then
    raise exception 'SUBMISSION_NOT_READY_FOR_APPROVAL:%',v_ready::text;
  end if;

  insert into public.linguistic_submission_approval_decisions(
    submission_id,decided_by_contributor_id,finalization_role_code,decision,readiness_snapshot,rationale
  ) values(
    v_submission,v_contributor,v_required_final_role,'APPROVED',v_ready,
    nullif(btrim(coalesce(p_rationale,'')),'')
  )
  on conflict (submission_id) do nothing
  returning public_id into v_decision_public_id;

  if v_decision_public_id is null then raise exception 'SUBMISSION_ALREADY_FINALIZED'; end if;

  update public.linguistic_task_submissions
     set status='APPROVED',reviewed_at=now(),updated_at=now()
   where id=v_submission;

  update public.linguistic_task_assignments
     set status='APPROVED',completed_at=now(),updated_at=now()
   where id=v_assignment;

  select required_submission_count into v_required_submissions
  from public.linguistic_tasks where id=v_task;

  select count(*) into v_approved_submissions
  from public.linguistic_task_submissions s
  join public.linguistic_task_assignments a on a.id=s.assignment_id
  where a.task_id=v_task and s.status='APPROVED';

  update public.linguistic_tasks
     set status=case when v_approved_submissions>=v_required_submissions then 'APPROVED' else 'IN_REVIEW' end,
         updated_at=now()
   where id=v_task;

  insert into public.linguistic_work_events(entity_type,entity_id,event_type,actor_person_id,payload)
  values(
    'SUBMISSION',v_submission,'FINAL_APPROVAL',v_person,
    jsonb_build_object(
      'decision_public_id',v_decision_public_id,
      'context',v_context,
      'finalization_role',v_required_final_role,
      'task_approved',(v_approved_submissions>=v_required_submissions)
    )
  );

  return jsonb_build_object(
    'success',true,
    'submission_public_id',p_submission_public_id,
    'decision_public_id',v_decision_public_id,
    'submission_status','APPROVED',
    'task_approved',(v_approved_submissions>=v_required_submissions),
    'publication_authorized',false
  );
end;
$$;

revoke all on function public.tc_finalize_linguistic_submission_approval(text,text) from public, anon;
grant execute on function public.tc_finalize_linguistic_submission_approval(text,text) to authenticated;

commit;
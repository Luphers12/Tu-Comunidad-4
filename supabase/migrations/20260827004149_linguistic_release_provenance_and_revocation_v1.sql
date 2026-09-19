begin;

-- A withdrawn review may be replaced by a fresh review; only one active vote per human/submission.
alter table public.linguistic_submission_reviews
  drop constraint if exists linguistic_submission_reviews_submission_id_reviewer_contri_key;
create unique index if not exists uq_linguistic_submission_review_active_person
on public.linguistic_submission_reviews(submission_id,reviewer_contributor_id)
where is_withdrawn=false;

-- Every official human translation keeps its exact approved submission provenance.
alter table public.translation_proposals
  add column if not exists source_submission_id uuid null references public.linguistic_task_submissions(id) on delete restrict;
create unique index if not exists uq_translation_proposal_source_submission
on public.translation_proposals(source_submission_id)
where source_submission_id is not null;

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
     or new.source_submission_id is distinct from old.source_submission_id
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

-- Review must be an assigned job, not an unsolicited vote by someone who discovered a public id.
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

  if exists(
    select 1 from public.linguistic_task_submissions s0
    join public.linguistic_task_submissions s1 on s1.assignment_id=s0.assignment_id and s1.version>s0.version
    where s0.id=new.submission_id
  ) then raise exception 'STALE_SUBMISSION_REVIEW_FORBIDDEN'; end if;

  if new.reviewer_contributor_id=v_author_contributor then raise exception 'SELF_REVIEW_FORBIDDEN'; end if;
  if exists(
    select 1 from public.linguistic_task_assignments a
    where a.task_id=v_task_id and a.contributor_id=new.reviewer_contributor_id
      and public.tc_linguistic_role_class(a.assignment_role)='AUTHORING'
      and a.status not in ('CANCELED','EXPIRED')
  ) then raise exception 'PARTICIPANT_REVIEW_FORBIDDEN'; end if;

  if not exists(
    select 1 from public.linguistic_task_assignments a
    where a.task_id=v_task_id
      and a.contributor_id=new.reviewer_contributor_id
      and a.assignment_role=new.review_role_code
      and a.status in ('ACCEPTED','SUBMITTED','CHANGES_REQUESTED')
  ) then raise exception 'REVIEW_ASSIGNMENT_REQUIRED'; end if;

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

  if new.review_role_code='FINAL_REVIEWER' then
    select greatest(t.required_review_count,v_policy.min_independent_reviewers)
      into v_required_count from public.linguistic_tasks t where t.id=v_task_id;

    select count(distinct r.reviewer_contributor_id) filter(where r.verdict in ('APPROVE','APPROVE_VARIANT')),
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

-- Readiness counts only currently valid positive reviewers; concerns remain blocking until withdrawn/resolved.
create or replace function public.tc_linguistic_submission_readiness(p_submission_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path = ''
as $$
declare
  v_task_id uuid;
  v_language_id uuid;
  v_variant_id uuid;
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
  select a.task_id,t.target_language_id,t.target_variant_id into v_task_id,v_language_id,v_variant_id
  from public.linguistic_task_submissions s
  join public.linguistic_task_assignments a on a.id=s.assignment_id
  join public.linguistic_tasks t on t.id=a.task_id
  where s.id=p_submission_id;
  if v_task_id is null then return jsonb_build_object('ready',false,'error','SUBMISSION_NOT_FOUND'); end if;

  v_context:=public.tc_linguistic_effective_task_context(v_task_id);
  select * into v_policy from public.linguistic_review_policies where context_name=v_context and is_active=true;
  select greatest(t.required_review_count,v_policy.min_independent_reviewers) into v_required
  from public.linguistic_tasks t where t.id=v_task_id;

  with valid_positive as (
    select r.*
    from public.linguistic_submission_reviews r
    join public.linguistic_role_catalog rc on rc.role_code=r.review_role_code and rc.is_active
    join public.linguistic_contributor_roles cr on cr.role_id=rc.id
      and cr.contributor_id=r.reviewer_contributor_id
      and cr.language_id=v_language_id
      and cr.variant_id is not distinct from v_variant_id
      and cr.status='VERIFIED'
      and (cr.expires_at is null or cr.expires_at>now())
    where r.submission_id=p_submission_id and not r.is_withdrawn
      and r.verdict in ('APPROVE','APPROVE_VARIANT')
  )
  select count(distinct reviewer_contributor_id) into v_approved from valid_positive;

  select count(*) into v_negative
  from public.linguistic_submission_reviews r
  where r.submission_id=p_submission_id and not r.is_withdrawn
    and r.verdict not in ('APPROVE','APPROVE_VARIANT');

  with valid_positive as (
    select r.*
    from public.linguistic_submission_reviews r
    join public.linguistic_role_catalog rc on rc.role_code=r.review_role_code and rc.is_active
    join public.linguistic_contributor_roles cr on cr.role_id=rc.id
      and cr.contributor_id=r.reviewer_contributor_id
      and cr.language_id=v_language_id
      and cr.variant_id is not distinct from v_variant_id
      and cr.status='VERIFIED'
      and (cr.expires_at is null or cr.expires_at>now())
    where r.submission_id=p_submission_id and not r.is_withdrawn
      and r.verdict in ('APPROVE','APPROVE_VARIANT')
  )
  select coalesce(array_agg(req.role_code order by req.role_code),'{}'::text[])
    into v_missing_roles
  from unnest(v_policy.required_role_codes) req(role_code)
  where not exists(select 1 from valid_positive r where r.review_role_code=req.role_code);

  v_final_ok := not ('FINAL_REVIEWER'=any(v_policy.required_role_codes)) or not ('FINAL_REVIEWER'=any(v_missing_roles));

  if v_policy.required_domain_level is null then v_domain_ok:=true;
  else
    select exists(
      select 1 from public.linguistic_submission_reviews r
      join public.linguistic_domain_qualifications dq on dq.id=r.domain_qualification_id
      join public.linguistic_role_catalog rc on rc.role_code=r.review_role_code and rc.is_active
      join public.linguistic_contributor_roles cr on cr.role_id=rc.id
        and cr.contributor_id=r.reviewer_contributor_id
        and cr.language_id=v_language_id
        and cr.variant_id is not distinct from v_variant_id
        and cr.status='VERIFIED'
        and (cr.expires_at is null or cr.expires_at>now())
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
    'ready',(coalesce(v_approved,0)>=v_required and coalesce(v_negative,0)=0 and cardinality(v_missing_roles)=0 and v_domain_ok and v_ai_ok and v_auth_ok and v_final_ok),
    'context',v_context,
    'required_independent_reviewers',v_required,
    'approved_independent_reviewers',coalesce(v_approved,0),
    'unresolved_reviews',coalesce(v_negative,0),
    'missing_roles',v_missing_roles,
    'domain_requirement_met',v_domain_ok,
    'ai_requirement_met',v_ai_ok,
    'publication_authorizations_complete',v_auth_ok,
    'final_review_complete',v_final_ok
  );
end;
$$;

-- Mark assigned review work complete after a submitted review.
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
  v_task uuid;
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

  select s.id,a.task_id into v_submission,v_task
  from public.linguistic_task_submissions s join public.linguistic_task_assignments a on a.id=s.assignment_id
  where s.public_id=p_submission_public_id;
  if v_submission is null then raise exception 'SUBMISSION_NOT_FOUND'; end if;

  insert into public.linguistic_submission_reviews(
    submission_id,reviewer_contributor_id,review_role_code,context_name,verdict,observation,
    independent_attested,conflict_of_interest_declared,conflict_note
  ) values(
    v_submission,v_contributor,p_review_role_code,'NORMAL_UI',p_verdict,nullif(btrim(coalesce(p_observation,'')),''),
    p_independent_attested,p_conflict_of_interest_declared,nullif(btrim(coalesce(p_conflict_note,'')),'')
  ) returning id,public_id into v_review_id,v_public_id;

  update public.linguistic_task_assignments
     set status='SUBMITTED',completed_at=now(),updated_at=now()
   where task_id=v_task and contributor_id=v_contributor and assignment_role=p_review_role_code
     and status in ('ACCEPTED','CHANGES_REQUESTED');

  insert into public.linguistic_work_events(entity_type,entity_id,event_type,actor_person_id,payload)
  values('SUBMISSION_REVIEW',v_review_id,'REVIEW_SUBMITTED',v_person,jsonb_build_object('submission_public_id',p_submission_public_id,'role',p_review_role_code,'verdict',p_verdict));

  return jsonb_build_object('success',true,'review_public_id',v_public_id,'readiness',public.tc_linguistic_submission_readiness(v_submission));
end;
$$;

-- Promote only an approved, rights-cleared submission to the canonical translation table.
create or replace function public.tc_promote_linguistic_submission_to_translation(p_submission_public_id text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_submission uuid;
  v_text text;
  v_language uuid;
  v_variant uuid;
  v_concept uuid;
  v_author_person uuid;
  v_ready jsonb;
  v_norm record;
  v_translation uuid;
  v_public_id text;
begin
  if not public.tc_is_feature_enabled('linguistics.publication') then raise exception 'LINGUISTIC_PUBLICATION_DISABLED'; end if;

  select s.id,s.submitted_text,t.target_language_id,t.target_variant_id,
         coalesce(t.concept_id,k.concept_id),c.person_id
    into v_submission,v_text,v_language,v_variant,v_concept,v_author_person
  from public.linguistic_task_submissions s
  join public.linguistic_task_assignments a on a.id=s.assignment_id
  join public.linguistic_tasks t on t.id=a.task_id
  join public.linguistic_contributors c on c.id=a.contributor_id
  left join public.ui_interface_keys k on k.id=t.ui_key_id
  where s.public_id=p_submission_public_id;
  if v_submission is null then raise exception 'SUBMISSION_NOT_FOUND'; end if;
  if v_text is null or btrim(v_text)='' then raise exception 'TEXT_SUBMISSION_REQUIRED'; end if;
  if v_concept is null then raise exception 'CONCEPT_REQUIRED_FOR_CANONICAL_TRANSLATION'; end if;

  v_ready:=public.tc_linguistic_submission_readiness(v_submission);
  if coalesce((v_ready->>'ready')::boolean,false) is not true then
    raise exception 'SUBMISSION_NOT_READY_FOR_RELEASE:%',v_ready::text;
  end if;

  select * into v_norm from public.normalize_linguistic_search(v_text,v_language,v_variant);

  insert into public.translation_proposals(
    concept_id,language_id,variant_id,orthography_version_id,source_submission_id,
    texto_original,texto_clean_input,texto_normalized_unicode,texto_search_folded,
    normalization_transformations,consensus_status,created_by_person_id
  ) values(
    v_concept,v_language,v_variant,v_norm.out_orthography_version_id,v_submission,
    v_norm.out_raw_original,v_norm.out_clean_input,v_norm.out_normalized_unicode,v_norm.out_search_folded,
    v_norm.out_transformations,'VERIFICADA',v_author_person
  )
  on conflict (source_submission_id) where source_submission_id is not null do update
    set consensus_status=excluded.consensus_status,updated_at=now()
  returning id,public_id into v_translation,v_public_id;

  return jsonb_build_object('success',true,'translation_public_id',v_public_id,'source_submission_public_id',p_submission_public_id,'status','VERIFICADA');
end;
$$;
revoke all on function public.tc_promote_linguistic_submission_to_translation(text) from public,anon,authenticated;
grant execute on function public.tc_promote_linguistic_submission_to_translation(text) to service_role;

-- Published dictionary versions can be invalidated but never rewritten after first release.
alter table public.ui_dictionary_versions add column if not exists invalidated_at timestamptz null;
alter table public.ui_dictionary_versions add column if not exists invalidation_reason text null;

create or replace function public.tc_guard_ui_release_entry()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_released_at timestamptz;
begin
  select v.released_at into v_released_at from public.ui_dictionary_versions v where v.id=old.dictionary_version_id;
  if v_released_at is not null then raise exception 'UI_RELEASE_HISTORY_IMMUTABLE'; end if;
  return coalesce(new,old);
end;
$$;

create or replace function public.tc_invalidate_ui_releases_for_submission(p_submission_id uuid,p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  with recursive affected(id) as (
    select p_submission_id
    union all
    select s.id from public.linguistic_task_submissions s join affected a on s.parent_submission_id=a.id
  ), versions as (
    select distinct e.dictionary_version_id
    from public.ui_dictionary_release_entries e
    join public.translation_proposals tp on tp.id=e.translation_proposal_id
    where tp.source_submission_id in (select id from affected)
  )
  update public.ui_dictionary_versions v
     set is_released=false,
         invalidated_at=coalesce(v.invalidated_at,now()),
         invalidation_reason=coalesce(v.invalidation_reason,p_reason)
   where v.id in (select dictionary_version_id from versions)
     and v.released_at is not null;
end;
$$;
revoke all on function public.tc_invalidate_ui_releases_for_submission(uuid,text) from public,anon,authenticated;

create or replace function public.tc_invalidate_release_on_authorization_revoke()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status is distinct from new.status and new.status='REVOKED' then
    perform public.tc_invalidate_ui_releases_for_submission(new.submission_id,'CONTRIBUTION_AUTHORIZATION_REVOKED');
  end if;
  return new;
end;
$$;
drop trigger if exists trg_invalidate_release_on_authorization_revoke on public.linguistic_contribution_authorizations;
create trigger trg_invalidate_release_on_authorization_revoke
after update of status on public.linguistic_contribution_authorizations
for each row execute function public.tc_invalidate_release_on_authorization_revoke();

create or replace function public.tc_invalidate_release_on_review_withdrawal()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not old.is_withdrawn and new.is_withdrawn then
    perform public.tc_invalidate_ui_releases_for_submission(new.submission_id,'LINGUISTIC_REVIEW_WITHDRAWN');
  end if;
  return new;
end;
$$;
drop trigger if exists trg_invalidate_release_on_review_withdrawal on public.linguistic_submission_reviews;
create trigger trg_invalidate_release_on_review_withdrawal
after update of is_withdrawn on public.linguistic_submission_reviews
for each row execute function public.tc_invalidate_release_on_review_withdrawal();

-- Compilation accepts target-language human translations only when their source submission is still release-ready.
create or replace function public.compile_ui_dictionary_release(p_version_code integer,p_description text,p_target_language_id uuid,p_target_variant_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_version uuid;
  v_hash text;
  v_holes int;
begin
  if not public.tc_is_feature_enabled('linguistics.publication') then raise exception 'LINGUISTIC_PUBLICATION_DISABLED'; end if;

  insert into public.ui_dictionary_versions(version_code,target_language_id,target_variant_id,content_hash,description)
  values(p_version_code,p_target_language_id,p_target_variant_id,'PENDING',p_description)
  returning id into v_version;

  with ranked as (
    select k.id key_id,tp.id trp_id,tp.language_id,tp.variant_id,
      case
        when p_target_variant_id is not null and tp.language_id=p_target_language_id and tp.variant_id=p_target_variant_id then 1
        when tp.language_id=p_target_language_id and tp.variant_id is null then 2
        when tp.language_id=cp.fallback_language_id and tp.variant_id is null then 3
      end rk,
      case
        when p_target_variant_id is not null and tp.language_id=p_target_language_id and tp.variant_id=p_target_variant_id then 'EXACT_VARIANT'
        when tp.language_id=p_target_language_id and tp.variant_id is null then 'LANGUAGE_GENERAL'
        when tp.language_id=cp.fallback_language_id and tp.variant_id is null then 'SYSTEM_FALLBACK'
      end rt,
      row_number() over (
        partition by k.id
        order by case
          when p_target_variant_id is not null and tp.language_id=p_target_language_id and tp.variant_id=p_target_variant_id then 1
          when tp.language_id=p_target_language_id and tp.variant_id is null then 2
          when tp.language_id=cp.fallback_language_id and tp.variant_id is null then 3
          else 9 end,
          (tp.consensus_status='VERIFICADA') desc,tp.created_at,tp.id
      ) rn
    from public.ui_interface_keys k
    join public.linguistic_context_policies cp on cp.context_name=k.context_name
    join public.linguistic_context_policy_statuses cps on cps.policy_id=cp.id
    join public.translation_proposals tp on tp.concept_id=k.concept_id and tp.consensus_status=cps.allowed_status
    where
      (tp.language_id=cp.fallback_language_id)
      or
      (tp.language_id=p_target_language_id and tp.source_submission_id is not null
       and coalesce((public.tc_linguistic_submission_readiness(tp.source_submission_id)->>'ready')::boolean,false))
  ), winners as (
    select * from ranked where rn=1 and rk is not null
  )
  insert into public.ui_dictionary_release_entries(dictionary_version_id,ui_key_id,translation_proposal_id,resolved_language_id,resolved_variant_id,resolution_type)
  select v_version,key_id,trp_id,language_id,variant_id,rt from winners;

  select count(*) into v_holes
  from public.ui_interface_keys k
  left join public.ui_dictionary_release_entries e on e.dictionary_version_id=v_version and e.ui_key_id=k.id
  left join public.translation_proposals tp on tp.id=e.translation_proposal_id
  where k.context_name in('PAYMENT','LEGAL','SAFETY','IDENTITY','COMPLIANCE')
    and(e.id is null or tp.consensus_status<>'VERIFICADA');
  if v_holes>0 then raise exception 'RELEASE_BLOCKED_CRITICAL_GAPS:%',v_holes; end if;

  select encode(extensions.digest(convert_to(coalesce(string_agg(k.ui_key||chr(31)||tp.texto_original||chr(30),'' order by k.ui_key),''),'UTF8'),'sha256'),'hex')
  into v_hash
  from public.ui_dictionary_release_entries e
  join public.ui_interface_keys k on k.id=e.ui_key_id
  join public.translation_proposals tp on tp.id=e.translation_proposal_id
  where e.dictionary_version_id=v_version;

  update public.ui_dictionary_versions
     set content_hash=v_hash,is_released=true,released_at=now(),invalidated_at=null,invalidation_reason=null
   where id=v_version;
  return v_version;
end;
$$;
revoke all on function public.compile_ui_dictionary_release(integer,text,uuid,uuid) from public,anon,authenticated;
grant execute on function public.compile_ui_dictionary_release(integer,text,uuid,uuid) to service_role;

-- If all releases for a language/variant have been invalidated, clients are told to clear stale cached translations.
create or replace function public.get_ui_dictionary_bundle(p_client_lang_id uuid,p_client_var_id uuid default null,p_target_version integer default null)
returns jsonb
language plpgsql
stable security definer
set search_path = ''
as $$
declare
  v_version uuid;
  v_code int;
  v_hash text;
  v_payload jsonb;
  v_key_count int;
begin
  select v.id,v.version_code,v.content_hash into v_version,v_code,v_hash
  from public.ui_dictionary_versions v
  where v.is_released
    and v.target_language_id=p_client_lang_id
    and v.target_variant_id is not distinct from p_client_var_id
  order by v.version_code desc limit 1;

  if v_version is null then
    return jsonb_build_object('dictionary_version',null,'dictionary_hash',null,'key_count',0,'requires_sync',true,'invalidate_cache',true,'translations','{}'::jsonb);
  end if;

  select count(*) into v_key_count from public.ui_dictionary_release_entries e where e.dictionary_version_id=v_version;
  if p_target_version is not null and p_target_version=v_code then
    return jsonb_build_object('dictionary_version',v_code,'dictionary_hash',v_hash,'key_count',v_key_count,'requires_sync',false,'invalidate_cache',false,'translations','{}'::jsonb);
  end if;

  select jsonb_object_agg(k.ui_key,tp.texto_original order by k.ui_key) into v_payload
  from public.ui_dictionary_release_entries e
  join public.ui_interface_keys k on k.id=e.ui_key_id
  join public.translation_proposals tp on tp.id=e.translation_proposal_id
  where e.dictionary_version_id=v_version;

  return jsonb_build_object('dictionary_version',v_code,'dictionary_hash',v_hash,'key_count',v_key_count,'requires_sync',true,'invalidate_cache',false,'translations',coalesce(v_payload,'{}'::jsonb));
end;
$$;

commit;
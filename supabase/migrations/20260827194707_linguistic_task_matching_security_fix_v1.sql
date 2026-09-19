begin;

revoke all on function public.tc_linguistic_task_candidates(uuid) from authenticated;

create or replace function public.tc_linguistic_matching_actor(p_capability varchar)
returns table(profile_id uuid, person_id uuid)
language sql
security definer
set search_path=public
as $$
  select p.id, p.person_id
  from public.current_user_profile_ids() cup
  join public.profiles p on p.id=cup.profile_id
  where public.internal_has_capability(p.id, p_capability, 'GLOBAL'::public.tc_scope_type, null)
  order by case when p.profile_type='ADM' then 0 else 1 end, p.created_at
  limit 1;
$$;
revoke all on function public.tc_linguistic_matching_actor(varchar) from public, anon, authenticated;

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
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.tc_is_feature_enabled('linguistics.task_matching') then
    raise exception 'FEATURE_DISABLED: linguistics.task_matching';
  end if;

  if not exists (select 1 from public.tc_linguistic_matching_actor('linguistic.task.match')) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  if not exists (select 1 from public.linguistic_tasks where id=p_task_id and status='OPEN') then
    raise exception 'TASK_NOT_OPEN';
  end if;

  return query
  with task as (
    select t.* from public.linguistic_tasks t where t.id=p_task_id
  ),
  base as (
    select
      lc.id as contributor_id,
      lc.public_id as contributor_public_id,
      rc.role_code,
      (lcr.variant_id is not distinct from t.target_variant_id) as exact_variant_match,
      case when t.requires_verified_domain then exists (
        select 1 from public.linguistic_domain_qualifications dq
        where dq.contributor_id=lc.id
          and dq.language_id=t.target_language_id
          and (dq.variant_id is not distinct from t.target_variant_id)
          and dq.context_name=t.context_name
          and dq.verification_status='VERIFIED'
      ) else true end as domain_verified,
      (
        select count(*)::int from public.linguistic_task_assignments a
        where a.contributor_id=lc.id
          and a.status = any(array['ASSIGNED','ACCEPTED','SUBMITTED','CHANGES_REQUESTED'])
      ) as active_assignment_count,
      coalesce((
        select avg(rm.weight) from public.linguistic_reputation_matrix rm
        where rm.contributor_id=lc.id
          and rm.language_id=t.target_language_id
          and (rm.variant_id is not distinct from t.target_variant_id)
      ),1.00)::numeric as reputation_weight,
      exists (
        select 1 from public.linguistic_task_assignments prior
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
      t.required_role_code
    from task t
    join public.linguistic_contributor_roles lcr
      on lcr.language_id=t.target_language_id and lcr.status='VERIFIED'
    join public.linguistic_role_catalog rc
      on rc.id=lcr.role_id and rc.role_code=t.required_role_code and rc.is_active=true
    join public.linguistic_contributors lc
      on lc.id=lcr.contributor_id and lc.is_active=true
    join public.linguistic_profiles lp
      on lp.contributor_id=lc.id
     and lp.can_receive_tasks=true
     and lp.availability_status='AVAILABLE'
    where (not t.requires_exact_variant or lcr.variant_id is not distinct from t.target_variant_id)
  )
  select
    b.contributor_id,
    b.contributor_public_id,
    b.role_code,
    b.exact_variant_match,
    b.domain_verified,
    b.active_assignment_count,
    b.reputation_weight,
    (100
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
end;
$$;
revoke all on function public.tc_linguistic_task_candidates(uuid) from public, anon;
grant execute on function public.tc_linguistic_task_candidates(uuid) to authenticated;

create or replace function public.tc_run_linguistic_task_matching(p_task_id uuid, p_limit integer default 10)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_actor record;
  v_task public.linguistic_tasks%rowtype;
  v_run_id uuid;
  v_count integer:=0;
begin
  if p_limit < 1 or p_limit > 25 then raise exception 'INVALID_LIMIT'; end if;
  if not public.tc_is_feature_enabled('linguistics.task_matching') then raise exception 'FEATURE_DISABLED: linguistics.task_matching'; end if;
  select * into v_actor from public.tc_linguistic_matching_actor('linguistic.task.match');
  if v_actor.profile_id is null then raise exception 'NOT_AUTHORIZED'; end if;
  select * into v_task from public.linguistic_tasks where id=p_task_id for update;
  if not found or v_task.status<>'OPEN' then raise exception 'TASK_NOT_OPEN'; end if;
  if v_task.required_role_code is null or v_task.context_name is null then raise exception 'TASK_MATCHING_CONTRACT_INCOMPLETE'; end if;

  insert into public.linguistic_task_match_runs(task_id,requested_role_code,status,generated_by_person_id,expires_at)
  values(p_task_id,v_task.required_role_code,'CALCULATED',v_actor.person_id,now()+interval '2 hours')
  returning id into v_run_id;

  insert into public.linguistic_task_match_candidates(
    match_run_id,contributor_id,rank_position,score,active_assignment_count,
    exact_variant_match,domain_verified,reputation_weight,conflict_detected,eligibility_snapshot
  )
  select v_run_id,c.contributor_id,row_number() over(order by c.match_score desc,c.active_assignment_count,c.contributor_public_id)::int,
         c.match_score,c.active_assignment_count,c.exact_variant_match,c.domain_verified,c.reputation_weight,c.conflict_detected,
         jsonb_build_object('role_code',c.role_code,'calculated_at',now())
  from public.tc_linguistic_task_candidates(p_task_id) c
  limit p_limit;

  get diagnostics v_count = row_count;
  update public.linguistic_task_match_runs set candidate_count=v_count where id=v_run_id;

  insert into public.linguistic_task_assignment_suggestions(match_run_id,task_id,contributor_id,assignment_role)
  select v_run_id,p_task_id,c.contributor_id,v_task.required_role_code
  from public.linguistic_task_match_candidates c
  where c.match_run_id=v_run_id
  order by c.rank_position
  limit 3;

  return jsonb_build_object('match_run_id',v_run_id,'candidate_count',v_count,'suggestion_count',least(v_count,3));
end;
$$;
revoke all on function public.tc_run_linguistic_task_matching(uuid,integer) from public, anon;
grant execute on function public.tc_run_linguistic_task_matching(uuid,integer) to authenticated;

create or replace function public.tc_approve_linguistic_assignment_suggestion(p_suggestion_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_actor record;
  v_s public.linguistic_task_assignment_suggestions%rowtype;
  v_task public.linguistic_tasks%rowtype;
  v_candidate record;
  v_assignment_id uuid;
begin
  if not public.tc_is_feature_enabled('linguistics.work_program') then raise exception 'FEATURE_DISABLED: linguistics.work_program'; end if;
  if not public.tc_is_feature_enabled('linguistics.task_matching') then raise exception 'FEATURE_DISABLED: linguistics.task_matching'; end if;
  select * into v_actor from public.tc_linguistic_matching_actor('linguistic.task.assign');
  if v_actor.profile_id is null then raise exception 'NOT_AUTHORIZED'; end if;

  select * into v_s from public.linguistic_task_assignment_suggestions where id=p_suggestion_id for update;
  if not found or v_s.status<>'SUGGESTED' then raise exception 'SUGGESTION_NOT_AVAILABLE'; end if;
  select * into v_task from public.linguistic_tasks where id=v_s.task_id for update;
  if v_task.status<>'OPEN' then raise exception 'TASK_NOT_OPEN'; end if;

  select * into v_candidate
  from public.tc_linguistic_task_candidates(v_s.task_id) c
  where c.contributor_id=v_s.contributor_id;
  if v_candidate.contributor_id is null then raise exception 'CANDIDATE_NO_LONGER_ELIGIBLE'; end if;

  insert into public.linguistic_task_assignments(task_id,contributor_id,assignment_role,status,assigned_by_person_id,due_at)
  values(v_s.task_id,v_s.contributor_id,v_s.assignment_role,'ASSIGNED',v_actor.person_id,v_task.due_at)
  returning id into v_assignment_id;

  update public.linguistic_task_assignment_suggestions
  set status='ASSIGNED',approved_by_person_id=v_actor.person_id,approved_at=now()
  where id=p_suggestion_id;

  return jsonb_build_object('assignment_id',v_assignment_id,'suggestion_id',p_suggestion_id,'status','ASSIGNED');
end;
$$;
revoke all on function public.tc_approve_linguistic_assignment_suggestion(uuid) from public, anon;
grant execute on function public.tc_approve_linguistic_assignment_suggestion(uuid) to authenticated;

commit;
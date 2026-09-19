create or replace function public.tc_request_linguistic_content_withdrawal(
  p_authorization_public_id text,
  p_scope text default 'ALL_FUTURE_USE',
  p_reason text default null
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_person_id uuid;
  v_submission_id uuid;
  v_contributor_id uuid;
  v_prior public.linguistic_contribution_authorizations%rowtype;
  v_new_auth_id uuid;
  v_new_auth_public_id text;
  v_new_version integer;
  v_reward_id uuid;
  v_reward_status text;
  v_reward_type text;
  v_compensation_effect text;
  v_withdrawal_id uuid;
  v_withdrawal_public_id text;
  v_retired_count integer := 0;
  v_replacement_status text := 'NOT_REQUIRED';
begin
  if p_scope not in ('APP_UI_PUBLICATION','PUBLIC_AUDIO','MARKETING','RESEARCH_SHARING','THIRD_PARTY_SHARING','AI_TRAINING','VOICE_MODELING','CULTURAL_ARCHIVE','PUBLIC_ATTRIBUTION','ALL_FUTURE_USE') then
    raise exception 'INVALID_WITHDRAWAL_SCOPE';
  end if;

  select p.id into v_person_id from public.persons p where p.auth_user_id=auth.uid();
  if v_person_id is null then raise exception 'AUTHENTICATED_PERSON_REQUIRED'; end if;

  select a.submission_id,a.contributor_id into v_submission_id,v_contributor_id
  from public.linguistic_contribution_authorizations a
  join public.linguistic_contributors c on c.id=a.contributor_id
  where a.public_id=p_authorization_public_id and c.person_id=v_person_id;
  if v_submission_id is null then raise exception 'AUTHORIZATION_NOT_FOUND'; end if;

  select a.* into v_prior
  from public.linguistic_contribution_authorizations a
  where a.submission_id=v_submission_id
  order by a.authorization_version desc limit 1
  for update;
  if v_prior.id is null or v_prior.contributor_id is distinct from v_contributor_id then raise exception 'AUTHORIZATION_OWNER_MISMATCH'; end if;

  v_new_version:=v_prior.authorization_version+1;
  update public.linguistic_contribution_authorizations
  set status='REVOKED',revoked_at=coalesce(revoked_at,now()),
      revocation_reason=coalesce(nullif(btrim(coalesce(p_reason,'')),''),'REPLACED_BY_NARROWER_AUTHORIZATION'),updated_at=now()
  where id=v_prior.id and status='GRANTED';

  insert into public.linguistic_contribution_authorizations(
    submission_id,contributor_id,consent_id,authorization_version,status,internal_review_allowed,
    app_ui_publication_allowed,derivative_formatting_allowed,commercial_use_allowed,public_attribution_allowed,
    marketing_allowed,research_sharing_allowed,third_party_sharing_allowed,ai_training_allowed,voice_modeling_allowed,
    public_audio_allowed,cultural_archive_allowed,archive_access_level,attribution_preference,attribution_display_name,
    license_type,geographic_scope,expires_at,granted_at
  ) values (
    v_prior.submission_id,v_prior.contributor_id,v_prior.consent_id,v_new_version,'GRANTED',true,
    case when p_scope in ('APP_UI_PUBLICATION','ALL_FUTURE_USE') then false else v_prior.app_ui_publication_allowed end,
    case when p_scope='ALL_FUTURE_USE' then false else v_prior.derivative_formatting_allowed end,
    case when p_scope='ALL_FUTURE_USE' then false else v_prior.commercial_use_allowed end,
    case when p_scope in ('PUBLIC_ATTRIBUTION','ALL_FUTURE_USE') then false else v_prior.public_attribution_allowed end,
    case when p_scope in ('MARKETING','ALL_FUTURE_USE') then false else v_prior.marketing_allowed end,
    case when p_scope in ('RESEARCH_SHARING','ALL_FUTURE_USE') then false else v_prior.research_sharing_allowed end,
    case when p_scope in ('THIRD_PARTY_SHARING','ALL_FUTURE_USE') then false else v_prior.third_party_sharing_allowed end,
    case when p_scope in ('AI_TRAINING','ALL_FUTURE_USE') then false else v_prior.ai_training_allowed end,
    case when p_scope in ('VOICE_MODELING','ALL_FUTURE_USE') then false else v_prior.voice_modeling_allowed end,
    case when p_scope in ('PUBLIC_AUDIO','ALL_FUTURE_USE') then false else v_prior.public_audio_allowed end,
    case when p_scope in ('CULTURAL_ARCHIVE','ALL_FUTURE_USE') then false else v_prior.cultural_archive_allowed end,
    case when p_scope in ('CULTURAL_ARCHIVE','ALL_FUTURE_USE') then 'DO_NOT_ARCHIVE' else v_prior.archive_access_level end,
    case when p_scope in ('PUBLIC_ATTRIBUTION','ALL_FUTURE_USE') then 'ANONYMOUS' else v_prior.attribution_preference end,
    case when p_scope in ('PUBLIC_ATTRIBUTION','ALL_FUTURE_USE') then null else v_prior.attribution_display_name end,
    case when p_scope='ALL_FUTURE_USE' then 'INTERNAL_REVIEW_ONLY' else v_prior.license_type end,
    case when p_scope='ALL_FUTURE_USE' then 'TU_COMUNIDAD_INTERNAL_REVIEW' else v_prior.geographic_scope end,
    v_prior.expires_at,now()
  ) returning id,public_id into v_new_auth_id,v_new_auth_public_id;

  select r.id,r.status,r.reward_type into v_reward_id,v_reward_status,v_reward_type
  from public.linguistic_work_rewards r where r.submission_id=v_submission_id;
  if v_reward_id is null or coalesce(v_reward_type,'NONE')='NONE' then v_compensation_effect:='NOT_APPLICABLE';
  elsif v_reward_status='ISSUED' then v_compensation_effect:='NO_AUTOMATIC_REFUND';
  else v_compensation_effect:='REVIEW_BEFORE_ISSUE'; end if;

  if p_scope in ('APP_UI_PUBLICATION','ALL_FUTURE_USE') then
    with recursive affected(id) as (
      select v_submission_id
      union all
      select s.id from public.linguistic_task_submissions s join affected a on s.parent_submission_id=a.id
    ), r as (
      update public.translation_proposals tp
      set publication_status='RETIRED',retired_at=coalesce(retired_at,now()),retirement_reason='CONTRIBUTOR_WITHDRAWAL:'||p_scope,updated_at=now()
      where tp.source_submission_id in (select id from affected)
        and tp.publication_status in ('CANDIDATE','PUBLISHED','WITHDRAWAL_PENDING')
      returning id
    ) select count(*) into v_retired_count from r;
    if v_retired_count>0 then v_replacement_status:='REQUIRED'; end if;

    with recursive affected(id) as (
      select v_submission_id
      union all
      select s.id from public.linguistic_task_submissions s join affected a on s.parent_submission_id=a.id
    ), tids as (
      select tp.id from public.translation_proposals tp where tp.source_submission_id in (select id from affected)
    )
    update public.ui_dictionary_versions v
    set invalidated_at=coalesce(v.invalidated_at,now()),invalidation_reason=coalesce(v.invalidation_reason,'CONTRIBUTOR_WITHDRAWAL:'||p_scope)
    where exists(select 1 from public.ui_dictionary_release_entries e where e.dictionary_version_id=v.id and e.translation_proposal_id in (select id from tids));
  end if;

  insert into public.linguistic_withdrawal_requests(
    submission_id,contributor_id,prior_authorization_id,replacement_authorization_id,withdrawal_scope,reason,
    reward_id,reward_status_at_request,compensation_effect,replacement_status,status,requested_at,effective_at
  ) values (
    v_submission_id,v_contributor_id,v_prior.id,v_new_auth_id,p_scope,nullif(btrim(coalesce(p_reason,'')),''),
    v_reward_id,v_reward_status,v_compensation_effect,v_replacement_status,'EFFECTIVE',now(),now()
  ) returning id,public_id into v_withdrawal_id,v_withdrawal_public_id;

  insert into public.linguistic_work_events(entity_type,entity_id,event_type,actor_person_id,payload)
  values('WITHDRAWAL',v_withdrawal_id,'FUTURE_USE_WITHDRAWN',v_person_id,
    jsonb_build_object('scope',p_scope,'compensation_effect',v_compensation_effect,'retired_translation_count',v_retired_count));

  return jsonb_build_object('success',true,'withdrawal_public_id',v_withdrawal_public_id,'status','EFFECTIVE','scope',p_scope,
    'replacement_authorization_public_id',v_new_auth_public_id,'compensation_effect',v_compensation_effect,
    'automatic_refund',false,'replacement_required',(v_replacement_status='REQUIRED'),'retired_translation_count',v_retired_count);
end;
$$;

revoke all on function public.tc_request_linguistic_content_withdrawal(text,text,text) from public,anon;
grant execute on function public.tc_request_linguistic_content_withdrawal(text,text,text) to authenticated;
begin;

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
     or new.consent_id is distinct from old.consent_id
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
     or new.geographic_scope is distinct from old.geographic_scope
     or new.expires_at is distinct from old.expires_at then
    raise exception 'Authorization grants are immutable; create a new authorization version';
  end if;
  return new;
end;
$$;

create or replace function public.tc_authorize_linguistic_submission_use(
  p_submission_public_id text,
  p_app_ui_publication boolean default false,
  p_derivative_formatting boolean default false,
  p_commercial_use boolean default false,
  p_public_attribution boolean default false,
  p_marketing boolean default false,
  p_research_sharing boolean default false,
  p_third_party_sharing boolean default false,
  p_ai_training boolean default false,
  p_voice_modeling boolean default false,
  p_public_audio boolean default false,
  p_cultural_archive boolean default false,
  p_archive_access_level text default 'DO_NOT_ARCHIVE',
  p_attribution_preference text default 'ANONYMOUS',
  p_attribution_display_name text default null,
  p_license_type text default 'LIMITED_PERMISSION',
  p_geographic_scope text default 'TU_COMUNIDAD_SERVICES'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_person_id uuid;
  v_contributor_id uuid;
  v_submission_id uuid;
  v_version integer;
  v_auth_id uuid;
  v_auth_public_id text;
begin
  if p_archive_access_level not in ('DO_NOT_ARCHIVE','INTERNAL','COMMUNITY','PUBLIC','RESTRICTED') then raise exception 'Invalid archive access level'; end if;
  if p_attribution_preference not in ('ANONYMOUS','PUBLIC_ID','DISPLAY_NAME','COMMUNITY_ONLY') then raise exception 'Invalid attribution preference'; end if;
  if p_attribution_preference='DISPLAY_NAME' and (p_attribution_display_name is null or btrim(p_attribution_display_name)='') then raise exception 'Display name is required'; end if;

  select p.id into v_person_id from public.persons p where p.auth_user_id=auth.uid();
  if v_person_id is null then raise exception 'Authenticated person profile required'; end if;

  select s.id,c.id into v_submission_id,v_contributor_id
    from public.linguistic_task_submissions s
    join public.linguistic_task_assignments a on a.id=s.assignment_id
    join public.linguistic_contributors c on c.id=a.contributor_id
    join public.persons p on p.id=c.person_id
   where s.public_id=p_submission_public_id and p.auth_user_id=auth.uid();
  if v_submission_id is null then raise exception 'Submission not found'; end if;

  select coalesce(max(authorization_version),0)+1 into v_version
    from public.linguistic_contribution_authorizations where submission_id=v_submission_id;

  insert into public.linguistic_contribution_authorizations(
    submission_id,contributor_id,authorization_version,status,internal_review_allowed,
    app_ui_publication_allowed,derivative_formatting_allowed,commercial_use_allowed,public_attribution_allowed,
    marketing_allowed,research_sharing_allowed,third_party_sharing_allowed,ai_training_allowed,voice_modeling_allowed,
    public_audio_allowed,cultural_archive_allowed,archive_access_level,attribution_preference,attribution_display_name,
    license_type,geographic_scope
  ) values (
    v_submission_id,v_contributor_id,v_version,'GRANTED',true,
    p_app_ui_publication,p_derivative_formatting,p_commercial_use,p_public_attribution,
    p_marketing,p_research_sharing,p_third_party_sharing,p_ai_training,p_voice_modeling,
    p_public_audio,p_cultural_archive,p_archive_access_level,p_attribution_preference,
    case when p_attribution_preference='DISPLAY_NAME' then btrim(p_attribution_display_name) else null end,
    p_license_type,p_geographic_scope
  ) returning id,public_id into v_auth_id,v_auth_public_id;

  insert into public.linguistic_work_events(entity_type,entity_id,event_type,actor_person_id,payload)
  values('AUTHORIZATION',v_auth_id,'AUTHORIZATION_VERSION_GRANTED',v_person_id,jsonb_build_object('submission_id',v_submission_id,'authorization_public_id',v_auth_public_id,'version',v_version));

  return jsonb_build_object('success',true,'authorization_public_id',v_auth_public_id,'version',v_version);
end;
$$;

revoke all on function public.tc_authorize_linguistic_submission_use(text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,text,text,text,text,text) from public;
grant execute on function public.tc_authorize_linguistic_submission_use(text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,text,text,text,text,text) to authenticated;

commit;
begin;

create or replace function public.tc_list_my_linguistic_assignments()
returns table(
  assignment_public_id text,
  task_public_id text,
  job_public_id text,
  job_title text,
  assignment_role text,
  assignment_status text,
  task_type text,
  source_text text,
  context_note text,
  variant_name text,
  task_status text,
  due_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select a.public_id,t.public_id,j.public_id,j.title,a.assignment_role,a.status,
         t.task_type,t.source_text,t.context_note,lv.name,t.status,coalesce(a.due_at,t.due_at)
    from public.linguistic_task_assignments a
    join public.linguistic_contributors c on c.id=a.contributor_id
    join public.persons p on p.id=c.person_id
    join public.linguistic_tasks t on t.id=a.task_id
    join public.linguistic_jobs j on j.id=t.job_id
    left join public.language_variants lv on lv.id=t.target_variant_id
   where p.auth_user_id=auth.uid()
   order by coalesce(a.due_at,t.due_at) nulls last,a.assigned_at;
$$;

create or replace function public.tc_accept_linguistic_assignment(p_assignment_public_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_person_id uuid;
  v_assignment_id uuid;
  v_assignment_status text;
  v_task_id uuid;
  v_job_status text;
  v_application_status text;
begin
  select p.id into v_person_id from public.persons p where p.auth_user_id=auth.uid();
  if v_person_id is null then raise exception 'Authenticated person profile required'; end if;

  select a.id,a.status,a.task_id,j.status,app.status
    into v_assignment_id,v_assignment_status,v_task_id,v_job_status,v_application_status
    from public.linguistic_task_assignments a
    join public.linguistic_contributors c on c.id=a.contributor_id
    join public.persons p on p.id=c.person_id
    join public.linguistic_tasks t on t.id=a.task_id
    join public.linguistic_jobs j on j.id=t.job_id
    left join public.linguistic_job_applications app on app.job_id=j.id and app.contributor_id=c.id
   where a.public_id=p_assignment_public_id and p.auth_user_id=auth.uid()
   for update of a;

  if v_assignment_id is null then raise exception 'Assignment not found'; end if;
  if v_job_status <> 'OPEN' then raise exception 'Job is not open'; end if;
  if v_application_status <> 'APPROVED' then raise exception 'Approved job application required'; end if;
  if v_assignment_status <> 'ASSIGNED' then raise exception 'Assignment cannot be accepted from status %',v_assignment_status; end if;

  update public.linguistic_task_assignments
     set status='ACCEPTED',accepted_at=now(),updated_at=now()
   where id=v_assignment_id;

  insert into public.linguistic_work_events(entity_type,entity_id,event_type,actor_person_id,payload)
  values('ASSIGNMENT',v_assignment_id,'ACCEPTED',v_person_id,'{}'::jsonb);

  return jsonb_build_object('success',true,'assignment_public_id',p_assignment_public_id,'status','ACCEPTED');
end;
$$;

create or replace function public.tc_submit_linguistic_text_task(
  p_assignment_public_id text,
  p_submitted_text text,
  p_variant_usage_note text default null,
  p_ai_assistance_disclosed boolean default false,
  p_ai_assistance_details text default null,
  p_sources_consulted jsonb default '[]'::jsonb,
  p_contributor_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_person_id uuid;
  v_contributor_id uuid;
  v_assignment_id uuid;
  v_assignment_status text;
  v_task_id uuid;
  v_task_type text;
  v_task_status text;
  v_allow_ai boolean;
  v_requires_ai_disclosure boolean;
  v_job_status text;
  v_version integer;
  v_submission_id uuid;
  v_submission_public_id text;
begin
  if p_submitted_text is null or btrim(p_submitted_text)='' then raise exception 'Submitted text is required'; end if;
  if jsonb_typeof(coalesce(p_sources_consulted,'[]'::jsonb)) <> 'array' then raise exception 'sources_consulted must be a JSON array'; end if;

  select p.id into v_person_id from public.persons p where p.auth_user_id=auth.uid();
  if v_person_id is null then raise exception 'Authenticated person profile required'; end if;

  select c.id,a.id,a.status,a.task_id,t.task_type,t.status,t.allow_ai_assistance,t.requires_ai_disclosure,j.status
    into v_contributor_id,v_assignment_id,v_assignment_status,v_task_id,v_task_type,v_task_status,v_allow_ai,v_requires_ai_disclosure,v_job_status
    from public.linguistic_task_assignments a
    join public.linguistic_contributors c on c.id=a.contributor_id
    join public.persons p on p.id=c.person_id
    join public.linguistic_tasks t on t.id=a.task_id
    join public.linguistic_jobs j on j.id=t.job_id
   where a.public_id=p_assignment_public_id and p.auth_user_id=auth.uid()
   for update of a;

  if v_assignment_id is null then raise exception 'Assignment not found'; end if;
  if v_job_status <> 'OPEN' then raise exception 'Job is not open'; end if;
  if v_assignment_status not in ('ACCEPTED','CHANGES_REQUESTED') then raise exception 'Assignment is not ready for submission'; end if;
  if v_task_status in ('APPROVED','ARCHIVED','PAUSED') then raise exception 'Task is not accepting submissions'; end if;
  if v_task_type not in ('TRANSLATE_UI','TRANSCRIBE','TERMINOLOGY','CULTURAL_VALIDATE') then raise exception 'This RPC accepts text tasks only'; end if;
  if p_ai_assistance_disclosed and not v_allow_ai then raise exception 'AI assistance is not allowed for this task'; end if;
  if p_ai_assistance_disclosed and v_requires_ai_disclosure and (p_ai_assistance_details is null or btrim(p_ai_assistance_details)='') then
    raise exception 'AI assistance details are required when AI assistance is disclosed';
  end if;

  select coalesce(max(version),0)+1 into v_version
    from public.linguistic_task_submissions
   where assignment_id=v_assignment_id;

  insert into public.linguistic_task_submissions(
    assignment_id,version,submitted_text,variant_usage_note,ai_assistance_disclosed,ai_assistance_details,
    sources_consulted,contributor_note,status
  ) values (
    v_assignment_id,v_version,btrim(p_submitted_text),nullif(btrim(coalesce(p_variant_usage_note,'')),''),
    p_ai_assistance_disclosed,nullif(btrim(coalesce(p_ai_assistance_details,'')),''),
    coalesce(p_sources_consulted,'[]'::jsonb),nullif(btrim(coalesce(p_contributor_note,'')),''),'SUBMITTED'
  ) returning id,public_id into v_submission_id,v_submission_public_id;

  insert into public.linguistic_contribution_authorizations(
    submission_id,contributor_id,authorization_version,status,internal_review_allowed,
    app_ui_publication_allowed,derivative_formatting_allowed,commercial_use_allowed,public_attribution_allowed,
    marketing_allowed,research_sharing_allowed,third_party_sharing_allowed,ai_training_allowed,voice_modeling_allowed,
    public_audio_allowed,cultural_archive_allowed,archive_access_level,attribution_preference,license_type,geographic_scope
  ) values (
    v_submission_id,v_contributor_id,1,'GRANTED',true,
    false,false,false,false,false,false,false,false,false,false,false,'DO_NOT_ARCHIVE','ANONYMOUS','INTERNAL_REVIEW_ONLY','TU_COMUNIDAD_INTERNAL_REVIEW'
  );

  update public.linguistic_task_assignments set status='SUBMITTED',completed_at=now(),updated_at=now() where id=v_assignment_id;
  update public.linguistic_tasks set status='IN_REVIEW',updated_at=now() where id=v_task_id and status in ('OPEN','ASSIGNED','READY');

  insert into public.linguistic_work_events(entity_type,entity_id,event_type,actor_person_id,payload)
  values('SUBMISSION',v_submission_id,'SUBMITTED',v_person_id,jsonb_build_object('assignment_public_id',p_assignment_public_id,'version',v_version));

  return jsonb_build_object('success',true,'submission_public_id',v_submission_public_id,'version',v_version,'publication_authorized',false);
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
  ) returning public_id into v_auth_public_id;

  insert into public.linguistic_work_events(entity_type,entity_id,event_type,actor_person_id,payload)
  values('AUTHORIZATION',v_submission_id,'AUTHORIZATION_VERSION_GRANTED',v_person_id,jsonb_build_object('authorization_public_id',v_auth_public_id,'version',v_version));

  return jsonb_build_object('success',true,'authorization_public_id',v_auth_public_id,'version',v_version);
end;
$$;

create or replace function public.tc_revoke_linguistic_authorization(p_authorization_public_id text,p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_person_id uuid;
  v_auth_id uuid;
begin
  select p.id into v_person_id from public.persons p where p.auth_user_id=auth.uid();
  if v_person_id is null then raise exception 'Authenticated person profile required'; end if;

  select au.id into v_auth_id
    from public.linguistic_contribution_authorizations au
    join public.linguistic_contributors c on c.id=au.contributor_id
    join public.persons p on p.id=c.person_id
   where au.public_id=p_authorization_public_id and p.auth_user_id=auth.uid()
   for update of au;
  if v_auth_id is null then raise exception 'Authorization not found'; end if;

  update public.linguistic_contribution_authorizations
     set status='REVOKED',revoked_at=now(),revocation_reason=nullif(btrim(coalesce(p_reason,'')),''),updated_at=now()
   where id=v_auth_id and status='GRANTED';

  insert into public.linguistic_work_events(entity_type,entity_id,event_type,actor_person_id,payload)
  values('AUTHORIZATION',v_auth_id,'REVOKED',v_person_id,jsonb_build_object('reason',p_reason));

  return jsonb_build_object('success',true,'authorization_public_id',p_authorization_public_id,'status','REVOKED');
end;
$$;

create or replace function public.tc_withdraw_linguistic_application(p_application_public_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_person_id uuid;
  v_application_id uuid;
begin
  select p.id into v_person_id from public.persons p where p.auth_user_id=auth.uid();
  if v_person_id is null then raise exception 'Authenticated person profile required'; end if;

  select a.id into v_application_id
    from public.linguistic_job_applications a
    join public.linguistic_contributors c on c.id=a.contributor_id
    join public.persons p on p.id=c.person_id
   where a.public_id=p_application_public_id and p.auth_user_id=auth.uid()
   for update of a;
  if v_application_id is null then raise exception 'Application not found'; end if;

  update public.linguistic_job_applications set status='WITHDRAWN',updated_at=now() where id=v_application_id;
  insert into public.linguistic_work_events(entity_type,entity_id,event_type,actor_person_id,payload)
  values('APPLICATION',v_application_id,'WITHDRAWN',v_person_id,'{}'::jsonb);
  return jsonb_build_object('success',true,'application_public_id',p_application_public_id,'status','WITHDRAWN');
end;
$$;

revoke all on function public.tc_list_my_linguistic_assignments() from public;
revoke all on function public.tc_accept_linguistic_assignment(text) from public;
revoke all on function public.tc_submit_linguistic_text_task(text,text,text,boolean,text,jsonb,text) from public;
revoke all on function public.tc_authorize_linguistic_submission_use(text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,text,text,text,text,text) from public;
revoke all on function public.tc_revoke_linguistic_authorization(text,text) from public;
revoke all on function public.tc_withdraw_linguistic_application(text) from public;

grant execute on function public.tc_list_my_linguistic_assignments() to authenticated;
grant execute on function public.tc_accept_linguistic_assignment(text) to authenticated;
grant execute on function public.tc_submit_linguistic_text_task(text,text,text,boolean,text,jsonb,text) to authenticated;
grant execute on function public.tc_authorize_linguistic_submission_use(text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,text,text,text,text,text) to authenticated;
grant execute on function public.tc_revoke_linguistic_authorization(text,text) to authenticated;
grant execute on function public.tc_withdraw_linguistic_application(text) to authenticated;

commit;
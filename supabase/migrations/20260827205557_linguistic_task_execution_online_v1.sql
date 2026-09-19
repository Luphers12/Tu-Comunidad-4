begin;

alter table public.linguistic_task_assignments
  add column if not exists response_note text,
  add column if not exists responded_at timestamptz;

insert into public.tc_feature_gates(
  feature_key,domain,display_name,source_status,backend_status,safety_status,legal_status,cultural_status,approval_status,is_enabled,notes
)
values(
  'linguistics.task_execution','LINGUISTICS','Ejecución online de tareas lingüísticas','NOT_REQUIRED','VERIFIED','PENDING','PENDING','PENDING','PENDING',false,
  'Aceptar/rechazar, enviar y corregir tareas lingüísticas. Requiere conexión activa; no permite cola ni sincronización offline.'
)
on conflict (feature_key) do update set
  backend_status='VERIFIED',
  is_enabled=false,
  updated_at=now();

create or replace function public.tc_respond_to_my_linguistic_assignment(
  p_assignment_public_id text,
  p_action text,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_person_id uuid;
  v_assignment_id uuid;
  v_status text;
  v_task_id uuid;
  v_action text := upper(btrim(coalesce(p_action,'')));
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.tc_is_feature_enabled('linguistics.work_program') then raise exception 'LINGUISTICS_WORK_PROGRAM_DISABLED'; end if;
  if not public.tc_is_feature_enabled('linguistics.task_execution') then raise exception 'LINGUISTIC_TASK_EXECUTION_DISABLED'; end if;
  if v_action not in ('ACCEPT','DECLINE') then raise exception 'INVALID_ACTION'; end if;

  select p.id,a.id,a.status,a.task_id
    into v_person_id,v_assignment_id,v_status,v_task_id
  from public.persons p
  join public.linguistic_contributors c on c.person_id=p.id and c.is_active=true
  join public.linguistic_task_assignments a on a.contributor_id=c.id
  where p.auth_user_id=auth.uid()
    and a.public_id=p_assignment_public_id
  for update of a;

  if v_assignment_id is null then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
  if v_status <> 'ASSIGNED' then raise exception 'ASSIGNMENT_ALREADY_RESPONDED'; end if;

  if v_action='ACCEPT' then
    update public.linguistic_task_assignments
       set status='ACCEPTED',accepted_at=now(),responded_at=now(),response_note=nullif(btrim(coalesce(p_note,'')),'')
     where id=v_assignment_id;

    update public.linguistic_tasks
       set status='ASSIGNED',updated_at=now()
     where id=v_task_id and status in ('OPEN','READY');
  else
    update public.linguistic_task_assignments
       set status='REJECTED',responded_at=now(),response_note=nullif(btrim(coalesce(p_note,'')),'')
     where id=v_assignment_id;
  end if;

  insert into public.linguistic_work_events(entity_type,entity_id,event_type,actor_person_id,payload)
  values('ASSIGNMENT',v_assignment_id,
         case when v_action='ACCEPT' then 'ASSIGNMENT_ACCEPTED' else 'ASSIGNMENT_DECLINED' end,
         v_person_id,jsonb_build_object('assignment_public_id',p_assignment_public_id,'note',nullif(btrim(coalesce(p_note,'')),'')));

  return jsonb_build_object('success',true,'assignment_public_id',p_assignment_public_id,'status',case when v_action='ACCEPT' then 'ACCEPTED' else 'REJECTED' end);
end;
$$;

revoke all on function public.tc_respond_to_my_linguistic_assignment(text,text,text) from public, anon;
grant execute on function public.tc_respond_to_my_linguistic_assignment(text,text,text) to authenticated;

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
set search_path to 'public'
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
  v_parent_submission_id uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.tc_is_feature_enabled('linguistics.work_program') then raise exception 'LINGUISTICS_WORK_PROGRAM_DISABLED'; end if;
  if not public.tc_is_feature_enabled('linguistics.task_execution') then raise exception 'LINGUISTIC_TASK_EXECUTION_DISABLED'; end if;
  if p_submitted_text is null or btrim(p_submitted_text)='' then raise exception 'SUBMITTED_TEXT_REQUIRED'; end if;
  if jsonb_typeof(coalesce(p_sources_consulted,'[]'::jsonb)) <> 'array' then raise exception 'SOURCES_MUST_BE_ARRAY'; end if;

  select p.id into v_person_id from public.persons p where p.auth_user_id=auth.uid();
  if v_person_id is null then raise exception 'AUTHENTICATED_PERSON_REQUIRED'; end if;

  select c.id,a.id,a.status,a.task_id,t.task_type,t.status,t.allow_ai_assistance,t.requires_ai_disclosure,j.status
    into v_contributor_id,v_assignment_id,v_assignment_status,v_task_id,v_task_type,v_task_status,v_allow_ai,v_requires_ai_disclosure,v_job_status
    from public.linguistic_task_assignments a
    join public.linguistic_contributors c on c.id=a.contributor_id
    join public.persons p on p.id=c.person_id
    join public.linguistic_tasks t on t.id=a.task_id
    join public.linguistic_jobs j on j.id=t.job_id
   where a.public_id=p_assignment_public_id and p.auth_user_id=auth.uid()
   for update of a;

  if v_assignment_id is null then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
  if v_job_status <> 'OPEN' then raise exception 'JOB_NOT_OPEN'; end if;
  if v_assignment_status not in ('ACCEPTED','CHANGES_REQUESTED') then raise exception 'ASSIGNMENT_NOT_READY_FOR_SUBMISSION'; end if;
  if v_task_status in ('APPROVED','ARCHIVED','PAUSED') then raise exception 'TASK_NOT_ACCEPTING_SUBMISSIONS'; end if;
  if v_task_type not in ('TRANSLATE_UI','TRANSCRIBE','TERMINOLOGY','CULTURAL_VALIDATE') then raise exception 'TEXT_RPC_NOT_ALLOWED_FOR_TASK_TYPE'; end if;
  if p_ai_assistance_disclosed and not v_allow_ai then raise exception 'AI_ASSISTANCE_NOT_ALLOWED'; end if;
  if p_ai_assistance_disclosed and v_requires_ai_disclosure and (p_ai_assistance_details is null or btrim(p_ai_assistance_details)='') then
    raise exception 'AI_ASSISTANCE_DETAILS_REQUIRED';
  end if;

  select coalesce(max(version),0)+1,
         (array_agg(id order by version desc))[1]
    into v_version,v_parent_submission_id
    from public.linguistic_task_submissions
   where assignment_id=v_assignment_id;

  if v_assignment_status='ACCEPTED' and v_version<>1 then
    raise exception 'UNEXPECTED_EXISTING_SUBMISSION';
  end if;
  if v_assignment_status='CHANGES_REQUESTED' and v_parent_submission_id is null then
    raise exception 'PARENT_SUBMISSION_REQUIRED';
  end if;

  insert into public.linguistic_task_submissions(
    assignment_id,version,parent_submission_id,submitted_text,variant_usage_note,ai_assistance_disclosed,ai_assistance_details,
    sources_consulted,contributor_note,status
  ) values (
    v_assignment_id,v_version,case when v_version>1 then v_parent_submission_id else null end,btrim(p_submitted_text),
    nullif(btrim(coalesce(p_variant_usage_note,'')),''),p_ai_assistance_disclosed,
    nullif(btrim(coalesce(p_ai_assistance_details,'')),''),coalesce(p_sources_consulted,'[]'::jsonb),
    nullif(btrim(coalesce(p_contributor_note,'')),''),'SUBMITTED'
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

  update public.linguistic_task_assignments
     set status='SUBMITTED',completed_at=now(),updated_at=now()
   where id=v_assignment_id;

  update public.linguistic_tasks
     set status='IN_REVIEW',updated_at=now()
   where id=v_task_id and status in ('OPEN','ASSIGNED','READY','IN_REVIEW');

  insert into public.linguistic_work_events(entity_type,entity_id,event_type,actor_person_id,payload)
  values('SUBMISSION',v_submission_id,'SUBMITTED',v_person_id,
         jsonb_build_object('assignment_public_id',p_assignment_public_id,'version',v_version,'parent_submission_id',v_parent_submission_id));

  return jsonb_build_object('success',true,'submission_public_id',v_submission_public_id,'version',v_version,'parent_submission_id',v_parent_submission_id,'publication_authorized',false);
end;
$$;

revoke all on function public.tc_submit_linguistic_text_task(text,text,text,boolean,text,jsonb,text) from public, anon;
grant execute on function public.tc_submit_linguistic_text_task(text,text,text,boolean,text,jsonb,text) to authenticated;

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
set search_path to ''
as $$
declare
  v_person uuid;
  v_contributor uuid;
  v_submission uuid;
  v_task uuid;
  v_author_assignment uuid;
  v_context text;
  v_review_id uuid;
  v_public_id text;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.tc_is_feature_enabled('linguistics.work_program') then raise exception 'LINGUISTICS_WORK_PROGRAM_DISABLED'; end if;
  if not public.tc_is_feature_enabled('linguistics.task_execution') then raise exception 'LINGUISTIC_TASK_EXECUTION_DISABLED'; end if;
  if p_verdict not in ('APPROVE','APPROVE_VARIANT','CHANGES_REQUIRED','NEEDS_CONTEXT','CONFLICT','REJECT') then raise exception 'INVALID_REVIEW_VERDICT'; end if;

  select p.id,c.id into v_person,v_contributor
  from public.persons p join public.linguistic_contributors c on c.person_id=p.id and c.is_active=true
  where p.auth_user_id=auth.uid();
  if v_contributor is null then raise exception 'LINGUISTIC_CONTRIBUTOR_REQUIRED'; end if;

  select s.id,a.task_id,a.id into v_submission,v_task,v_author_assignment
  from public.linguistic_task_submissions s
  join public.linguistic_task_assignments a on a.id=s.assignment_id
  where s.public_id=p_submission_public_id;
  if v_submission is null then raise exception 'SUBMISSION_NOT_FOUND'; end if;

  v_context := public.tc_linguistic_effective_task_context(v_task);

  insert into public.linguistic_submission_reviews(
    submission_id,reviewer_contributor_id,review_role_code,context_name,verdict,observation,
    independent_attested,conflict_of_interest_declared,conflict_note
  ) values(
    v_submission,v_contributor,p_review_role_code,v_context,p_verdict,nullif(btrim(coalesce(p_observation,'')),''),
    p_independent_attested,p_conflict_of_interest_declared,nullif(btrim(coalesce(p_conflict_note,'')),'')
  ) returning id,public_id into v_review_id,v_public_id;

  update public.linguistic_task_assignments
     set status='SUBMITTED',completed_at=now(),updated_at=now()
   where task_id=v_task and contributor_id=v_contributor and assignment_role=p_review_role_code
     and status in ('ACCEPTED','CHANGES_REQUESTED');

  if p_verdict='CHANGES_REQUIRED' then
    update public.linguistic_task_assignments
       set status='CHANGES_REQUESTED',completed_at=null,updated_at=now()
     where id=v_author_assignment and status='SUBMITTED';
    update public.linguistic_task_submissions
       set status='CHANGES_REQUESTED',reviewed_at=now(),updated_at=now()
     where id=v_submission and status in ('SUBMITTED','IN_REVIEW');
  elsif p_verdict='REJECT' then
    update public.linguistic_task_assignments
       set status='REJECTED',updated_at=now()
     where id=v_author_assignment and status='SUBMITTED';
    update public.linguistic_task_submissions
       set status='REJECTED',reviewed_at=now(),updated_at=now()
     where id=v_submission and status in ('SUBMITTED','IN_REVIEW');
  else
    update public.linguistic_task_submissions
       set status='IN_REVIEW',reviewed_at=now(),updated_at=now()
     where id=v_submission and status='SUBMITTED';
  end if;

  insert into public.linguistic_work_events(entity_type,entity_id,event_type,actor_person_id,payload)
  values('SUBMISSION',v_submission,'REVIEW_SUBMITTED',v_person,
         jsonb_build_object('review_public_id',v_public_id,'role',p_review_role_code,'verdict',p_verdict,'context',v_context));

  return jsonb_build_object('success',true,'review_public_id',v_public_id,'readiness',public.tc_linguistic_submission_readiness(v_submission));
end;
$$;

revoke all on function public.tc_submit_linguistic_submission_review(text,text,text,text,boolean,boolean,text) from public, anon;
grant execute on function public.tc_submit_linguistic_submission_review(text,text,text,text,boolean,boolean,text) to authenticated;

commit;
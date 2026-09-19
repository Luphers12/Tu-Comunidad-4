-- TU COMUNIDAD: harden affiliation lifecycle, keep applicant actions separate from human activation.

insert into public.capabilities(name)
values ('affiliation.review'), ('affiliation.approve')
on conflict (name) do nothing;

-- Prevent race-created duplicate live applications for the same person + role.
create unique index if not exists affiliation_one_live_application_per_role
on public.affiliation_applications(person_id, requested_role_code)
where state in ('DRAFT','SUBMITTED','UNDER_REVIEW','CHANGES_REQUESTED');

-- Append-only history for affiliation review/event records.
create or replace function public.tc_block_affiliation_history_mutation()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  raise exception 'AFFILIATION_HISTORY_APPEND_ONLY' using errcode='P0001';
end;
$function$;

revoke all on function public.tc_block_affiliation_history_mutation() from public, anon, authenticated;

drop trigger if exists trg_affiliation_events_append_only on public.affiliation_events;
create trigger trg_affiliation_events_append_only
before update or delete on public.affiliation_events
for each row execute function public.tc_block_affiliation_history_mutation();

drop trigger if exists trg_affiliation_reviews_append_only on public.affiliation_reviews;
create trigger trg_affiliation_reviews_append_only
before update or delete on public.affiliation_reviews
for each row execute function public.tc_block_affiliation_history_mutation();

create or replace function public.tc_start_affiliation(
  p_requested_role_code text,
  p_community_id uuid default null,
  p_operational_location_id uuid default null,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_person uuid;
  v_role text;
  v_app_id uuid;
  v_public_id text;
  v_op_purpose text;
begin
  if auth.uid() is null then raise exception 'TC_UNAUTHENTICATED' using errcode='P0001'; end if;
  v_person := public.current_user_person_id();
  if v_person is null then raise exception 'PERSON_REQUIRED' using errcode='P0001'; end if;

  v_role := upper(btrim(coalesce(p_requested_role_code,'')));
  if v_role not in ('TIE','VEN','CON','RSG','PTC') then
    raise exception 'AFFILIATION_ROLE_INVALID' using errcode='P0001';
  end if;

  -- Community is part of the application itself, not an arbitrary free-form payload.
  if p_community_id is null or not exists(
    select 1 from public.communities where id=p_community_id and is_active
  ) then
    raise exception 'COMMUNITY_REQUIRED' using errcode='P0001';
  end if;

  if p_operational_location_id is not null then
    select purpose into v_op_purpose
    from public.operational_locations
    where id=p_operational_location_id and created_by_person_id=v_person and active;
    if v_op_purpose is null then
      raise exception 'OPERATIONAL_LOCATION_NOT_ALLOWED' using errcode='P0001';
    end if;
    if v_role='TIE' and v_op_purpose <> 'STORE_PICKUP' then
      raise exception 'STORE_PICKUP_LOCATION_REQUIRED' using errcode='P0001';
    end if;
    if v_role='PTC' and v_op_purpose <> 'PTC_PICKUP' then
      raise exception 'PTC_PICKUP_LOCATION_REQUIRED' using errcode='P0001';
    end if;
  end if;

  select id,public_id into v_app_id,v_public_id
  from public.affiliation_applications
  where person_id=v_person and requested_role_code=v_role
    and state in ('DRAFT','SUBMITTED','UNDER_REVIEW','CHANGES_REQUESTED')
  order by created_at desc limit 1;

  if v_app_id is not null then
    return jsonb_build_object(
      'application_public_id',v_public_id,
      'state',(select state from public.affiliation_applications where id=v_app_id),
      'already_exists',true
    );
  end if;

  insert into public.affiliation_applications(
    person_id,requested_role_code,community_id,operational_location_id,applicant_note
  ) values(
    v_person,v_role,p_community_id,p_operational_location_id,
    nullif(btrim(coalesce(p_note,'')),'')
  ) returning id,public_id into v_app_id,v_public_id;

  insert into public.affiliation_application_requirements(application_id,requirement_code,required)
  select v_app_id,x.code,x.required
  from (values
    ('IDENTITY',true),
    ('COMMUNITY',true),
    ('TERMS',true)
  ) as x(code,required);

  if v_role='TIE' then
    insert into public.affiliation_application_requirements(application_id,requirement_code,required) values
      (v_app_id,'STORE_INFO',true),(v_app_id,'OPERATIONAL_LOCATION',true),(v_app_id,'CONTACT_METHOD',true);
  elsif v_role='VEN' then
    insert into public.affiliation_application_requirements(application_id,requirement_code,required) values
      (v_app_id,'SELLER_INFO',true),(v_app_id,'CONTACT_METHOD',true);
  elsif v_role='CON' then
    insert into public.affiliation_application_requirements(application_id,requirement_code,required) values
      (v_app_id,'LICENSE_OR_PERMIT',true),(v_app_id,'VEHICLE',true),(v_app_id,'SERVICE_AREA',true);
  elsif v_role='RSG' then
    insert into public.affiliation_application_requirements(application_id,requirement_code,required) values
      (v_app_id,'SERVICE_AREA',true),(v_app_id,'CONTACT_METHOD',true);
  elsif v_role='PTC' then
    insert into public.affiliation_application_requirements(application_id,requirement_code,required) values
      (v_app_id,'OPERATIONAL_LOCATION',true),(v_app_id,'CONTACT_METHOD',true);
  end if;

  update public.affiliation_application_requirements
     set status='PROVIDED',
         applicant_payload=jsonb_build_object('community_id',p_community_id),
         provided_at=now(),updated_at=now()
   where application_id=v_app_id and requirement_code='COMMUNITY';

  if p_operational_location_id is not null then
    update public.affiliation_application_requirements
       set status='PROVIDED',
           applicant_payload=jsonb_build_object('operational_location_id',p_operational_location_id),
           provided_at=now(),updated_at=now()
     where application_id=v_app_id and requirement_code='OPERATIONAL_LOCATION';
  end if;

  insert into public.affiliation_events(
    application_id,actor_person_id,event_type,from_state,to_state,payload
  ) values(
    v_app_id,v_person,'APPLICATION_STARTED',null,'DRAFT',
    jsonb_build_object('requested_role_code',v_role,'community_id',p_community_id)
  );

  return jsonb_build_object('application_public_id',v_public_id,'state','DRAFT','already_exists',false);
end;
$function$;

create or replace function public.tc_update_affiliation_context(
  p_application_public_id text,
  p_community_id uuid,
  p_operational_location_id uuid default null,
  p_note text default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_person uuid;
  v_app_id uuid;
  v_role text;
  v_state text;
  v_op_purpose text;
begin
  if auth.uid() is null then raise exception 'TC_UNAUTHENTICATED' using errcode='P0001'; end if;
  v_person := public.current_user_person_id();

  select id,requested_role_code,state into v_app_id,v_role,v_state
  from public.affiliation_applications
  where public_id=upper(btrim(p_application_public_id)) and person_id=v_person
  for update;

  if v_app_id is null then raise exception 'AFFILIATION_NOT_FOUND' using errcode='P0001'; end if;
  if v_state not in ('DRAFT','CHANGES_REQUESTED') then raise exception 'AFFILIATION_NOT_EDITABLE' using errcode='P0001'; end if;
  if p_community_id is null or not exists(select 1 from public.communities where id=p_community_id and is_active) then
    raise exception 'COMMUNITY_REQUIRED' using errcode='P0001';
  end if;

  if p_operational_location_id is not null then
    select purpose into v_op_purpose from public.operational_locations
    where id=p_operational_location_id and created_by_person_id=v_person and active;
    if v_op_purpose is null then raise exception 'OPERATIONAL_LOCATION_NOT_ALLOWED' using errcode='P0001'; end if;
    if v_role='TIE' and v_op_purpose <> 'STORE_PICKUP' then raise exception 'STORE_PICKUP_LOCATION_REQUIRED' using errcode='P0001'; end if;
    if v_role='PTC' and v_op_purpose <> 'PTC_PICKUP' then raise exception 'PTC_PICKUP_LOCATION_REQUIRED' using errcode='P0001'; end if;
  end if;

  update public.affiliation_applications
     set community_id=p_community_id,
         operational_location_id=p_operational_location_id,
         applicant_note=coalesce(nullif(btrim(coalesce(p_note,'')),''),applicant_note),
         updated_at=now(),version=version+1
   where id=v_app_id;

  update public.affiliation_application_requirements
     set status='PROVIDED',applicant_payload=jsonb_build_object('community_id',p_community_id),provided_at=now(),updated_at=now()
   where application_id=v_app_id and requirement_code='COMMUNITY';

  if exists(select 1 from public.affiliation_application_requirements where application_id=v_app_id and requirement_code='OPERATIONAL_LOCATION') then
    if p_operational_location_id is null then
      update public.affiliation_application_requirements
         set status='PENDING',applicant_payload='{}'::jsonb,provided_at=null,verified_at=null,updated_at=now()
       where application_id=v_app_id and requirement_code='OPERATIONAL_LOCATION';
    else
      update public.affiliation_application_requirements
         set status='PROVIDED',applicant_payload=jsonb_build_object('operational_location_id',p_operational_location_id),provided_at=now(),verified_at=null,updated_at=now()
       where application_id=v_app_id and requirement_code='OPERATIONAL_LOCATION';
    end if;
  end if;

  insert into public.affiliation_events(application_id,actor_person_id,event_type,from_state,to_state,payload)
  values(v_app_id,v_person,'APPLICATION_CONTEXT_UPDATED',v_state,v_state,
         jsonb_build_object('community_id',p_community_id,'operational_location_id',p_operational_location_id));

  return true;
end;
$function$;

create or replace function public.tc_provide_affiliation_requirement(
  p_application_public_id text,
  p_requirement_code text,
  p_payload jsonb default '{}'::jsonb
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_person uuid;
  v_app_id uuid;
  v_state text;
  v_code text;
  v_updated int;
begin
  if auth.uid() is null then raise exception 'TC_UNAUTHENTICATED' using errcode='P0001'; end if;
  v_person := public.current_user_person_id();
  v_code := upper(btrim(coalesce(p_requirement_code,'')));

  if v_code in ('COMMUNITY','OPERATIONAL_LOCATION') then
    raise exception 'AFFILIATION_CONTEXT_REQUIREMENT_USE_CONTEXT_RPC' using errcode='P0001';
  end if;

  select id,state into v_app_id,v_state from public.affiliation_applications
  where public_id=upper(btrim(p_application_public_id)) and person_id=v_person;
  if v_app_id is null then raise exception 'AFFILIATION_NOT_FOUND' using errcode='P0001'; end if;
  if v_state not in ('DRAFT','CHANGES_REQUESTED') then raise exception 'AFFILIATION_NOT_EDITABLE' using errcode='P0001'; end if;

  update public.affiliation_application_requirements
     set status='PROVIDED',applicant_payload=coalesce(p_payload,'{}'::jsonb),provided_at=now(),verified_at=null,reviewer_note=null,updated_at=now()
   where application_id=v_app_id and requirement_code=v_code;
  get diagnostics v_updated=row_count;
  if v_updated<>1 then raise exception 'AFFILIATION_REQUIREMENT_NOT_FOUND' using errcode='P0001'; end if;

  insert into public.affiliation_events(application_id,actor_person_id,event_type,from_state,to_state,payload)
  values(v_app_id,v_person,'REQUIREMENT_PROVIDED',v_state,v_state,jsonb_build_object('requirement_code',v_code));

  return true;
end;
$function$;

create or replace function public.tc_submit_affiliation_application(p_application_public_id text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_person uuid;
  v_app_id uuid;
  v_state text;
  v_role text;
  v_community uuid;
  v_op uuid;
  v_op_purpose text;
begin
  if auth.uid() is null then raise exception 'TC_UNAUTHENTICATED' using errcode='P0001'; end if;
  v_person := public.current_user_person_id();

  select id,state,requested_role_code,community_id,operational_location_id
    into v_app_id,v_state,v_role,v_community,v_op
  from public.affiliation_applications
  where public_id=upper(btrim(p_application_public_id)) and person_id=v_person
  for update;

  if v_app_id is null then raise exception 'AFFILIATION_NOT_FOUND' using errcode='P0001'; end if;
  if v_state not in ('DRAFT','CHANGES_REQUESTED') then raise exception 'AFFILIATION_NOT_SUBMITTABLE' using errcode='P0001'; end if;
  if v_community is null or not exists(select 1 from public.communities where id=v_community and is_active) then
    raise exception 'COMMUNITY_REQUIRED' using errcode='P0001';
  end if;

  if v_role in ('TIE','PTC') then
    select purpose into v_op_purpose from public.operational_locations
    where id=v_op and created_by_person_id=v_person and active;
    if v_op_purpose is null then raise exception 'OPERATIONAL_LOCATION_REQUIRED' using errcode='P0001'; end if;
    if v_role='TIE' and v_op_purpose <> 'STORE_PICKUP' then raise exception 'STORE_PICKUP_LOCATION_REQUIRED' using errcode='P0001'; end if;
    if v_role='PTC' and v_op_purpose <> 'PTC_PICKUP' then raise exception 'PTC_PICKUP_LOCATION_REQUIRED' using errcode='P0001'; end if;
  end if;

  if exists(
    select 1 from public.affiliation_application_requirements
    where application_id=v_app_id and required and status not in ('PROVIDED','VERIFIED','WAIVED')
  ) then
    raise exception 'AFFILIATION_REQUIREMENTS_INCOMPLETE' using errcode='P0001';
  end if;

  update public.affiliation_applications
     set state='SUBMITTED',submitted_at=now(),resolved_at=null,updated_at=now(),version=version+1
   where id=v_app_id;

  insert into public.affiliation_events(application_id,actor_person_id,event_type,from_state,to_state,payload)
  values(v_app_id,v_person,'APPLICATION_SUBMITTED',v_state,'SUBMITTED','{}'::jsonb);

  return true;
end;
$function$;

create or replace function public.tc_withdraw_affiliation_application(p_application_public_id text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_person uuid;
  v_app_id uuid;
  v_state text;
begin
  if auth.uid() is null then raise exception 'TC_UNAUTHENTICATED' using errcode='P0001'; end if;
  v_person := public.current_user_person_id();

  select id,state into v_app_id,v_state
  from public.affiliation_applications
  where public_id=upper(btrim(p_application_public_id)) and person_id=v_person
  for update;

  if v_app_id is null or v_state not in ('DRAFT','SUBMITTED','CHANGES_REQUESTED') then
    raise exception 'AFFILIATION_NOT_WITHDRAWABLE' using errcode='P0001';
  end if;

  update public.affiliation_applications
     set state='WITHDRAWN',resolved_at=now(),updated_at=now(),version=version+1
   where id=v_app_id;

  insert into public.affiliation_events(application_id,actor_person_id,event_type,from_state,to_state,payload)
  values(v_app_id,v_person,'APPLICATION_WITHDRAWN',v_state,'WITHDRAWN','{}'::jsonb);

  return true;
end;
$function$;

-- Reviewer queue: only applications within a capability scope are visible.
create or replace function public.tc_affiliation_review_queue(
  p_state text default null,
  p_limit integer default 50
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $function$
  select coalesce(jsonb_agg(x.payload order by x.created_at),'[]'::jsonb)
  from (
    select a.created_at,
      jsonb_build_object(
        'application_public_id',a.public_id,
        'person_public_id',per.public_id,
        'requested_role_code',a.requested_role_code,
        'state',a.state,
        'community_id',a.community_id,
        'community_name',c.name,
        'operational_location_id',a.operational_location_id,
        'operational_location_name',ol.name,
        'operational_location_purpose',ol.purpose,
        'submitted_at',a.submitted_at,
        'created_at',a.created_at,
        'requirements',(
          select coalesce(jsonb_agg(jsonb_build_object(
            'code',r.requirement_code,
            'required',r.required,
            'status',r.status,
            'payload',r.applicant_payload,
            'reviewer_note',r.reviewer_note
          ) order by r.requirement_code),'[]'::jsonb)
          from public.affiliation_application_requirements r
          where r.application_id=a.id
        )
      ) as payload
    from public.affiliation_applications a
    join public.persons per on per.id=a.person_id
    left join public.communities c on c.id=a.community_id
    left join public.operational_locations ol on ol.id=a.operational_location_id
    where auth.uid() is not null
      and a.state in ('SUBMITTED','UNDER_REVIEW','CHANGES_REQUESTED')
      and (p_state is null or a.state=upper(btrim(p_state)))
      and exists(
        select 1
        from public.current_user_profile_ids() cp
        where public.internal_has_capability(cp.profile_id,'affiliation.review','COMMUNITY',a.community_id)
           or public.internal_has_capability(cp.profile_id,'affiliation.approve','COMMUNITY',a.community_id)
      )
    order by a.created_at
    limit greatest(1,least(coalesce(p_limit,50),100))
  ) x;
$function$;

create or replace function public.tc_review_affiliation_requirement(
  p_application_public_id text,
  p_requirement_code text,
  p_decision text,
  p_note text default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_app_id uuid;
  v_community uuid;
  v_state text;
  v_reviewer uuid;
  v_decision text;
  v_code text;
begin
  if auth.uid() is null then raise exception 'TC_UNAUTHENTICATED' using errcode='P0001'; end if;
  v_decision := upper(btrim(coalesce(p_decision,'')));
  v_code := upper(btrim(coalesce(p_requirement_code,'')));
  if v_decision not in ('VERIFIED','REJECTED','WAIVED') then raise exception 'AFFILIATION_REQUIREMENT_DECISION_INVALID' using errcode='P0001'; end if;

  select id,community_id,state into v_app_id,v_community,v_state
  from public.affiliation_applications
  where public_id=upper(btrim(p_application_public_id))
  for update;
  if v_app_id is null then raise exception 'AFFILIATION_NOT_FOUND' using errcode='P0001'; end if;
  if v_state not in ('SUBMITTED','UNDER_REVIEW') then raise exception 'AFFILIATION_NOT_REVIEWABLE' using errcode='P0001'; end if;

  select cp.profile_id into v_reviewer
  from public.current_user_profile_ids() cp
  where public.internal_has_capability(cp.profile_id,'affiliation.review','COMMUNITY',v_community)
     or public.internal_has_capability(cp.profile_id,'affiliation.approve','COMMUNITY',v_community)
  order by case when cp.profile_type='ADM' then 0 when cp.profile_type='SOP' then 1 else 2 end
  limit 1;
  if v_reviewer is null then raise exception 'AFFILIATION_REVIEW_FORBIDDEN' using errcode='P0001'; end if;

  if not exists(select 1 from public.affiliation_application_requirements where application_id=v_app_id and requirement_code=v_code) then
    raise exception 'AFFILIATION_REQUIREMENT_NOT_FOUND' using errcode='P0001';
  end if;

  update public.affiliation_application_requirements
     set status=v_decision,
         reviewer_note=nullif(btrim(coalesce(p_note,'')),''),
         verified_at=case when v_decision in ('VERIFIED','WAIVED') then now() else null end,
         updated_at=now()
   where application_id=v_app_id and requirement_code=v_code;

  if v_state='SUBMITTED' then
    update public.affiliation_applications set state='UNDER_REVIEW',updated_at=now(),version=version+1 where id=v_app_id;
    insert into public.affiliation_events(application_id,actor_profile_id,event_type,from_state,to_state,payload)
    values(v_app_id,v_reviewer,'REVIEW_STARTED','SUBMITTED','UNDER_REVIEW','{}'::jsonb);
    v_state := 'UNDER_REVIEW';
  end if;

  insert into public.affiliation_events(application_id,actor_profile_id,event_type,from_state,to_state,payload)
  values(v_app_id,v_reviewer,'REQUIREMENT_REVIEWED',v_state,v_state,
         jsonb_build_object('requirement_code',v_code,'decision',v_decision,'note',nullif(btrim(coalesce(p_note,'')),'')));

  if v_decision='REJECTED' then
    update public.affiliation_applications set state='CHANGES_REQUESTED',updated_at=now(),version=version+1 where id=v_app_id;
    insert into public.affiliation_events(application_id,actor_profile_id,event_type,from_state,to_state,payload)
    values(v_app_id,v_reviewer,'CHANGES_REQUESTED',v_state,'CHANGES_REQUESTED',jsonb_build_object('requirement_code',v_code));
  end if;

  return true;
end;
$function$;

create or replace function public.tc_review_affiliation_application(
  p_application_public_id text,
  p_decision text,
  p_rationale text default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_app_id uuid;
  v_community uuid;
  v_state text;
  v_reviewer uuid;
  v_decision text;
  v_next text;
begin
  if auth.uid() is null then raise exception 'TC_UNAUTHENTICATED' using errcode='P0001'; end if;
  v_decision := upper(btrim(coalesce(p_decision,'')));
  if v_decision not in ('REQUEST_CHANGES','RECOMMEND_APPROVAL','RECOMMEND_REJECTION') then
    raise exception 'AFFILIATION_REVIEW_DECISION_INVALID' using errcode='P0001';
  end if;

  select id,community_id,state into v_app_id,v_community,v_state
  from public.affiliation_applications
  where public_id=upper(btrim(p_application_public_id))
  for update;
  if v_app_id is null then raise exception 'AFFILIATION_NOT_FOUND' using errcode='P0001'; end if;
  if v_state not in ('SUBMITTED','UNDER_REVIEW') then raise exception 'AFFILIATION_NOT_REVIEWABLE' using errcode='P0001'; end if;

  select cp.profile_id into v_reviewer
  from public.current_user_profile_ids() cp
  where public.internal_has_capability(cp.profile_id,'affiliation.review','COMMUNITY',v_community)
     or public.internal_has_capability(cp.profile_id,'affiliation.approve','COMMUNITY',v_community)
  order by case when cp.profile_type='ADM' then 0 when cp.profile_type='SOP' then 1 else 2 end
  limit 1;
  if v_reviewer is null then raise exception 'AFFILIATION_REVIEW_FORBIDDEN' using errcode='P0001'; end if;

  v_next := case when v_decision='REQUEST_CHANGES' then 'CHANGES_REQUESTED' else 'UNDER_REVIEW' end;

  insert into public.affiliation_reviews(application_id,reviewer_profile_id,decision,rationale)
  values(v_app_id,v_reviewer,v_decision,nullif(btrim(coalesce(p_rationale,'')),''));

  update public.affiliation_applications set state=v_next,updated_at=now(),version=version+1 where id=v_app_id;

  insert into public.affiliation_events(application_id,actor_profile_id,event_type,from_state,to_state,payload)
  values(v_app_id,v_reviewer,'APPLICATION_REVIEWED',v_state,v_next,
         jsonb_build_object('decision',v_decision,'rationale',nullif(btrim(coalesce(p_rationale,'')),'')));

  return true;
end;
$function$;

create or replace function public.tc_finalize_affiliation_application(
  p_application_public_id text,
  p_decision text,
  p_rationale text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_app public.affiliation_applications%rowtype;
  v_approver uuid;
  v_decision text;
  v_profile_id uuid;
  v_profile_public_id text;
  v_territory text;
  v_existing_status text;
begin
  if auth.uid() is null then raise exception 'TC_UNAUTHENTICATED' using errcode='P0001'; end if;
  v_decision := upper(btrim(coalesce(p_decision,'')));
  if v_decision not in ('APPROVE','REJECT') then raise exception 'AFFILIATION_FINAL_DECISION_INVALID' using errcode='P0001'; end if;

  select * into v_app from public.affiliation_applications
  where public_id=upper(btrim(p_application_public_id))
  for update;
  if v_app.id is null then raise exception 'AFFILIATION_NOT_FOUND' using errcode='P0001'; end if;
  if v_app.state not in ('SUBMITTED','UNDER_REVIEW') then raise exception 'AFFILIATION_NOT_FINALIZABLE' using errcode='P0001'; end if;

  select cp.profile_id into v_approver
  from public.current_user_profile_ids() cp
  where public.internal_has_capability(cp.profile_id,'affiliation.approve','COMMUNITY',v_app.community_id)
  order by case when cp.profile_type='ADM' then 0 when cp.profile_type='SOP' then 1 else 2 end
  limit 1;
  if v_approver is null then raise exception 'AFFILIATION_APPROVAL_FORBIDDEN' using errcode='P0001'; end if;

  if v_decision='REJECT' then
    insert into public.affiliation_reviews(application_id,reviewer_profile_id,decision,rationale)
    values(v_app.id,v_approver,'REJECT',nullif(btrim(coalesce(p_rationale,'')),''));
    update public.affiliation_applications
       set state='REJECTED',resolved_at=now(),updated_at=now(),version=version+1
     where id=v_app.id;
    insert into public.affiliation_events(application_id,actor_profile_id,event_type,from_state,to_state,payload)
    values(v_app.id,v_approver,'APPLICATION_REJECTED',v_app.state,'REJECTED',jsonb_build_object('rationale',nullif(btrim(coalesce(p_rationale,'')),'')));
    return jsonb_build_object('application_public_id',v_app.public_id,'state','REJECTED','activated_profile_public_id',null);
  end if;

  if exists(
    select 1 from public.affiliation_application_requirements
    where application_id=v_app.id and required and status not in ('VERIFIED','WAIVED')
  ) then
    raise exception 'AFFILIATION_REQUIREMENTS_NOT_VERIFIED' using errcode='P0001';
  end if;

  select c.public_id into v_territory from public.communities c where c.id=v_app.community_id and c.is_active;
  if v_territory is null then raise exception 'COMMUNITY_REQUIRED' using errcode='P0001'; end if;

  select id,public_id,status::text into v_profile_id,v_profile_public_id,v_existing_status
  from public.profiles
  where person_id=v_app.person_id and profile_type=v_app.requested_role_code
  order by created_at desc limit 1
  for update;

  if v_profile_id is not null then
    if v_existing_status in ('restricted','suspended') then
      raise exception 'AFFILIATION_EXISTING_PROFILE_RESTRICTED' using errcode='P0001';
    end if;
    update public.profiles
       set status='active',territory_id=v_territory,updated_at=now()
     where id=v_profile_id
     returning public_id into v_profile_public_id;
  else
    v_profile_public_id := public.tc_generate_public_id(v_app.requested_role_code);
    insert into public.profiles(public_id,person_id,profile_type,status,territory_id)
    values(v_profile_public_id,v_app.person_id,v_app.requested_role_code,'active',v_territory)
    returning id into v_profile_id;
  end if;

  if v_app.operational_location_id is not null then
    update public.operational_locations
       set owner_profile_id=v_profile_id,verification_status='VERIFIED',updated_at=now()
     where id=v_app.operational_location_id and created_by_person_id=v_app.person_id;
  end if;

  insert into public.affiliation_reviews(application_id,reviewer_profile_id,decision,rationale)
  values(v_app.id,v_approver,'APPROVE',nullif(btrim(coalesce(p_rationale,'')),''));

  update public.affiliation_applications
     set state='APPROVED',activated_profile_id=v_profile_id,resolved_at=now(),updated_at=now(),version=version+1
   where id=v_app.id;

  insert into public.affiliation_events(application_id,actor_profile_id,event_type,from_state,to_state,payload)
  values(v_app.id,v_approver,'APPLICATION_APPROVED',v_app.state,'APPROVED',
         jsonb_build_object('activated_profile_public_id',v_profile_public_id,'rationale',nullif(btrim(coalesce(p_rationale,'')),'')));

  return jsonb_build_object('application_public_id',v_app.public_id,'state','APPROVED','activated_profile_public_id',v_profile_public_id);
end;
$function$;

create or replace function public.tc_my_affiliations()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $function$
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'application_public_id',a.public_id,
      'requested_role_code',a.requested_role_code,
      'state',a.state,
      'community_id',a.community_id,
      'operational_location_id',a.operational_location_id,
      'activated_profile_public_id',ap.public_id,
      'submitted_at',a.submitted_at,
      'resolved_at',a.resolved_at,
      'created_at',a.created_at,
      'requirements',(
        select coalesce(jsonb_agg(jsonb_build_object(
          'code',r.requirement_code,
          'required',r.required,
          'status',r.status,
          'payload',r.applicant_payload,
          'reviewer_note',r.reviewer_note
        ) order by r.requirement_code),'[]'::jsonb)
        from public.affiliation_application_requirements r where r.application_id=a.id
      )
    ) order by a.created_at desc
  ),'[]'::jsonb)
  from public.affiliation_applications a
  left join public.profiles ap on ap.id=a.activated_profile_id
  where auth.uid() is not null and a.person_id=public.current_user_person_id();
$function$;

-- Execute surface: no anonymous access. Applicant/reviewer RPCs are authenticated only.
revoke all on function public.tc_start_affiliation(text,uuid,uuid,text) from public, anon;
revoke all on function public.tc_update_affiliation_context(text,uuid,uuid,text) from public, anon;
revoke all on function public.tc_provide_affiliation_requirement(text,text,jsonb) from public, anon;
revoke all on function public.tc_submit_affiliation_application(text) from public, anon;
revoke all on function public.tc_withdraw_affiliation_application(text) from public, anon;
revoke all on function public.tc_my_affiliations() from public, anon;
revoke all on function public.tc_affiliation_review_queue(text,integer) from public, anon;
revoke all on function public.tc_review_affiliation_requirement(text,text,text,text) from public, anon;
revoke all on function public.tc_review_affiliation_application(text,text,text) from public, anon;
revoke all on function public.tc_finalize_affiliation_application(text,text,text) from public, anon;

grant execute on function public.tc_start_affiliation(text,uuid,uuid,text) to authenticated;
grant execute on function public.tc_update_affiliation_context(text,uuid,uuid,text) to authenticated;
grant execute on function public.tc_provide_affiliation_requirement(text,text,jsonb) to authenticated;
grant execute on function public.tc_submit_affiliation_application(text) to authenticated;
grant execute on function public.tc_withdraw_affiliation_application(text) to authenticated;
grant execute on function public.tc_my_affiliations() to authenticated;
grant execute on function public.tc_affiliation_review_queue(text,integer) to authenticated;
grant execute on function public.tc_review_affiliation_requirement(text,text,text,text) to authenticated;
grant execute on function public.tc_review_affiliation_application(text,text,text) to authenticated;
grant execute on function public.tc_finalize_affiliation_application(text,text,text) to authenticated;

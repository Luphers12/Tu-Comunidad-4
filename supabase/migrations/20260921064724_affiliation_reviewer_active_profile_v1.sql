
CREATE OR REPLACE FUNCTION public.tc_affiliation_review_queue(p_state text DEFAULT NULL::text, p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
      and (
        public.internal_has_capability(
          public.tc_active_profile_id(),'affiliation.review','COMMUNITY',a.community_id
        )
        or public.internal_has_capability(
          public.tc_active_profile_id(),'affiliation.approve','COMMUNITY',a.community_id
        )
      )
    order by a.created_at
    limit greatest(1,least(coalesce(p_limit,50),100))
  ) x;
$function$
;

CREATE OR REPLACE FUNCTION public.tc_review_affiliation_requirement(p_application_public_id text, p_requirement_code text, p_decision text, p_note text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

  v_reviewer := public.tc_active_profile_id();
  if v_reviewer is null or not (
    public.internal_has_capability(v_reviewer,'affiliation.review','COMMUNITY',v_community)
    or public.internal_has_capability(v_reviewer,'affiliation.approve','COMMUNITY',v_community)
  ) then
    raise exception 'AFFILIATION_REVIEW_FORBIDDEN' using errcode='P0001';
  end if;

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
$function$
;

CREATE OR REPLACE FUNCTION public.tc_review_affiliation_application(p_application_public_id text, p_decision text, p_rationale text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

  v_reviewer := public.tc_active_profile_id();
  if v_reviewer is null or not (
    public.internal_has_capability(v_reviewer,'affiliation.review','COMMUNITY',v_community)
    or public.internal_has_capability(v_reviewer,'affiliation.approve','COMMUNITY',v_community)
  ) then
    raise exception 'AFFILIATION_REVIEW_FORBIDDEN' using errcode='P0001';
  end if;

  v_next := case when v_decision='REQUEST_CHANGES' then 'CHANGES_REQUESTED' else 'UNDER_REVIEW' end;

  insert into public.affiliation_reviews(application_id,reviewer_profile_id,decision,rationale)
  values(v_app_id,v_reviewer,v_decision,nullif(btrim(coalesce(p_rationale,'')),''));

  update public.affiliation_applications set state=v_next,updated_at=now(),version=version+1 where id=v_app_id;

  insert into public.affiliation_events(application_id,actor_profile_id,event_type,from_state,to_state,payload)
  values(v_app_id,v_reviewer,'APPLICATION_REVIEWED',v_state,v_next,
         jsonb_build_object('decision',v_decision,'rationale',nullif(btrim(coalesce(p_rationale,'')),'')));

  return true;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.tc_finalize_affiliation_application(p_application_public_id text, p_decision text, p_rationale text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

  v_approver := public.tc_active_profile_id();
  if v_approver is null or not public.internal_has_capability(
    v_approver,'affiliation.approve','COMMUNITY',v_app.community_id
  ) then
    raise exception 'AFFILIATION_APPROVAL_FORBIDDEN' using errcode='P0001';
  end if;

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
$function$
;

revoke all on function public.tc_affiliation_review_queue(text,integer)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_review_affiliation_requirement(text,text,text,text)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_review_affiliation_application(text,text,text)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_finalize_affiliation_application(text,text,text)
  from public,anon,authenticated,service_role;

grant execute on function public.tc_affiliation_review_queue(text,integer)
  to authenticated;
grant execute on function public.tc_review_affiliation_requirement(text,text,text,text)
  to authenticated;
grant execute on function public.tc_review_affiliation_application(text,text,text)
  to authenticated;
grant execute on function public.tc_finalize_affiliation_application(text,text,text)
  to authenticated;

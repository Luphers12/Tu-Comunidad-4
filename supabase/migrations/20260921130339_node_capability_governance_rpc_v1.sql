
create or replace function public.tc_start_node_capability_request(
  p_node_public_id text,
  p_capability_code text,
  p_justification text default null,
  p_requested_configuration jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_node uuid;
  v_requester uuid;
  v_cap public.logistics_capability_catalog%rowtype;
  v_existing public.node_capability_requests%rowtype;
  v_request uuid;
  v_public text;
begin
  v_node:=public.tc_require_my_operational_node(p_node_public_id,null);
  v_requester:=public.tc_active_profile_id();

  select * into v_cap
  from public.logistics_capability_catalog c
  where c.code=upper(btrim(coalesce(p_capability_code,'')))
    and c.active
    and c.code in (
      'RECEIVE_CARGO',
      'HANDOFF_CARGO',
      'SORT_CARGO',
      'STAGE_CARGO',
      'LAST_MILE_ORIGIN',
      'BOX_HOST'
    );

  if v_cap.id is null then
    raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_NOT_REQUESTABLE';
  end if;

  if exists(
    select 1
    from public.operational_location_capabilities olc
    where olc.operational_location_id=v_node
      and olc.capability_id=v_cap.id
      and olc.status='ENABLED'
  ) then
    raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_ALREADY_ENABLED';
  end if;

  select * into v_existing
  from public.node_capability_requests r
  where r.operational_location_id=v_node
    and r.capability_id=v_cap.id
    and r.state in ('DRAFT','SUBMITTED','UNDER_REVIEW','CHANGES_REQUESTED')
  order by r.created_at desc,r.id desc
  limit 1;

  if v_existing.id is not null then
    return jsonb_build_object(
      'request_public_id',v_existing.public_id,
      'state',v_existing.state,
      'idempotent',true
    );
  end if;

  insert into public.node_capability_requests(
    operational_location_id,capability_id,requested_by_profile_id,
    state,justification,requested_configuration
  ) values(
    v_node,v_cap.id,v_requester,
    'DRAFT',
    nullif(btrim(coalesce(p_justification,'')),''),
    coalesce(p_requested_configuration,'{}'::jsonb)
  )
  returning id,public_id into v_request,v_public;

  insert into public.node_capability_request_requirements(
    request_id,requirement_code,source_type,required,status
  ) values
    (v_request,'NODE_OWNERSHIP','SYSTEM',true,'PENDING'),
    (v_request,'NETWORK_ENABLED','SYSTEM',true,'PENDING'),
    (v_request,'OPERATIONAL_READINESS','APPLICANT',true,'PENDING');

  if v_cap.code='LAST_MILE_ORIGIN' then
    insert into public.node_capability_request_requirements(
      request_id,requirement_code,source_type,required,status
    ) values
      (v_request,'RECEIVE_CARGO_ENABLED','SYSTEM',true,'PENDING'),
      (v_request,'HANDOFF_CARGO_ENABLED','SYSTEM',true,'PENDING'),
      (v_request,'HOME_DELIVERY_COVERAGE','SYSTEM',true,'PENDING');
  end if;

  perform public.tc_refresh_node_capability_requirements(v_request);

  insert into public.node_capability_request_events(
    request_id,event_type,actor_profile_id,metadata
  ) values(
    v_request,'STARTED',v_requester,
    jsonb_build_object('capability_code',v_cap.code)
  );

  return jsonb_build_object(
    'request_public_id',v_public,
    'state','DRAFT',
    'idempotent',false
  );
end;
$$;

create or replace function public.tc_provide_node_capability_requirement(
  p_request_public_id text,
  p_requirement_code text,
  p_evidence jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request public.node_capability_requests%rowtype;
  v_active uuid;
  v_req public.node_capability_request_requirements%rowtype;
begin
  v_active:=public.tc_active_profile_id();

  select * into v_request
  from public.node_capability_requests r
  where r.public_id=upper(btrim(coalesce(p_request_public_id,'')))
  for update;

  if v_request.id is null then
    raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_REQUEST_NOT_FOUND';
  end if;

  if v_request.requested_by_profile_id is distinct from v_active then
    raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_REQUEST_FORBIDDEN';
  end if;

  if v_request.state not in ('DRAFT','CHANGES_REQUESTED') then
    raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_REQUEST_NOT_EDITABLE';
  end if;

  select * into v_req
  from public.node_capability_request_requirements q
  where q.request_id=v_request.id
    and q.requirement_code=upper(btrim(coalesce(p_requirement_code,'')))
  for update;

  if v_req.id is null then
    raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_REQUIREMENT_NOT_FOUND';
  end if;

  if v_req.source_type<>'APPLICANT' then
    raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_SYSTEM_REQUIREMENT_READ_ONLY';
  end if;

  update public.node_capability_request_requirements
     set status='PROVIDED',
         evidence=coalesce(p_evidence,'{}'::jsonb),
         reviewer_note=null,
         updated_at=now()
   where id=v_req.id;

  insert into public.node_capability_request_events(
    request_id,event_type,actor_profile_id,metadata
  ) values(
    v_request.id,'REQUIREMENT_PROVIDED',v_active,
    jsonb_build_object('requirement_code',v_req.requirement_code)
  );

  return jsonb_build_object(
    'request_public_id',v_request.public_id,
    'requirement_code',v_req.requirement_code,
    'status','PROVIDED'
  );
end;
$$;

create or replace function public.tc_submit_node_capability_request(
  p_request_public_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request public.node_capability_requests%rowtype;
  v_active uuid;
  v_incomplete integer;
begin
  v_active:=public.tc_active_profile_id();

  select * into v_request
  from public.node_capability_requests r
  where r.public_id=upper(btrim(coalesce(p_request_public_id,'')))
  for update;

  if v_request.id is null then
    raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_REQUEST_NOT_FOUND';
  end if;

  if v_request.requested_by_profile_id is distinct from v_active then
    raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_REQUEST_FORBIDDEN';
  end if;

  if v_request.state not in ('DRAFT','CHANGES_REQUESTED') then
    raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_REQUEST_NOT_SUBMITTABLE';
  end if;

  perform public.tc_refresh_node_capability_requirements(v_request.id);

  select count(*) into v_incomplete
  from public.node_capability_request_requirements q
  where q.request_id=v_request.id
    and q.required
    and q.status not in ('PROVIDED','VERIFIED');

  if v_incomplete>0 then
    raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_REQUIREMENTS_INCOMPLETE';
  end if;

  update public.node_capability_requests
     set state='SUBMITTED',
         submitted_at=now(),
         updated_at=now()
   where id=v_request.id;

  insert into public.node_capability_request_events(
    request_id,event_type,actor_profile_id
  ) values(
    v_request.id,'SUBMITTED',v_active
  );

  return jsonb_build_object(
    'request_public_id',v_request.public_id,
    'state','SUBMITTED'
  );
end;
$$;

create or replace function public.tc_node_my_capability_requests(
  p_node_public_id text default null,
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_active uuid;
  v_node uuid;
  v_limit integer;
  v_result jsonb;
begin
  v_active:=public.tc_active_profile_id();

  if v_active is null then
    raise exception using errcode='P0001', message='TC_ACTIVE_PROFILE_NOT_SELECTED';
  end if;

  if p_node_public_id is not null then
    v_node:=public.tc_require_my_operational_node(p_node_public_id,null);
  end if;

  v_limit:=least(greatest(coalesce(p_limit,100),1),250);

  select coalesce(jsonb_agg(x.obj order by x.created_at desc,x.request_public_id),'[]'::jsonb)
  into v_result
  from (
    select
      r.created_at,
      r.public_id as request_public_id,
      jsonb_build_object(
        'request_public_id',r.public_id,
        'node_public_id',o.public_id,
        'node_name',o.name,
        'capability_code',c.code,
        'state',r.state,
        'justification',r.justification,
        'submitted_at',r.submitted_at,
        'decided_at',r.decided_at,
        'requirements',coalesce((
          select jsonb_agg(jsonb_build_object(
            'requirement_code',q.requirement_code,
            'source_type',q.source_type,
            'required',q.required,
            'status',q.status,
            'evidence',q.evidence,
            'reviewer_note',q.reviewer_note
          ) order by q.requirement_code)
          from public.node_capability_request_requirements q
          where q.request_id=r.id
        ),'[]'::jsonb)
      ) as obj
    from public.node_capability_requests r
    join public.operational_locations o on o.id=r.operational_location_id
    join public.logistics_capability_catalog c on c.id=r.capability_id
    where r.requested_by_profile_id=v_active
      and (v_node is null or r.operational_location_id=v_node)
    order by r.created_at desc,r.id desc
    limit v_limit
  ) x;

  return v_result;
end;
$$;

create or replace function public.tc_require_node_capability_reviewer(
  p_request_id uuid,
  p_mode text
)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_active uuid;
  v_type text;
  v_community uuid;
  v_capability_name text;
begin
  v_active:=public.tc_active_profile_id();

  if v_active is null then
    raise exception using errcode='P0001', message='TC_ACTIVE_PROFILE_NOT_SELECTED';
  end if;

  select p.profile_type into v_type
  from public.profiles p
  where p.id=v_active
    and p.status='active';

  if v_type not in ('SOP','ADM') then
    raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_REVIEW_ROLE_FORBIDDEN';
  end if;

  select o.community_id into v_community
  from public.node_capability_requests r
  join public.operational_locations o on o.id=r.operational_location_id
  where r.id=p_request_id;

  if v_community is null then
    raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_REQUEST_NOT_FOUND';
  end if;

  v_capability_name:=case upper(btrim(coalesce(p_mode,'')))
    when 'REVIEW' then 'logistics.node_capability.review'
    when 'APPROVE' then 'logistics.node_capability.approve'
    else null
  end;

  if v_capability_name is null then
    raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_REVIEW_MODE_INVALID';
  end if;

  if not (
    public.internal_has_capability(
      v_active,v_capability_name::varchar,'GLOBAL'::public.tc_scope_type,null
    )
    or
    public.internal_has_capability(
      v_active,v_capability_name::varchar,'COMMUNITY'::public.tc_scope_type,v_community
    )
  ) then
    raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_REVIEW_CAPABILITY_REQUIRED';
  end if;

  return v_active;
end;
$$;

revoke all on function public.tc_require_node_capability_reviewer(uuid,text)
  from public,anon,authenticated,service_role;

create or replace function public.tc_node_capability_review_queue(
  p_capability_code text default null,
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_active uuid;
  v_type text;
  v_limit integer;
  v_filter text:=nullif(upper(btrim(coalesce(p_capability_code,''))),'');
  v_result jsonb;
begin
  v_active:=public.tc_active_profile_id();

  if v_active is null then
    raise exception using errcode='P0001', message='TC_ACTIVE_PROFILE_NOT_SELECTED';
  end if;

  select p.profile_type into v_type
  from public.profiles p
  where p.id=v_active and p.status='active';

  if v_type not in ('SOP','ADM') then
    raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_REVIEW_ROLE_FORBIDDEN';
  end if;

  v_limit:=least(greatest(coalesce(p_limit,100),1),250);

  select coalesce(jsonb_agg(x.obj order by x.created_at,x.request_public_id),'[]'::jsonb)
  into v_result
  from (
    select
      r.created_at,
      r.public_id as request_public_id,
      jsonb_build_object(
        'request_public_id',r.public_id,
        'state',r.state,
        'node_public_id',o.public_id,
        'node_name',o.name,
        'community_public_id',cm.public_id,
        'community_name',cm.name,
        'requester_profile_public_id',reqp.public_id,
        'capability_code',c.code,
        'justification',r.justification,
        'requested_configuration',r.requested_configuration,
        'requirements',coalesce((
          select jsonb_agg(jsonb_build_object(
            'requirement_code',q.requirement_code,
            'source_type',q.source_type,
            'required',q.required,
            'status',q.status,
            'evidence',q.evidence,
            'reviewer_note',q.reviewer_note
          ) order by q.requirement_code)
          from public.node_capability_request_requirements q
          where q.request_id=r.id
        ),'[]'::jsonb)
      ) as obj
    from public.node_capability_requests r
    join public.operational_locations o on o.id=r.operational_location_id
    join public.communities cm on cm.id=o.community_id
    join public.logistics_capability_catalog c on c.id=r.capability_id
    join public.profiles reqp on reqp.id=r.requested_by_profile_id
    where r.state in ('SUBMITTED','UNDER_REVIEW','CHANGES_REQUESTED')
      and (v_filter is null or c.code=v_filter)
      and (
        public.internal_has_capability(
          v_active,'logistics.node_capability.review'::varchar,
          'GLOBAL'::public.tc_scope_type,null
        )
        or public.internal_has_capability(
          v_active,'logistics.node_capability.approve'::varchar,
          'GLOBAL'::public.tc_scope_type,null
        )
        or public.internal_has_capability(
          v_active,'logistics.node_capability.review'::varchar,
          'COMMUNITY'::public.tc_scope_type,o.community_id
        )
        or public.internal_has_capability(
          v_active,'logistics.node_capability.approve'::varchar,
          'COMMUNITY'::public.tc_scope_type,o.community_id
        )
      )
    order by r.created_at,r.id
    limit v_limit
  ) x;

  return v_result;
end;
$$;

create or replace function public.tc_review_node_capability_requirement(
  p_request_public_id text,
  p_requirement_code text,
  p_decision text,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request public.node_capability_requests%rowtype;
  v_reviewer uuid;
  v_req public.node_capability_request_requirements%rowtype;
  v_decision text:=upper(btrim(coalesce(p_decision,'')));
begin
  select * into v_request
  from public.node_capability_requests r
  where r.public_id=upper(btrim(coalesce(p_request_public_id,'')))
  for update;

  if v_request.id is null then
    raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_REQUEST_NOT_FOUND';
  end if;

  v_reviewer:=public.tc_require_node_capability_reviewer(v_request.id,'REVIEW');

  if v_request.state not in ('SUBMITTED','UNDER_REVIEW','CHANGES_REQUESTED') then
    raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_REQUEST_NOT_REVIEWABLE';
  end if;

  if v_decision not in ('VERIFIED','REJECTED') then
    raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_REQUIREMENT_DECISION_INVALID';
  end if;

  select * into v_req
  from public.node_capability_request_requirements q
  where q.request_id=v_request.id
    and q.requirement_code=upper(btrim(coalesce(p_requirement_code,'')))
  for update;

  if v_req.id is null then
    raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_REQUIREMENT_NOT_FOUND';
  end if;

  if v_req.source_type<>'APPLICANT' then
    raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_SYSTEM_REQUIREMENT_READ_ONLY';
  end if;

  if v_decision='VERIFIED' and v_req.status not in ('PROVIDED','VERIFIED') then
    raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_REQUIREMENT_NOT_PROVIDED';
  end if;

  update public.node_capability_request_requirements
     set status=v_decision,
         reviewer_note=nullif(btrim(coalesce(p_note,'')),''),
         updated_at=now()
   where id=v_req.id;

  update public.node_capability_requests
     set state=case when v_decision='REJECTED' then 'CHANGES_REQUESTED' else 'UNDER_REVIEW' end,
         updated_at=now()
   where id=v_request.id;

  insert into public.node_capability_request_events(
    request_id,event_type,actor_profile_id,metadata
  ) values(
    v_request.id,
    case when v_decision='VERIFIED' then 'REQUIREMENT_VERIFIED' else 'REQUIREMENT_REJECTED' end,
    v_reviewer,
    jsonb_build_object(
      'requirement_code',v_req.requirement_code,
      'note',nullif(btrim(coalesce(p_note,'')),'')
    )
  );

  return jsonb_build_object(
    'request_public_id',v_request.public_id,
    'requirement_code',v_req.requirement_code,
    'status',v_decision
  );
end;
$$;

create or replace function public.tc_finalize_node_capability_request(
  p_request_public_id text,
  p_decision text,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request public.node_capability_requests%rowtype;
  v_approver uuid;
  v_approver_person uuid;
  v_decision text:=upper(btrim(coalesce(p_decision,'')));
  v_incomplete integer;
  v_cap text;
  v_olc_public text;
begin
  select * into v_request
  from public.node_capability_requests r
  where r.public_id=upper(btrim(coalesce(p_request_public_id,'')))
  for update;

  if v_request.id is null then
    raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_REQUEST_NOT_FOUND';
  end if;

  v_approver:=public.tc_require_node_capability_reviewer(v_request.id,'APPROVE');

  if v_decision not in ('APPROVE','REJECT','CHANGES_REQUESTED') then
    raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_FINAL_DECISION_INVALID';
  end if;

  if v_request.state not in ('SUBMITTED','UNDER_REVIEW','CHANGES_REQUESTED') then
    raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_REQUEST_NOT_FINALIZABLE';
  end if;

  if v_decision='APPROVE' then
    perform public.tc_refresh_node_capability_requirements(v_request.id);

    select count(*) into v_incomplete
    from public.node_capability_request_requirements q
    where q.request_id=v_request.id
      and q.required
      and q.status<>'VERIFIED';

    if v_incomplete>0 then
      raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_REQUIREMENTS_NOT_VERIFIED';
    end if;

    if not exists(
      select 1
      from public.operational_locations o
      join public.profiles p on p.id=o.owner_profile_id
      where o.id=v_request.operational_location_id
        and o.active
        and o.network_enabled
        and p.id=v_request.requested_by_profile_id
        and p.status='active'
        and p.profile_type in ('TIE','PTC')
    ) then
      raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_OWNERSHIP_CHANGED';
    end if;

    select p.person_id into v_approver_person
    from public.profiles p
    where p.id=v_approver;

    insert into public.operational_location_capabilities(
      operational_location_id,capability_id,status,
      configuration,set_by_person_id
    ) values(
      v_request.operational_location_id,
      v_request.capability_id,
      'ENABLED',
      v_request.requested_configuration,
      v_approver_person
    )
    on conflict (operational_location_id,capability_id)
    do update set
      status='ENABLED',
      configuration=excluded.configuration,
      set_by_person_id=excluded.set_by_person_id,
      updated_at=now()
    returning public_id into v_olc_public;

    update public.node_capability_requests
       set state='APPROVED',
           decided_at=now(),
           updated_at=now()
     where id=v_request.id;

    select c.code into v_cap
    from public.logistics_capability_catalog c
    where c.id=v_request.capability_id;

    insert into public.node_capability_request_events(
      request_id,event_type,actor_profile_id,metadata
    ) values(
      v_request.id,'APPROVED',v_approver,
      jsonb_build_object(
        'capability_code',v_cap,
        'operational_location_capability_public_id',v_olc_public,
        'note',nullif(btrim(coalesce(p_note,'')),'')
      )
    );

    return jsonb_build_object(
      'request_public_id',v_request.public_id,
      'state','APPROVED',
      'operational_location_capability_public_id',v_olc_public
    );
  end if;

  update public.node_capability_requests
     set state=case when v_decision='REJECT' then 'REJECTED' else 'CHANGES_REQUESTED' end,
         decided_at=case when v_decision='REJECT' then now() else decided_at end,
         updated_at=now()
   where id=v_request.id;

  insert into public.node_capability_request_events(
    request_id,event_type,actor_profile_id,metadata
  ) values(
    v_request.id,
    case when v_decision='REJECT' then 'REJECTED' else 'CHANGES_REQUESTED' end,
    v_approver,
    jsonb_build_object('note',nullif(btrim(coalesce(p_note,'')),''))
  );

  return jsonb_build_object(
    'request_public_id',v_request.public_id,
    'state',case when v_decision='REJECT' then 'REJECTED' else 'CHANGES_REQUESTED' end
  );
end;
$$;

revoke all on function public.tc_start_node_capability_request(text,text,text,jsonb)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_provide_node_capability_requirement(text,text,jsonb)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_submit_node_capability_request(text)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_node_my_capability_requests(text,integer)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_node_capability_review_queue(text,integer)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_review_node_capability_requirement(text,text,text,text)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_finalize_node_capability_request(text,text,text)
  from public,anon,authenticated,service_role;

grant execute on function public.tc_start_node_capability_request(text,text,text,jsonb)
  to authenticated;
grant execute on function public.tc_provide_node_capability_requirement(text,text,jsonb)
  to authenticated;
grant execute on function public.tc_submit_node_capability_request(text)
  to authenticated;
grant execute on function public.tc_node_my_capability_requests(text,integer)
  to authenticated;
grant execute on function public.tc_node_capability_review_queue(text,integer)
  to authenticated;
grant execute on function public.tc_review_node_capability_requirement(text,text,text,text)
  to authenticated;
grant execute on function public.tc_finalize_node_capability_request(text,text,text)
  to authenticated;

comment on function public.tc_finalize_node_capability_request(text,text,text) is
'Only active SOP/ADM with explicit logistics.node_capability.approve scope may enable a NODE capability. LAST_MILE_ORIGIN system prerequisites cannot be waived.';

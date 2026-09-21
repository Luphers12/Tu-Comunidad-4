
create or replace function public.tc_profile_switcher()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_person uuid;
  v_context_key text;
  v_active uuid;
  v_default uuid;
  v_profiles jsonb;
  v_locked jsonb;
  v_activation_options jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode='P0001', message='TC_UNAUTHENTICATED';
  end if;

  select p.id into v_person
  from public.persons p
  where p.auth_user_id=auth.uid();

  if v_person is null then
    raise exception using errcode='P0001', message='TC_SESSION_PERSON_NOT_FOUND';
  end if;

  v_context_key:=public.tc_session_context_key();

  select c.active_profile_id into v_active
  from public.active_profile_contexts c
  join public.profiles p on p.id=c.active_profile_id
  where c.person_id=v_person
    and c.session_context_key=v_context_key
    and p.person_id=v_person
    and p.status='active';

  if v_active is null then
    select p.id into v_default
    from public.profiles p
    where p.person_id=v_person
      and p.status='active'
    order by
      case p.profile_type
        when 'CLI' then 1
        when 'CON' then 2
        when 'RSG' then 3
        when 'TIE' then 4
        when 'PTC' then 5
        when 'VEN' then 6
        when 'EMP' then 7
        when 'SOP' then 8
        when 'ADM' then 9
        else 20
      end,
      p.created_at,
      p.public_id
    limit 1;

    if v_default is null then
      raise exception using errcode='P0001', message='TC_NO_ACTIVE_PROFILE_AVAILABLE';
    end if;

    insert into public.active_profile_contexts(
      person_id,session_context_key,active_profile_id,activated_at
    ) values(
      v_person,v_context_key,v_default,now()
    )
    on conflict (person_id,session_context_key)
    do update set
      active_profile_id=excluded.active_profile_id,
      activated_at=excluded.activated_at,
      updated_at=now();

    insert into public.active_profile_context_events(
      person_id,session_context_key,from_profile_id,to_profile_id,event_type
    ) values(
      v_person,v_context_key,null,v_default,'DEFAULT_SELECTED'
    );

    v_active:=v_default;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'profile_public_id',p.public_id,
    'profile_type',p.profile_type,
    'status',p.status,
    'is_active_profile',(p.id=v_active),
    'active_commitment_count',public.tc_profile_active_commitment_count(p.id)
  ) order by
    case p.profile_type
      when 'CLI' then 1
      when 'CON' then 2
      when 'RSG' then 3
      when 'TIE' then 4
      when 'PTC' then 5
      when 'VEN' then 6
      when 'EMP' then 7
      when 'SOP' then 8
      when 'ADM' then 9
      else 20
    end,
    p.public_id),'[]'::jsonb)
  into v_profiles
  from public.profiles p
  where p.person_id=v_person
    and p.status='active';

  select coalesce(jsonb_agg(jsonb_build_object(
    'profile_public_id',p.public_id,
    'profile_type',p.profile_type,
    'status',p.status,
    'switchable',false
  ) order by p.profile_type,p.public_id),'[]'::jsonb)
  into v_locked
  from public.profiles p
  where p.person_id=v_person
    and p.status<>'active';

  with roles(role_code,sort_order) as (
    values
      ('TIE'::text,1),
      ('VEN'::text,2),
      ('CON'::text,3),
      ('RSG'::text,4),
      ('PTC'::text,5)
  ),
  role_state as (
    select
      r.role_code,
      r.sort_order,
      ap.active_count,
      la.id as application_id,
      la.public_id as application_public_id,
      la.state as application_state,
      la.activated_profile_id,
      activated.public_id as activated_profile_public_id,
      coalesce(req.required_total,0) as required_total,
      coalesce(req.required_complete,0) as required_complete,
      greatest(coalesce(req.required_total,0)-coalesce(req.required_complete,0),0) as required_remaining,
      coalesce(req.requirements,'[]'::jsonb) as requirements
    from roles r
    left join lateral (
      select count(*)::integer as active_count
      from public.profiles p
      where p.person_id=v_person
        and p.profile_type=r.role_code
        and p.status='active'
    ) ap on true
    left join lateral (
      select a.*
      from public.affiliation_applications a
      where a.person_id=v_person
        and a.requested_role_code=r.role_code
      order by a.created_at desc,a.id desc
      limit 1
    ) la on true
    left join public.profiles activated
      on activated.id=la.activated_profile_id
    left join lateral (
      select
        count(*) filter(where ar.required)::integer as required_total,
        count(*) filter(
          where ar.required and ar.status in ('VERIFIED','WAIVED')
        )::integer as required_complete,
        coalesce(jsonb_agg(jsonb_build_object(
          'code',ar.requirement_code,
          'required',ar.required,
          'status',ar.status,
          'reviewer_note',ar.reviewer_note
        ) order by ar.requirement_code),'[]'::jsonb) as requirements
      from public.affiliation_application_requirements ar
      where ar.application_id=la.id
    ) req on true
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'role_code',rs.role_code,
    'activation_state',case
      when rs.active_count>0 then 'ACTIVE'
      when rs.application_id is null then 'NOT_STARTED'
      else rs.application_state
    end,
    'switchable',(rs.active_count>0),
    'can_start_affiliation',(
      rs.active_count=0
      and (
        rs.application_id is null
        or rs.application_state in ('REJECTED','WITHDRAWN')
      )
    ),
    'application_public_id',rs.application_public_id,
    'activated_profile_public_id',rs.activated_profile_public_id,
    'required_total',rs.required_total,
    'required_complete',rs.required_complete,
    'required_remaining',rs.required_remaining,
    'requirements',rs.requirements
  ) order by rs.sort_order),'[]'::jsonb)
  into v_activation_options
  from role_state rs;

  return jsonb_build_object(
    'active_profile_public_id',(select public_id from public.profiles where id=v_active),
    'active_profile_type',(select profile_type from public.profiles where id=v_active),
    'switchable_profiles',v_profiles,
    'locked_profiles',v_locked,
    'role_activation_options',v_activation_options
  );
end;
$$;

revoke all on function public.tc_profile_switcher()
  from public,anon,authenticated,service_role;
grant execute on function public.tc_profile_switcher()
  to authenticated;

comment on function public.tc_profile_switcher() is
'Account-level profile switcher plus affiliation activation status. Operational switching requires an active profile; incomplete role applications remain visible but non-switchable.';

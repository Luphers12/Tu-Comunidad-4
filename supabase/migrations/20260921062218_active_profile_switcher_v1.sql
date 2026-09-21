
create or replace function public.tc_profile_active_commitment_count(
  p_profile_id uuid
)
returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_type text;
  v_count integer:=0;
begin
  select profile_type into v_type
  from public.profiles
  where id=p_profile_id
    and status='active';

  if v_type='RSG' then
    select count(*) into v_count
    from public.logistics_last_mile_assignments a
    where a.rsg_profile_id=p_profile_id
      and a.state='ACTIVE';

  elsif v_type='CON' then
    select count(distinct m.id) into v_count
    from public.logistics_matches m
    join public.logistics_trips t on t.id=m.trip_id
    join public.logistics_capacity_reservations r
      on r.id=m.capacity_reservation_id
    where t.driver_profile_id=p_profile_id
      and m.state='ACCEPTED'
      and r.state in ('HELD','CONFIRMED')
      and t.state not in ('COMPLETED','CANCELLED');
  end if;

  return coalesce(v_count,0);
end;
$$;

revoke all on function public.tc_profile_active_commitment_count(uuid)
  from public,anon,authenticated,service_role;

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

  return jsonb_build_object(
    'active_profile_public_id',(select public_id from public.profiles where id=v_active),
    'active_profile_type',(select profile_type from public.profiles where id=v_active),
    'switchable_profiles',v_profiles,
    'locked_profiles',v_locked
  );
end;
$$;

create or replace function public.tc_switch_active_profile(
  p_profile_public_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_person uuid;
  v_context_key text;
  v_target public.profiles%rowtype;
  v_from public.profiles%rowtype;
  v_from_id uuid;
  v_background integer:=0;
  v_paused integer:=0;
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

  select * into v_target
  from public.profiles p
  where p.person_id=v_person
    and p.public_id=upper(btrim(coalesce(p_profile_public_id,'')));

  if v_target.id is null or v_target.status<>'active' then
    raise exception using errcode='P0001', message='TC_PROFILE_NOT_SWITCHABLE';
  end if;

  v_context_key:=public.tc_session_context_key();

  select c.active_profile_id into v_from_id
  from public.active_profile_contexts c
  where c.person_id=v_person
    and c.session_context_key=v_context_key
  for update;

  if v_from_id is not null then
    select * into v_from from public.profiles where id=v_from_id;
  end if;

  if v_from_id=v_target.id then
    return jsonb_build_object(
      'active_profile_public_id',v_target.public_id,
      'active_profile_type',v_target.profile_type,
      'changed',false,
      'background_commitment_count',public.tc_profile_active_commitment_count(v_target.id),
      'paused_availability_count',0
    );
  end if;

  if v_from_id is not null then
    v_background:=public.tc_profile_active_commitment_count(v_from_id);

    if v_from.profile_type='RSG' then
      update public.logistics_rsg_availability
         set state='PAUSED',
             updated_at=now()
       where rsg_profile_id=v_from_id
         and state='AVAILABLE';

      get diagnostics v_paused=row_count;
    end if;
  end if;

  insert into public.active_profile_contexts(
    person_id,session_context_key,active_profile_id,activated_at
  ) values(
    v_person,v_context_key,v_target.id,now()
  )
  on conflict (person_id,session_context_key)
  do update set
    active_profile_id=excluded.active_profile_id,
    activated_at=excluded.activated_at,
    updated_at=now();

  insert into public.active_profile_context_events(
    person_id,session_context_key,from_profile_id,to_profile_id,event_type
  ) values(
    v_person,v_context_key,v_from_id,v_target.id,'PROFILE_SWITCH'
  );

  return jsonb_build_object(
    'active_profile_public_id',v_target.public_id,
    'active_profile_type',v_target.profile_type,
    'changed',true,
    'previous_profile_public_id',v_from.public_id,
    'previous_profile_type',v_from.profile_type,
    'background_commitment_count',v_background,
    'paused_availability_count',v_paused
  );
end;
$$;

revoke all on function public.tc_profile_switcher()
  from public,anon,authenticated,service_role;
revoke all on function public.tc_switch_active_profile(text)
  from public,anon,authenticated,service_role;

grant execute on function public.tc_profile_switcher()
  to authenticated;
grant execute on function public.tc_switch_active_profile(text)
  to authenticated;

comment on function public.tc_switch_active_profile(text) is
'Explicit Facebook-style operational profile switch. Existing commitments remain owned by the profile that accepted them; switching away only removes action authority and pauses new RSG availability.';

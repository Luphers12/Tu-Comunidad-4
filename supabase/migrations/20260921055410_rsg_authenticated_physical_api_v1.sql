
create or replace function public.tc_release_last_mile_to_rsg(
  p_movement_public_id text,
  p_package_public_ids text[],
  p_idempotency_key text,
  p_occurred_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_movement public.movements%rowtype;
  v_actor uuid;
  v_ids uuid[];
  v_requested integer;
  v_resolved integer;
begin
  if auth.uid() is null then
    raise exception using errcode='P0001', message='TC_UNAUTHENTICATED';
  end if;

  select * into v_movement
  from public.movements mv
  where mv.public_id=upper(btrim(coalesce(p_movement_public_id,'')));

  if v_movement.id is null or v_movement.from_profile_id is null then
    raise exception using errcode='P0001', message='TC_LAST_MILE_MOVEMENT_NOT_FOUND';
  end if;

  v_actor:=v_movement.from_profile_id;

  if not exists(
    select 1
    from public.profiles p
    join public.persons per on per.id=p.person_id
    where p.id=v_actor
      and p.status='active'
      and per.auth_user_id=auth.uid()
  ) then
    raise exception using errcode='P0001', message='TC_LAST_MILE_ORIGIN_RELEASE_FORBIDDEN';
  end if;

  select
    array_agg(p.id order by p.public_id),
    count(*)
  into v_ids,v_resolved
  from public.packages p
  join public.movement_packages mp
    on mp.package_id=p.id
   and mp.movement_id=v_movement.id
  where p.public_id in (
    select distinct upper(btrim(x))
    from unnest(p_package_public_ids) x
    where nullif(btrim(x),'') is not null
  );

  select count(distinct upper(btrim(x))) into v_requested
  from unnest(p_package_public_ids) x
  where nullif(btrim(x),'') is not null;

  if v_requested is null or v_requested<1 or v_resolved<>v_requested then
    raise exception using errcode='P0001', message='TC_PACKAGE_NOT_IN_MOVEMENT';
  end if;

  return public.tc_apply_last_mile_pickup_release(
    v_movement.id,v_ids,v_actor,p_idempotency_key,p_occurred_at
  );
end;
$$;

create or replace function public.tc_rsg_receive_pickup(
  p_rsg_public_id text,
  p_movement_public_id text,
  p_package_public_ids text[],
  p_idempotency_key text,
  p_occurred_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rsg uuid;
  v_movement uuid;
  v_ids uuid[];
  v_requested integer;
  v_resolved integer;
begin
  v_rsg:=public.tc_require_my_rsg_profile(p_rsg_public_id);

  select mv.id into v_movement
  from public.movements mv
  join public.logistics_last_mile_assignments a
    on a.movement_id=mv.id
   and a.rsg_profile_id=v_rsg
   and a.state='ACTIVE'
  where mv.public_id=upper(btrim(coalesce(p_movement_public_id,'')));

  if v_movement is null then
    raise exception using errcode='P0001', message='TC_RSG_MOVEMENT_FORBIDDEN';
  end if;

  select array_agg(p.id order by p.public_id),count(*)
    into v_ids,v_resolved
  from public.packages p
  join public.movement_packages mp
    on mp.package_id=p.id
   and mp.movement_id=v_movement
  where p.public_id in (
    select distinct upper(btrim(x))
    from unnest(p_package_public_ids) x
    where nullif(btrim(x),'') is not null
  );

  select count(distinct upper(btrim(x))) into v_requested
  from unnest(p_package_public_ids) x
  where nullif(btrim(x),'') is not null;

  if v_requested is null or v_requested<1 or v_resolved<>v_requested then
    raise exception using errcode='P0001', message='TC_PACKAGE_NOT_IN_MOVEMENT';
  end if;

  return public.tc_apply_last_mile_pickup_receive(
    v_movement,v_ids,v_rsg,p_idempotency_key,p_occurred_at
  );
end;
$$;

create or replace function public.tc_rsg_record_arrival_candidate(
  p_rsg_public_id text,
  p_movement_public_id text,
  p_source_type text,
  p_latitude numeric default null,
  p_longitude numeric default null,
  p_idempotency_key text default null,
  p_occurred_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rsg uuid;
  v_movement uuid;
begin
  v_rsg:=public.tc_require_my_rsg_profile(p_rsg_public_id);

  if nullif(btrim(coalesce(p_idempotency_key,'')),'') is null then
    raise exception using errcode='P0001', message='TC_RSG_IDEMPOTENCY_KEY_REQUIRED';
  end if;

  select mv.id into v_movement
  from public.movements mv
  join public.logistics_last_mile_assignments a
    on a.movement_id=mv.id
   and a.rsg_profile_id=v_rsg
   and a.state='ACTIVE'
  where mv.public_id=upper(btrim(coalesce(p_movement_public_id,'')));

  if v_movement is null then
    raise exception using errcode='P0001', message='TC_RSG_MOVEMENT_FORBIDDEN';
  end if;

  return public.tc_record_last_mile_arrival_candidate(
    v_movement,v_rsg,p_source_type,p_latitude,p_longitude,
    p_idempotency_key,p_occurred_at
  );
end;
$$;

create or replace function public.tc_rsg_confirm_delivery(
  p_rsg_public_id text,
  p_movement_public_id text,
  p_package_public_ids text[],
  p_evidence_public_ids text[],
  p_idempotency_key text,
  p_occurred_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rsg uuid;
  v_movement uuid;
  v_ids uuid[];
  v_requested integer;
  v_resolved integer;
begin
  v_rsg:=public.tc_require_my_rsg_profile(p_rsg_public_id);

  select mv.id into v_movement
  from public.movements mv
  join public.logistics_last_mile_assignments a
    on a.movement_id=mv.id
   and a.rsg_profile_id=v_rsg
   and a.state='ACTIVE'
  where mv.public_id=upper(btrim(coalesce(p_movement_public_id,'')));

  if v_movement is null then
    raise exception using errcode='P0001', message='TC_RSG_MOVEMENT_FORBIDDEN';
  end if;

  select array_agg(p.id order by p.public_id),count(*)
    into v_ids,v_resolved
  from public.packages p
  join public.movement_packages mp
    on mp.package_id=p.id
   and mp.movement_id=v_movement
  where p.public_id in (
    select distinct upper(btrim(x))
    from unnest(p_package_public_ids) x
    where nullif(btrim(x),'') is not null
  );

  select count(distinct upper(btrim(x))) into v_requested
  from unnest(p_package_public_ids) x
  where nullif(btrim(x),'') is not null;

  if v_requested is null or v_requested<1 or v_resolved<>v_requested then
    raise exception using errcode='P0001', message='TC_PACKAGE_NOT_IN_MOVEMENT';
  end if;

  return public.tc_apply_last_mile_delivery_confirmation(
    v_movement,v_ids,v_rsg,p_evidence_public_ids,
    p_idempotency_key,p_occurred_at
  );
end;
$$;

create or replace function public.tc_rsg_my_execution_board(
  p_rsg_public_id text,
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_rsg uuid;
  v_limit integer;
  v_result jsonb;
begin
  v_rsg:=public.tc_require_my_rsg_profile(p_rsg_public_id);
  v_limit:=least(greatest(coalesce(p_limit,100),1),250);

  select coalesce(jsonb_agg(x.obj order by x.accepted_at desc,x.assignment_public_id),'[]'::jsonb)
  into v_result
  from (
    select
      a.accepted_at,
      a.public_id as assignment_public_id,
      jsonb_build_object(
        'assignment_public_id',a.public_id,
        'task_public_id',t.public_id,
        'assignment_state',a.state,
        'movement_public_id',mv.public_id,
        'movement_state',mv.state,
        'service_mode',av.service_mode,
        'origin',jsonb_build_object(
          'node_public_id',o.public_id,
          'name',o.name
        ),
        'packages',coalesce((
          select jsonb_agg(jsonb_build_object(
            'package_public_id',p.public_id,
            'state',p.state,
            'current_custody_is_rsg',(p.current_custodian_id=v_rsg)
          ) order by p.public_id)
          from public.movement_packages mp
          join public.packages p on p.id=mp.package_id
          where mp.movement_id=mv.id
        ),'[]'::jsonb),
        'recipient',jsonb_build_object(
          'name',pds.recipient_name,
          'phone',pds.recipient_phone
        ),
        'destination',jsonb_build_object(
          'address_text',concat_ws(', ',pds.label,c.name,mun.name,dep.name),
          'label',pds.label,
          'community_name',c.name,
          'municipality_name',mun.name,
          'department_name',dep.name,
          'lat',case when pds.point is null then null else extensions.st_y(pds.point::extensions.geometry) end,
          'lng',case when pds.point is null then null else extensions.st_x(pds.point::extensions.geometry) end,
          'visual_reference',pds.visual_reference,
          'access_instructions',pds.access_instructions,
          'authorized_contact',pds.authorized_contact,
          'safe_location_ref',pds.safe_location_ref
        ),
        'arrival_candidates',coalesce((
          select jsonb_agg(jsonb_build_object(
            'arrival_event_public_id',e.public_id,
            'source_type',e.source_type,
            'distance_to_destination_m',e.distance_to_destination_m,
            'occurred_at',e.occurred_at
          ) order by e.occurred_at,e.id)
          from public.logistics_last_mile_arrival_events e
          where e.movement_id=mv.id
        ),'[]'::jsonb)
      ) as obj
    from public.logistics_last_mile_assignments a
    join public.logistics_last_mile_tasks t on t.id=a.task_id
    join public.movements mv on mv.id=a.movement_id
    join public.logistics_last_mile_matches lm on lm.id=a.match_id
    join public.logistics_rsg_availability av on av.id=lm.availability_id
    join public.operational_locations o on o.id=t.origin_operational_location_id
    join public.logistics_destination_versions dsv on dsv.id=t.destination_version_id
    join public.private_destination_snapshots pds on pds.id=dsv.private_snapshot_id
    join public.communities c on c.id=pds.community_id
    join public.municipalities mun on mun.id=pds.municipality_id
    join public.departments dep on dep.id=pds.department_id
    where a.rsg_profile_id=v_rsg
      and a.state='ACTIVE'
    order by a.accepted_at desc,a.public_id
    limit v_limit
  ) x;

  return v_result;
end;
$$;

revoke all on function public.tc_release_last_mile_to_rsg(text,text[],text,timestamptz)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_rsg_receive_pickup(text,text,text[],text,timestamptz)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_rsg_record_arrival_candidate(text,text,text,numeric,numeric,text,timestamptz)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_rsg_confirm_delivery(text,text,text[],text[],text,timestamptz)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_rsg_my_execution_board(text,integer)
  from public,anon,authenticated,service_role;

grant execute on function public.tc_release_last_mile_to_rsg(text,text[],text,timestamptz)
  to authenticated;
grant execute on function public.tc_rsg_receive_pickup(text,text,text[],text,timestamptz)
  to authenticated;
grant execute on function public.tc_rsg_record_arrival_candidate(text,text,text,numeric,numeric,text,timestamptz)
  to authenticated;
grant execute on function public.tc_rsg_confirm_delivery(text,text,text[],text[],text,timestamptz)
  to authenticated;
grant execute on function public.tc_rsg_my_execution_board(text,integer)
  to authenticated;

comment on function public.tc_rsg_record_arrival_candidate(text,text,text,numeric,numeric,text,timestamptz) is
'Records assigned-RSG arrival-candidate evidence and optional distance to destination. It never marks the package delivered or transfers custody.';
comment on function public.tc_rsg_confirm_delivery(text,text,text[],text[],text,timestamptz) is
'Final delivery confirmation requires package-specific registered last-mile evidence before custody transfers from RSG to CLI.';

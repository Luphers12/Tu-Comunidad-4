
create or replace function public.tc_refresh_last_mile_matches(
  p_task_id uuid
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_task public.logistics_last_mile_tasks%rowtype;
  v_community uuid;
  v_inserted integer:=0;
begin
  select * into v_task
  from public.logistics_last_mile_tasks t
  where t.id=p_task_id
  for update;

  if v_task.id is null then
    raise exception using errcode='P0001', message='TC_LAST_MILE_TASK_NOT_FOUND';
  end if;

  if v_task.state in ('ASSIGNED','PICKED_UP','OUT_FOR_DELIVERY','DELIVERED','CANCELLED') then
    return jsonb_build_object(
      'task_id',v_task.id,
      'status','NO_REFRESH_FOR_STATE',
      'task_state',v_task.state,
      'offered',0
    );
  end if;

  select dsv.community_id into v_community
  from public.logistics_destination_versions dsv
  where dsv.id=v_task.destination_version_id
    and dsv.target_kind='PRIVATE_LOCATION';

  if v_community is null then
    raise exception using errcode='P0001', message='TC_LAST_MILE_PRIVATE_DESTINATION_REQUIRED';
  end if;

  if not exists(
    select 1 from public.service_coverage sc
    where sc.community_id=v_community
      and sc.is_active
      and sc.home_delivery_available
  ) then
    return jsonb_build_object(
      'task_id',v_task.id,
      'status','HOME_DELIVERY_UNAVAILABLE',
      'offered',0
    );
  end if;

  with eligible as (
    select a.id as availability_id,a.rsg_profile_id
    from public.logistics_rsg_availability a
    join public.profiles p
      on p.id=a.rsg_profile_id
     and p.profile_type='RSG'
     and p.status='active'
    where a.community_id=v_community
      and a.state='AVAILABLE'
      and (not v_task.requires_cold_chain or a.supports_cold_chain)
      and (not v_task.requires_fragile_handling or a.supports_fragile)
      and (not v_task.requires_bulky or a.supports_bulky)
      and (
        a.available_from is null
        or v_task.latest_delivery_at is null
        or a.available_from<=v_task.latest_delivery_at
      )
      and (
        a.available_until is null
        or v_task.earliest_ready_at is null
        or a.available_until>=v_task.earliest_ready_at
      )
      and (
        select coalesce(sum(r.reserved_weight_kg),0)
        from public.logistics_rsg_capacity_reservations r
        where r.availability_id=a.id and r.state='CONFIRMED'
      ) + v_task.total_weight_kg <= a.available_weight_kg
      and (
        select coalesce(sum(r.reserved_volume_m3),0)
        from public.logistics_rsg_capacity_reservations r
        where r.availability_id=a.id and r.state='CONFIRMED'
      ) + v_task.total_volume_m3 <= a.available_volume_m3
      and (
        select coalesce(sum(r.reserved_packages),0)
        from public.logistics_rsg_capacity_reservations r
        where r.availability_id=a.id and r.state='CONFIRMED'
      ) + v_task.package_count <= a.available_packages
  ),
  inserted as (
    insert into public.logistics_last_mile_matches(
      task_id,availability_id,rsg_profile_id,state
    )
    select
      v_task.id,e.availability_id,e.rsg_profile_id,'OFFERED'
    from eligible e
    on conflict (task_id,availability_id) do nothing
    returning id
  )
  select count(*) into v_inserted from inserted;

  insert into public.logistics_last_mile_match_events(
    match_id,event_type,reason_code
  )
  select m.id,'OFFERED','AUTO_MATCH_COMMUNITY_CAPACITY'
  from public.logistics_last_mile_matches m
  where m.task_id=v_task.id
    and m.state='OFFERED'
    and not exists(
      select 1
      from public.logistics_last_mile_match_events e
      where e.match_id=m.id and e.event_type='OFFERED'
    );

  if exists(
    select 1
    from public.logistics_last_mile_matches m
    where m.task_id=v_task.id and m.state='OFFERED'
  ) then
    update public.logistics_last_mile_tasks
       set state='OFFERED'
     where id=v_task.id
       and state in ('PENDING','RECOVERY');
  end if;

  return jsonb_build_object(
    'task_id',v_task.id,
    'status','REFRESHED',
    'offered',v_inserted
  );
end;
$$;

create or replace function public.tc_create_last_mile_task(
  p_origin_location_public_id text,
  p_package_public_ids text[],
  p_earliest_ready_at timestamptz default null,
  p_latest_delivery_at timestamptz default null
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_origin public.operational_locations%rowtype;
  v_requested integer;
  v_resolved integer;
  v_destination_version uuid;
  v_destination_count integer;
  v_package_ids uuid[];
  v_package_string text;
  v_task_key text;
  v_task uuid;
  v_task_public text;
  v_weight numeric;
  v_volume numeric;
  v_cold boolean;
  v_fragile boolean;
  v_refresh jsonb;
begin
  if p_package_public_ids is null or cardinality(p_package_public_ids)<1 then
    raise exception using errcode='P0001', message='TC_EMPTY_EVENT_PACKAGE_SET';
  end if;

  select * into v_origin
  from public.operational_locations o
  where o.public_id=upper(btrim(coalesce(p_origin_location_public_id,'')))
    and o.active and o.network_enabled;

  if v_origin.id is null or v_origin.owner_profile_id is null then
    raise exception using errcode='P0001', message='TC_LAST_MILE_ORIGIN_NODE_INVALID';
  end if;

  select count(distinct upper(btrim(x)))
    into v_requested
  from unnest(p_package_public_ids) x
  where nullif(btrim(x),'') is not null;

  select
    array_agg(p.id order by p.public_id),
    count(*),
    string_agg(p.public_id,'|' order by p.public_id),
    sum(p.weight_kg),
    sum(p.volume_m3),
    bool_or(p.requires_cold_chain),
    bool_or(p.requires_fragile_handling)
  into
    v_package_ids,v_resolved,v_package_string,
    v_weight,v_volume,v_cold,v_fragile
  from public.packages p
  where p.public_id in (
    select distinct upper(btrim(x))
    from unnest(p_package_public_ids) x
    where nullif(btrim(x),'') is not null
  )
    and p.current_custodian_id=v_origin.owner_profile_id;

  if v_requested<1 or v_resolved<>v_requested then
    raise exception using errcode='P0001', message='TC_LAST_MILE_PACKAGE_NOT_AT_ORIGIN';
  end if;

  select count(distinct o.destination_contract_id),min(o.destination_contract_id)
    into v_destination_count,v_destination_version
  from public.packages p
  join public.sub_orders so on so.id=p.sub_order_id
  join public.orders o on o.id=so.order_id
  where p.id=any(v_package_ids);

  if v_destination_count<>1 or v_destination_version is null then
    raise exception using errcode='P0001', message='TC_LAST_MILE_SINGLE_PRIVATE_DESTINATION_REQUIRED';
  end if;

  if not exists(
    select 1
    from public.logistics_destination_versions dsv
    join public.private_destination_snapshots pds
      on pds.id=dsv.private_snapshot_id
    join public.service_coverage sc
      on sc.community_id=dsv.community_id
     and sc.is_active
     and sc.home_delivery_available
    where dsv.id=v_destination_version
      and dsv.target_kind='PRIVATE_LOCATION'
  ) then
    raise exception using errcode='P0001', message='TC_HOME_DELIVERY_NOT_AVAILABLE';
  end if;

  if p_latest_delivery_at is not null
     and p_earliest_ready_at is not null
     and p_latest_delivery_at<p_earliest_ready_at then
    raise exception using errcode='P0001', message='TC_LAST_MILE_TIME_WINDOW_INVALID';
  end if;

  v_task_key:=encode(
    extensions.digest(
      convert_to(
        v_origin.id::text||'|'||v_destination_version::text||'|'||v_package_string,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  select t.id,t.public_id into v_task,v_task_public
  from public.logistics_last_mile_tasks t
  where t.task_key=v_task_key;

  if v_task is null then
    insert into public.logistics_last_mile_tasks(
      task_key,origin_operational_location_id,destination_version_id,
      state,total_weight_kg,total_volume_m3,package_count,
      requires_cold_chain,requires_fragile_handling,requires_bulky,
      earliest_ready_at,latest_delivery_at
    ) values(
      v_task_key,v_origin.id,v_destination_version,
      'PENDING',coalesce(v_weight,0),coalesce(v_volume,0),v_resolved,
      coalesce(v_cold,false),coalesce(v_fragile,false),false,
      p_earliest_ready_at,p_latest_delivery_at
    )
    returning id,public_id into v_task,v_task_public;

    insert into public.logistics_last_mile_task_packages(task_id,package_id)
    select v_task,unnest(v_package_ids);
  end if;

  v_refresh:=public.tc_refresh_last_mile_matches(v_task);

  return jsonb_build_object(
    'task_public_id',v_task_public,
    'task_id',v_task,
    'match_refresh',v_refresh
  );
end;
$$;

create or replace function public.tc_respond_last_mile_match(
  p_match_id uuid,
  p_rsg_profile_id uuid,
  p_action text,
  p_reason_code text default null
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_action text:=upper(btrim(coalesce(p_action,'')));
  v_match public.logistics_last_mile_matches%rowtype;
  v_task public.logistics_last_mile_tasks%rowtype;
  v_reservation uuid;
  v_assignment uuid;
begin
  if v_action not in ('ACCEPT','REJECT') then
    raise exception using errcode='P0001', message='TC_LAST_MILE_MATCH_ACTION_INVALID';
  end if;

  select * into v_match
  from public.logistics_last_mile_matches m
  where m.id=p_match_id
  for update;

  if v_match.id is null then
    raise exception using errcode='P0001', message='TC_LAST_MILE_MATCH_NOT_FOUND';
  end if;

  if v_match.rsg_profile_id is distinct from p_rsg_profile_id then
    raise exception using errcode='P0001', message='TC_LAST_MILE_MATCH_RSG_FORBIDDEN';
  end if;

  if not exists(
    select 1 from public.profiles p
    where p.id=p_rsg_profile_id
      and p.profile_type='RSG'
      and p.status='active'
  ) then
    raise exception using errcode='P0001', message='TC_RSG_PROFILE_INACTIVE';
  end if;

  if v_match.state='ACCEPTED' then
    select a.id into v_assignment
    from public.logistics_last_mile_assignments a
    where a.match_id=v_match.id;

    return jsonb_build_object(
      'match_public_id',v_match.public_id,
      'state','ACCEPTED',
      'assignment_id',v_assignment,
      'idempotent',true
    );
  end if;

  if v_match.state<>'OFFERED' then
    raise exception using errcode='P0001', message='TC_LAST_MILE_MATCH_ALREADY_RESOLVED';
  end if;

  if v_action='REJECT' then
    update public.logistics_last_mile_matches
       set state='REJECTED',
           responded_at=now(),
           updated_at=now()
     where id=v_match.id;

    insert into public.logistics_last_mile_match_events(
      match_id,event_type,actor_profile_id,reason_code
    ) values(
      v_match.id,'REJECTED',p_rsg_profile_id,
      nullif(btrim(coalesce(p_reason_code,'')),'')
    );

    return jsonb_build_object(
      'match_public_id',v_match.public_id,
      'state','REJECTED',
      'idempotent',false
    );
  end if;

  select * into v_task
  from public.logistics_last_mile_tasks t
  where t.id=v_match.task_id
  for update;

  if v_task.state not in ('PENDING','OFFERED','RECOVERY') then
    raise exception using errcode='P0001', message='TC_LAST_MILE_TASK_NOT_ASSIGNABLE';
  end if;

  if exists(
    select 1
    from public.logistics_last_mile_matches m
    where m.task_id=v_task.id
      and m.state='ACCEPTED'
      and m.id<>v_match.id
  ) then
    raise exception using errcode='P0001', message='TC_LAST_MILE_TASK_ALREADY_ACCEPTED';
  end if;

  insert into public.logistics_rsg_capacity_reservations(
    availability_id,task_id,
    reserved_weight_kg,reserved_volume_m3,reserved_packages,
    state,idempotency_key
  ) values(
    v_match.availability_id,v_task.id,
    v_task.total_weight_kg,v_task.total_volume_m3,v_task.package_count,
    'CONFIRMED','LMM:'||v_match.public_id
  )
  returning id into v_reservation;

  update public.logistics_last_mile_matches
     set state='ACCEPTED',
         capacity_reservation_id=v_reservation,
         responded_at=now(),
         updated_at=now()
   where id=v_match.id;

  insert into public.logistics_last_mile_assignments(
    task_id,match_id,rsg_profile_id,capacity_reservation_id,state
  ) values(
    v_task.id,v_match.id,p_rsg_profile_id,v_reservation,'ACTIVE'
  )
  returning id into v_assignment;

  update public.logistics_last_mile_tasks
     set state='ASSIGNED'
   where id=v_task.id;

  insert into public.logistics_last_mile_match_events(
    match_id,event_type,actor_profile_id,reason_code,
    metadata
  ) values(
    v_match.id,'ACCEPTED',p_rsg_profile_id,
    nullif(btrim(coalesce(p_reason_code,'')),''),
    jsonb_build_object(
      'capacity_reservation_id',v_reservation,
      'assignment_id',v_assignment
    )
  );

  return jsonb_build_object(
    'match_public_id',v_match.public_id,
    'state','ACCEPTED',
    'assignment_id',v_assignment,
    'capacity_reservation_id',v_reservation,
    'idempotent',false
  );
end;
$$;

revoke all on function public.tc_refresh_last_mile_matches(uuid)
  from public,anon,authenticated;
revoke all on function public.tc_create_last_mile_task(text,text[],timestamptz,timestamptz)
  from public,anon,authenticated;
revoke all on function public.tc_respond_last_mile_match(uuid,uuid,text,text)
  from public,anon,authenticated;

grant execute on function public.tc_refresh_last_mile_matches(uuid)
  to service_role;
grant execute on function public.tc_create_last_mile_task(text,text[],timestamptz,timestamptz)
  to service_role;
grant execute on function public.tc_respond_last_mile_match(uuid,uuid,text,text)
  to service_role;

comment on function public.tc_refresh_last_mile_matches(uuid) is
'PII-free RSG matching by active home-delivery community, declared local availability, time/handling requirements and remaining capacity.';

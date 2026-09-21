
CREATE OR REPLACE FUNCTION public.tc_respond_last_mile_match(p_match_id uuid, p_rsg_profile_id uuid, p_action text, p_reason_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_action text:=upper(btrim(coalesce(p_action,'')));
  v_match public.logistics_last_mile_matches%rowtype;
  v_task public.logistics_last_mile_tasks%rowtype;
  v_reservation uuid;
  v_assignment uuid;
  v_rec record;
  v_attempt uuid;
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

  update public.logistics_last_mile_tasks
     set state='ASSIGNED'
   where id=v_task.id;

  insert into public.logistics_last_mile_assignments(
    task_id,match_id,rsg_profile_id,capacity_reservation_id,state
  ) values(
    v_task.id,v_match.id,p_rsg_profile_id,v_reservation,'ACTIVE'
  )
  returning id into v_assignment;

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

  for v_rec in
    select td.demand_id
    from public.logistics_last_mile_task_demands td
    where td.task_id=v_task.id
  loop
    update public.logistics_demands
       set state='LAST_MILE_ASSIGNED',
           version=version+1,
           updated_at=now()
     where id=v_rec.demand_id
       and state='AWAITING_LAST_MILE';

    update public.logistics_private_destination_adapters
       set state='LAST_MILE_ASSIGNED',
           last_mile_task_id=v_task.id,
           updated_at=now()
     where demand_id=v_rec.demand_id
       and state<>'COMPLETED';

    select a.id into v_attempt
    from public.logistics_routing_attempts a
    where a.demand_id=v_rec.demand_id
    order by a.attempt_seq desc
    limit 1;

    if v_attempt is not null then
      perform public.tc_evaluate_logistics_promise(
        v_rec.demand_id,v_attempt
      );
    end if;
  end loop;

  return jsonb_build_object(
    'match_public_id',v_match.public_id,
    'state','ACCEPTED',
    'assignment_id',v_assignment,
    'capacity_reservation_id',v_reservation,
    'idempotent',false
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.tc_apply_last_mile_pickup_receive(p_movement_id uuid, p_package_ids uuid[], p_rsg_profile_id uuid, p_idempotency_key text, p_occurred_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_ids uuid[];
  v_requested integer;
  v_event jsonb;
  v_movement public.movements%rowtype;
  v_assignment public.logistics_last_mile_assignments%rowtype;
  v_rec record;
  v_total integer;
  v_received integer;
  v_version bigint;
begin
  select array_agg(distinct x order by x),count(distinct x)
    into v_ids,v_requested
  from unnest(p_package_ids) x;

  if v_requested is null or v_requested<1 then
    raise exception using errcode='P0001', message='TC_EMPTY_EVENT_PACKAGE_SET';
  end if;

  v_event:=public.tc_internal_event_replay_or_begin(
    p_idempotency_key,'LAST_MILE_PICKUP_RECEIVE',
    p_rsg_profile_id,p_movement_id,p_occurred_at,
    jsonb_build_object('package_ids',to_jsonb(v_ids))
  );

  if coalesce((v_event->>'replay')::boolean,false) then
    select state,version into v_movement.state,v_version
    from public.movements where id=p_movement_id;
    return jsonb_build_object(
      'event_id',v_event->>'event_id',
      'movement_state',v_movement.state,
      'movement_version',v_version,
      'idempotent',true
    );
  end if;

  select * into v_assignment
  from public.logistics_last_mile_assignments a
  where a.movement_id=p_movement_id
    and a.rsg_profile_id=p_rsg_profile_id
    and a.state='ACTIVE'
  for update;

  if v_assignment.id is null then
    raise exception using errcode='P0001', message='TC_RSG_MOVEMENT_FORBIDDEN';
  end if;

  select * into v_movement
  from public.movements mv
  where mv.id=p_movement_id
  for update;

  if v_movement.state<>'TRANSFER_PENDING' then
    raise exception using errcode='P0001', message='TC_LAST_MILE_PICKUP_RELEASE_REQUIRED';
  end if;

  if (
    select count(*)
    from public.logistics_movement_custody_phases h
    where h.movement_id=p_movement_id
      and h.phase='LAST_MILE_PICKUP'
      and h.package_id=any(v_ids)
      and h.to_profile_id=p_rsg_profile_id
      and h.status in ('RELEASED','RECEIVED')
  )<>v_requested then
    raise exception using errcode='P0001', message='TC_LAST_MILE_PICKUP_PHASE_NOT_READY';
  end if;

  for v_rec in
    select h.id,h.package_id,h.status,h.from_profile_id,h.to_profile_id,
           h.release_occurred_at
    from public.logistics_movement_custody_phases h
    where h.movement_id=p_movement_id
      and h.phase='LAST_MILE_PICKUP'
      and h.package_id=any(v_ids)
    order by h.package_id
    for update
  loop
    if v_rec.status='RELEASED' then
      if v_rec.release_occurred_at is not null
         and p_occurred_at<v_rec.release_occurred_at then
        raise exception using errcode='P0001', message='TC_RECEIVE_BEFORE_RELEASE_TIME';
      end if;

      if not exists(
        select 1 from public.packages p
        where p.id=v_rec.package_id
          and p.current_custodian_id=v_rec.from_profile_id
      ) then
        raise exception using errcode='P0001', message='TC_CUSTODY_MISMATCH';
      end if;

      update public.packages
         set current_custodian_id=p_rsg_profile_id,
             state='OUT_FOR_DELIVERY',
             version=version+1
       where id=v_rec.package_id;

      update public.logistics_movement_custody_phases
         set status='RECEIVED',
             receive_event_id=v_event->>'event_id',
             receive_occurred_at=p_occurred_at,
             version=version+1
       where id=v_rec.id;

      insert into public.custody_events(
        package_id,movement_id,from_profile_id,to_profile_id,event_id,occurred_at
      ) values(
        v_rec.package_id,p_movement_id,
        v_rec.from_profile_id,p_rsg_profile_id,
        v_event->>'event_id',p_occurred_at
      );
    end if;
  end loop;

  select count(*) into v_total
  from public.logistics_movement_custody_phases h
  where h.movement_id=p_movement_id
    and h.phase='LAST_MILE_PICKUP';

  select count(*) into v_received
  from public.logistics_movement_custody_phases h
  where h.movement_id=p_movement_id
    and h.phase='LAST_MILE_PICKUP'
    and h.status='RECEIVED';

  if v_total>0 and v_received=v_total then
    update public.movements
       set state='IN_TRANSIT',
           departed_at=coalesce(departed_at,p_occurred_at),
           version=version+1
     where id=p_movement_id
    returning version into v_version;

    update public.logistics_last_mile_tasks
       set state='OUT_FOR_DELIVERY'
     where id=v_assignment.task_id;

    update public.logistics_demands d
       set state='IN_TRANSIT',
           version=version+1,
           updated_at=now()
     where d.id in (
       select td.demand_id
       from public.logistics_last_mile_task_demands td
       where td.task_id=v_assignment.task_id
     )
       and d.state not in ('DELIVERED','CANCELLED');
  else
    select version into v_version from public.movements where id=p_movement_id;
  end if;

  perform public.tc_finish_internal_logistics_event(
    v_event->>'event_id',
    case when v_received=v_total and v_total>0 then 'IN_TRANSIT' else 'TRANSFER_PENDING' end,
    v_version,
    jsonb_build_object(
      'phase','LAST_MILE_PICKUP','action','RECEIVE',
      'received_count',v_received,'expected_count',v_total
    )
  );

  return jsonb_build_object(
    'event_id',v_event->>'event_id',
    'received_count',v_received,
    'expected_count',v_total,
    'movement_state',case when v_received=v_total and v_total>0 then 'IN_TRANSIT' else 'TRANSFER_PENDING' end,
    'movement_version',v_version,
    'idempotent',false
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.tc_apply_last_mile_delivery_confirmation(p_movement_id uuid, p_package_ids uuid[], p_rsg_profile_id uuid, p_evidence_public_ids text[], p_idempotency_key text, p_occurred_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_ids uuid[];
  v_requested integer;
  v_event jsonb;
  v_assignment public.logistics_last_mile_assignments%rowtype;
  v_movement public.movements%rowtype;
  v_rec record;
  v_total integer;
  v_delivered integer;
  v_version bigint;
  v_evidence_ids text[];
begin
  select array_agg(distinct x order by x),count(distinct x)
    into v_ids,v_requested
  from unnest(p_package_ids) x;

  select array_agg(distinct upper(btrim(x)) order by upper(btrim(x)))
    into v_evidence_ids
  from unnest(p_evidence_public_ids) x
  where nullif(btrim(x),'') is not null;

  if v_requested is null or v_requested<1
     or v_evidence_ids is null
     or cardinality(v_evidence_ids)<1 then
    raise exception using errcode='P0001', message='TC_LAST_MILE_DELIVERY_EVIDENCE_REQUIRED';
  end if;

  v_event:=public.tc_internal_event_replay_or_begin(
    p_idempotency_key,'LAST_MILE_DELIVERY_CONFIRMED',
    p_rsg_profile_id,p_movement_id,p_occurred_at,
    jsonb_build_object(
      'package_ids',to_jsonb(v_ids),
      'evidence_public_ids',to_jsonb(v_evidence_ids)
    )
  );

  if coalesce((v_event->>'replay')::boolean,false) then
    select state,version into v_movement.state,v_version
    from public.movements where id=p_movement_id;

    return jsonb_build_object(
      'event_id',v_event->>'event_id',
      'movement_state',v_movement.state,
      'movement_version',v_version,
      'idempotent',true
    );
  end if;

  select * into v_assignment
  from public.logistics_last_mile_assignments a
  where a.movement_id=p_movement_id
    and a.rsg_profile_id=p_rsg_profile_id
    and a.state='ACTIVE'
  for update;

  if v_assignment.id is null then
    raise exception using errcode='P0001', message='TC_RSG_MOVEMENT_FORBIDDEN';
  end if;

  select * into v_movement
  from public.movements mv
  where mv.id=p_movement_id
  for update;

  if v_movement.state not in ('IN_TRANSIT','ARRIVED') then
    raise exception using errcode='P0001', message='TC_LAST_MILE_DELIVERY_STATE_INVALID';
  end if;

  if (
    select count(*)
    from public.logistics_movement_custody_phases h
    where h.movement_id=p_movement_id
      and h.phase='LAST_MILE_DELIVERY'
      and h.package_id=any(v_ids)
      and h.from_profile_id=p_rsg_profile_id
  )<>v_requested then
    raise exception using errcode='P0001', message='TC_PACKAGE_NOT_IN_MOVEMENT';
  end if;

  if exists(
    select 1
    from unnest(v_ids) p(package_id)
    where not exists(
      select 1
      from public.evidence e
      where e.package_id=p.package_id
        and e.movement_id=p_movement_id
        and e.uploader_profile_id=p_rsg_profile_id
        and e.evidence_type in ('LAST_MILE_DELIVERY_PHOTO','LAST_MILE_SIGNATURE_IMAGE')
        and e.status in ('UPLOADED','VERIFIED','RETAINED')
        and e.public_id=any(v_evidence_ids)
    )
  ) then
    raise exception using errcode='P0001', message='TC_LAST_MILE_PACKAGE_EVIDENCE_MISSING';
  end if;

  for v_rec in
    select h.id,h.package_id,h.status,h.from_profile_id,h.to_profile_id
    from public.logistics_movement_custody_phases h
    where h.movement_id=p_movement_id
      and h.phase='LAST_MILE_DELIVERY'
      and h.package_id=any(v_ids)
    order by h.package_id
    for update
  loop
    if v_rec.status='PLANNED' then
      if not exists(
        select 1 from public.packages p
        where p.id=v_rec.package_id
          and p.current_custodian_id=p_rsg_profile_id
      ) then
        raise exception using errcode='P0001', message='TC_CUSTODY_MISMATCH';
      end if;

      update public.packages
         set current_custodian_id=v_rec.to_profile_id,
             state='DELIVERED',
             version=version+1
       where id=v_rec.package_id;

      update public.logistics_movement_custody_phases
         set status='RECEIVED',
             release_event_id=v_event->>'event_id',
             receive_event_id=v_event->>'event_id',
             release_occurred_at=p_occurred_at,
             receive_occurred_at=p_occurred_at,
             version=version+1
       where id=v_rec.id;

      insert into public.custody_events(
        package_id,movement_id,from_profile_id,to_profile_id,event_id,occurred_at
      ) values(
        v_rec.package_id,p_movement_id,
        p_rsg_profile_id,v_rec.to_profile_id,
        v_event->>'event_id',p_occurred_at
      );
    end if;
  end loop;

  select count(*) into v_total
  from public.logistics_movement_custody_phases h
  where h.movement_id=p_movement_id
    and h.phase='LAST_MILE_DELIVERY';

  select count(*) into v_delivered
  from public.logistics_movement_custody_phases h
  where h.movement_id=p_movement_id
    and h.phase='LAST_MILE_DELIVERY'
    and h.status='RECEIVED';

  if v_total>0 and v_delivered=v_total then
    update public.movements
       set state='COMPLETED',
           arrived_at=coalesce(arrived_at,p_occurred_at),
           completed_at=coalesce(completed_at,p_occurred_at),
           version=version+1
     where id=p_movement_id
    returning version into v_version;

    update public.logistics_last_mile_tasks
       set state='DELIVERED'
     where id=v_assignment.task_id;

    update public.logistics_last_mile_assignments
       set state='COMPLETED',
           updated_at=now()
     where id=v_assignment.id;

    update public.logistics_rsg_capacity_reservations
       set state='CONSUMED',
           updated_at=now()
     where id=v_assignment.capacity_reservation_id
       and state='CONFIRMED';

    update public.logistics_demands d
       set state='DELIVERED',
           version=version+1,
           updated_at=now()
     where d.id in (
       select td.demand_id
       from public.logistics_last_mile_task_demands td
       where td.task_id=v_assignment.task_id
     )
       and d.state<>'CANCELLED';

    update public.logistics_private_destination_adapters a
       set state='COMPLETED',
           updated_at=now()
     where a.demand_id in (
       select td.demand_id
       from public.logistics_last_mile_task_demands td
       where td.task_id=v_assignment.task_id
     );
  else
    select version into v_version from public.movements where id=p_movement_id;
  end if;

  perform public.tc_finish_internal_logistics_event(
    v_event->>'event_id',
    case when v_delivered=v_total and v_total>0 then 'COMPLETED' else v_movement.state end,
    v_version,
    jsonb_build_object(
      'phase','LAST_MILE_DELIVERY',
      'delivered_count',v_delivered,
      'expected_count',v_total,
      'evidence_public_ids',to_jsonb(v_evidence_ids)
    )
  );

  return jsonb_build_object(
    'event_id',v_event->>'event_id',
    'delivered_count',v_delivered,
    'expected_count',v_total,
    'movement_state',case when v_delivered=v_total and v_total>0 then 'COMPLETED' else v_movement.state end,
    'movement_version',v_version,
    'idempotent',false
  );
end;
$function$
;

revoke all on function public.tc_respond_last_mile_match(uuid,uuid,text,text)
  from public,anon,authenticated;
revoke all on function public.tc_apply_last_mile_pickup_receive(uuid,uuid[],uuid,text,timestamptz)
  from public,anon,authenticated;
revoke all on function public.tc_apply_last_mile_delivery_confirmation(uuid,uuid[],uuid,text[],text,timestamptz)
  from public,anon,authenticated;

grant execute on function public.tc_respond_last_mile_match(uuid,uuid,text,text)
  to service_role;
grant execute on function public.tc_apply_last_mile_pickup_receive(uuid,uuid[],uuid,text,timestamptz)
  to service_role;
grant execute on function public.tc_apply_last_mile_delivery_confirmation(uuid,uuid[],uuid,text[],text,timestamptz)
  to service_role;

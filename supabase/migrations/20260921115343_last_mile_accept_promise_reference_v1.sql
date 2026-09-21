
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
  v_eval uuid;
  v_eval_ids uuid[] := '{}'::uuid[];
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
      v_eval:=public.tc_evaluate_logistics_promise(
        v_rec.demand_id,v_attempt
      );
      v_eval_ids:=array_append(v_eval_ids,v_eval);
    end if;
  end loop;

  return jsonb_build_object(
    'match_public_id',v_match.public_id,
    'state','ACCEPTED',
    'assignment_id',v_assignment,
    'capacity_reservation_id',v_reservation,
    'promise_evaluation_ids',to_jsonb(v_eval_ids),
    'idempotent',false
  );
end;
$function$
;

revoke all on function public.tc_respond_last_mile_match(uuid,uuid,text,text)
  from public,anon,authenticated;
grant execute on function public.tc_respond_last_mile_match(uuid,uuid,text,text)
  to service_role;

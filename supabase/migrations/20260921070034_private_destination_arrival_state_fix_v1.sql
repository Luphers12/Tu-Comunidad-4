
CREATE OR REPLACE FUNCTION public.tc_apply_canonical_arrival_receive_once(p_movement_id uuid, p_package_ids uuid[], p_actor_profile_id uuid, p_idempotency_key text, p_occurred_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_movement public.movements%rowtype;
  v_event jsonb;
  v_event_id text;
  v_requested integer;
  v_rec record;
  v_total integer;
  v_received integer;
  v_version bigint;
  v_profile_type text;
  v_package_state text;
  v_next_movements jsonb;
begin
  select * into v_movement
  from public.movements m
  where m.id=p_movement_id
  for update;

  if v_movement.state<>'TRANSFER_PENDING' then
    raise exception using errcode='P0001', message='TC_ARRIVAL_RECEIVE_RELEASE_REQUIRED';
  end if;

  if p_package_ids is null or cardinality(p_package_ids)<1 then
    raise exception using errcode='P0001', message='TC_EMPTY_EVENT_PACKAGE_SET';
  end if;

  select p.profile_type into v_profile_type
  from public.profiles p
  where p.id=p_actor_profile_id and p.status='active';

  if v_profile_type is null then
    raise exception using errcode='P0001', message='TC_RECEIVER_PROFILE_INACTIVE';
  end if;

  v_package_state:=case v_profile_type
    when 'PTC' then 'AT_PTC'
    when 'TIE' then 'READY'
    when 'VEN' then 'READY'
    when 'RSG' then 'OUT_FOR_DELIVERY'
    else 'READY'
  end;

  select count(distinct x) into v_requested from unnest(p_package_ids) x;

  if (
    select count(*)
    from public.logistics_movement_custody_phases h
    where h.movement_id=p_movement_id
      and h.phase='ARRIVAL'
      and h.package_id=any(p_package_ids)
      and h.to_profile_id=p_actor_profile_id
      and h.status in ('RELEASED','RECEIVED')
  )<>v_requested then
    raise exception using errcode='P0001', message='TC_ARRIVAL_RECEIVE_ACTOR_OR_RELEASE_MISMATCH';
  end if;

  v_event:=public.tc_begin_internal_logistics_event(
    p_idempotency_key,'CANONICAL_ARRIVAL_RECEIVE',
    p_actor_profile_id,p_movement_id,p_occurred_at,
    jsonb_build_object('package_ids',to_jsonb(p_package_ids))
  );
  v_event_id:=v_event->>'event_id';

  for v_rec in
    select h.id,h.package_id,h.status,h.receive_event_id,
           h.from_profile_id,h.to_profile_id,h.release_occurred_at
    from public.logistics_movement_custody_phases h
    where h.movement_id=p_movement_id
      and h.phase='ARRIVAL'
      and h.package_id=any(p_package_ids)
    order by h.package_id
    for update
  loop
    if v_rec.status='RELEASED' then
      if v_rec.release_occurred_at is not null and p_occurred_at<v_rec.release_occurred_at then
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
         set current_custodian_id=v_rec.to_profile_id,
             state=v_package_state,
             version=version+1
       where id=v_rec.package_id;

      update public.logistics_movement_custody_phases
         set status='RECEIVED',
             receive_event_id=v_event_id,
             receive_occurred_at=p_occurred_at,
             version=version+1
       where id=v_rec.id;

      insert into public.custody_events(
        package_id,movement_id,from_profile_id,to_profile_id,event_id,occurred_at
      ) values(
        v_rec.package_id,p_movement_id,
        v_rec.from_profile_id,v_rec.to_profile_id,
        v_event_id,p_occurred_at
      );
    elsif v_rec.status='RECEIVED' and v_rec.receive_event_id=v_event_id then
      null;
    else
      raise exception using errcode='P0001', message='TC_ARRIVAL_RECEIVE_INVALID_PHASE_STATE';
    end if;
  end loop;

  select count(*) into v_total
  from public.logistics_movement_custody_phases h
  where h.movement_id=p_movement_id and h.phase='ARRIVAL';

  select count(*) into v_received
  from public.logistics_movement_custody_phases h
  where h.movement_id=p_movement_id and h.phase='ARRIVAL' and h.status='RECEIVED';

  if v_received=v_total and v_total>0 then
    update public.movements
       set state='COMPLETED',
           completed_at=coalesce(completed_at,p_occurred_at),
           version=version+1
     where id=p_movement_id
     returning version into v_version;

    update public.logistics_capacity_reservations r
       set state='CONSUMED',updated_at=now()
     where r.id in (
       select md.capacity_reservation_id
       from public.logistics_movement_demands md
       where md.movement_id=p_movement_id
     )
       and r.state='CONFIRMED';

    update public.logistics_execution_plans ep
       set state='COMPLETED',updated_at=now()
     where ep.id in (
       select he.execution_plan_id
       from public.logistics_hop_executions he
       where he.movement_id=p_movement_id
         and not exists(
           select 1
           from public.logistics_hop_executions he2
           join public.movements m2 on m2.id=he2.movement_id
           where he2.execution_plan_id=he.execution_plan_id
             and he2.id<>he.id
             and m2.state<>'COMPLETED'
         )
     );

    update public.logistics_demands d
       set state=case
           when exists(
             select 1
             from public.logistics_execution_plans ep
             where ep.demand_id=d.id and ep.state='COMPLETED'
           )
           and exists(
             select 1
             from public.logistics_private_destination_adapters a
             where a.demand_id=d.id
               and a.state<>'COMPLETED'
           ) then 'AWAITING_LAST_MILE'
           when exists(
             select 1
             from public.logistics_execution_plans ep
             where ep.demand_id=d.id and ep.state='COMPLETED'
           ) then 'DELIVERED'
           else 'IN_TRANSIT'
         end,
         version=version+1,
         updated_at=now()
     where d.id in (
       select md.demand_id
       from public.logistics_movement_demands md
       where md.movement_id=p_movement_id
     )
       and d.state<>'CANCELLED';

    select coalesce(jsonb_agg(jsonb_build_object(
      'execution_plan_id',ep.id,
      'movement_id',m2.id,
      'movement_public_id',m2.public_id,
      'hop_sequence',h2.hop_sequence,
      'origin_operational_location_id',m2.origin_operational_location_id,
      'destination_operational_location_id',m2.destination_operational_location_id
    ) order by h2.hop_sequence),'[]'::jsonb)
    into v_next_movements
    from public.logistics_hop_executions he
    join public.logistics_execution_plans ep on ep.id=he.execution_plan_id
    join public.logistics_routing_hops h on h.id=he.routing_hop_id
    join public.logistics_hop_executions he2
      on he2.execution_plan_id=he.execution_plan_id
    join public.logistics_routing_hops h2
      on h2.id=he2.routing_hop_id
     and h2.hop_sequence=h.hop_sequence+1
    join public.movements m2 on m2.id=he2.movement_id
    where he.movement_id=p_movement_id;
  else
    select version into v_version from public.movements where id=p_movement_id;
    v_next_movements:='[]'::jsonb;
  end if;

  perform public.tc_finish_internal_logistics_event(
    v_event_id,
    case when v_received=v_total and v_total>0 then 'COMPLETED' else 'TRANSFER_PENDING' end,
    v_version,
    jsonb_build_object(
      'phase','ARRIVAL','action','RECEIVE',
      'received_count',v_received,'expected_count',v_total,
      'next_movements',v_next_movements
    )
  );

  return jsonb_build_object(
    'event_id',v_event_id,
    'processed_package_count',v_requested,
    'received_count',v_received,
    'expected_count',v_total,
    'movement_state',case when v_received=v_total and v_total>0 then 'COMPLETED' else 'TRANSFER_PENDING' end,
    'movement_version',v_version,
    'next_movements',v_next_movements
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.tc_reconcile_execution_plan_completion(p_execution_plan_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_plan public.logistics_execution_plans%rowtype;
  v_effective_count integer;
  v_completed_count integer;
  v_new_state text;
  v_private_adapter uuid;
  v_demand_state text;
begin
  select * into v_plan
  from public.logistics_execution_plans ep
  where ep.id=p_execution_plan_id
  for update;

  if v_plan.id is null then
    raise exception using errcode='P0001', message='TC_EXECUTION_PLAN_NOT_FOUND';
  end if;

  select count(*) into v_effective_count
  from public.logistics_hop_executions he
  where he.execution_plan_id=v_plan.id
    and not exists(
      select 1 from public.logistics_hop_executions nx
      where nx.supersedes_hop_execution_id=he.id
    );

  select count(*) into v_completed_count
  from public.logistics_hop_executions he
  join public.movements m on m.id=he.movement_id
  where he.execution_plan_id=v_plan.id
    and not exists(
      select 1 from public.logistics_hop_executions nx
      where nx.supersedes_hop_execution_id=he.id
    )
    and m.state='COMPLETED';

  if v_effective_count>0 and v_completed_count=v_effective_count then
    update public.logistics_execution_plans
       set state='COMPLETED',updated_at=now()
     where id=v_plan.id
       and state<>'CANCELLED';

    select a.id into v_private_adapter
    from public.logistics_private_destination_adapters a
    where a.demand_id=v_plan.demand_id;

    if v_private_adapter is not null then
      update public.logistics_private_destination_adapters
         set state='AWAITING_LAST_MILE',
             updated_at=now()
       where id=v_private_adapter
         and state not in ('COMPLETED','RECOVERY');

      update public.logistics_demands
         set state='AWAITING_LAST_MILE',
             version=version+1,
             updated_at=now()
       where id=v_plan.demand_id
         and state<>'CANCELLED';

      v_demand_state:='AWAITING_LAST_MILE';
    else
      update public.logistics_demands
         set state='DELIVERED',
             version=version+1,
             updated_at=now()
       where id=v_plan.demand_id
         and state not in ('DELIVERED','CANCELLED');

      v_demand_state:='DELIVERED';
    end if;

    v_new_state:='COMPLETED';
  else
    update public.logistics_execution_plans
       set state='ACTIVE',updated_at=now()
     where id=v_plan.id
       and state<>'CANCELLED';

    if exists(
      select 1
      from public.logistics_hop_executions he
      join public.movements m on m.id=he.movement_id
      where he.execution_plan_id=v_plan.id
        and not exists(
          select 1 from public.logistics_hop_executions nx
          where nx.supersedes_hop_execution_id=he.id
        )
        and m.state in ('IN_TRANSIT','ARRIVED','TRANSFER_PENDING','COMPLETED')
    ) then
      update public.logistics_demands
         set state='IN_TRANSIT',version=version+1,updated_at=now()
       where id=v_plan.demand_id
         and state not in ('DELIVERED','CANCELLED','ROUTING_EXCEPTION');
    end if;

    v_new_state:='ACTIVE';
  end if;

  return jsonb_build_object(
    'execution_plan_id',v_plan.id,
    'plan_state',v_new_state,
    'effective_hop_count',v_effective_count,
    'completed_hop_count',v_completed_count,
    'demand_state',coalesce(v_demand_state,(
      select d.state from public.logistics_demands d where d.id=v_plan.demand_id
    ))
  );
end;
$function$
;

revoke all on function public.tc_apply_canonical_arrival_receive_once(uuid,uuid[],uuid,text,timestamptz)
  from public,anon,authenticated;
revoke all on function public.tc_reconcile_execution_plan_completion(uuid)
  from public,anon,authenticated;

grant execute on function public.tc_apply_canonical_arrival_receive_once(uuid,uuid[],uuid,text,timestamptz)
  to service_role;
grant execute on function public.tc_reconcile_execution_plan_completion(uuid)
  to service_role;

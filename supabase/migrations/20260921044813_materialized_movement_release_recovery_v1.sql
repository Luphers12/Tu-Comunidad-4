
create or replace function public.tc_release_materialized_movement_before_departure(
  p_movement_id uuid,
  p_reason_code text
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_movement public.movements%rowtype;
  v_case uuid;
  v_case_key text;
  v_rec record;
  v_demand uuid;
  v_attempt uuid;
  v_hop_count integer;
  v_active_accepted integer;
  v_new_state text;
  v_released integer := 0;
  v_refreshed jsonb := '[]'::jsonb;
begin
  select * into v_movement
  from public.movements m
  where m.id=p_movement_id
  for update;

  if v_movement.id is null then
    raise exception using errcode='P0001', message='TC_MOVEMENT_NOT_FOUND';
  end if;

  if v_movement.state not in ('PLANNED','ASSIGNED','READY') then
    raise exception using errcode='P0001', message='TC_MATERIALIZED_MOVEMENT_ALREADY_STARTED';
  end if;

  if exists(
    select 1
    from public.logistics_movement_custody_phases h
    where h.movement_id=p_movement_id
      and h.status<>'PLANNED'
  ) or exists(
    select 1 from public.custody_events c where c.movement_id=p_movement_id
  ) then
    raise exception using errcode='P0001', message='TC_MATERIALIZED_MOVEMENT_CUSTODY_ALREADY_STARTED';
  end if;

  v_case_key:='MATERIALIZED_CANDIDATE_FAILED:'||p_movement_id::text;

  insert into public.logistics_recovery_cases(
    case_key,case_type,movement_id
  ) values(
    v_case_key,'MATERIALIZED_CANDIDATE_FAILED',p_movement_id
  )
  on conflict (case_key) do nothing
  returning id into v_case;

  if v_case is null then
    select id into v_case
    from public.logistics_recovery_cases
    where case_key=v_case_key;
  else
    insert into public.logistics_recovery_events(
      recovery_case_id,event_type,reason_code,
      metadata
    ) values(
      v_case,'OPENED',
      nullif(btrim(coalesce(p_reason_code,'')),''),
      jsonb_build_object('movement_id',p_movement_id)
    );
  end if;

  for v_rec in
    select distinct
      he.execution_plan_id,
      he.routing_hop_id,
      he.match_id,
      he.capacity_reservation_id,
      ep.routing_attempt_id,
      ep.demand_id
    from public.logistics_hop_executions he
    join public.logistics_execution_plans ep on ep.id=he.execution_plan_id
    where he.movement_id=p_movement_id
      and not exists(
        select 1
        from public.logistics_hop_executions nx
        where nx.supersedes_hop_execution_id=he.id
      )
  loop
    update public.logistics_capacity_reservations
       set state='RELEASED',updated_at=now()
     where id=v_rec.capacity_reservation_id
       and state in ('HELD','CONFIRMED');

    if found then
      v_released:=v_released+1;
    end if;

    update public.logistics_matches
       set state='INVALIDATED',
           responded_at=coalesce(responded_at,now()),
           updated_at=now()
     where id=v_rec.match_id
       and state='ACCEPTED';

    if found then
      insert into public.logistics_match_events(
        match_id,event_type,reason_code,
        metadata
      ) values(
        v_rec.match_id,'INVALIDATED',
        coalesce(nullif(btrim(coalesce(p_reason_code,'')),''),'MATERIALIZED_CANDIDATE_FAILED'),
        jsonb_build_object(
          'movement_id',p_movement_id,
          'recovery_case_id',v_case,
          'materialized',true
        )
      );
    end if;

    insert into public.logistics_recovery_events(
      recovery_case_id,event_type,reason_code,metadata
    ) values(
      v_case,'CANDIDATE_RELEASED',
      coalesce(nullif(btrim(coalesce(p_reason_code,'')),''),'MATERIALIZED_CANDIDATE_FAILED'),
      jsonb_build_object(
        'execution_plan_id',v_rec.execution_plan_id,
        'routing_hop_id',v_rec.routing_hop_id,
        'match_id',v_rec.match_id,
        'capacity_reservation_id',v_rec.capacity_reservation_id
      )
    );

    select count(*) into v_hop_count
    from public.logistics_routing_hops h
    where h.routing_attempt_id=v_rec.routing_attempt_id;

    select count(distinct m.routing_hop_id)
      into v_active_accepted
    from public.logistics_matches m
    join public.logistics_capacity_reservations r
      on r.id=m.capacity_reservation_id
    where m.routing_attempt_id=v_rec.routing_attempt_id
      and m.state='ACCEPTED'
      and r.state in ('HELD','CONFIRMED','CONSUMED');

    v_new_state:=case
      when v_active_accepted=0 then 'READY_FOR_ROUTING'
      when v_active_accepted<v_hop_count then 'PARTIALLY_ASSIGNED'
      else 'ASSIGNED'
    end;

    update public.logistics_demands
       set state=v_new_state,
           routing_exception_code=null,
           routing_exception_detail=null,
           version=version+1,
           updated_at=now()
     where id=v_rec.demand_id
       and state not in ('DELIVERED','CANCELLED');

    perform public.tc_evaluate_logistics_promise(
      v_rec.demand_id,v_rec.routing_attempt_id
    );

    v_refreshed:=v_refreshed||jsonb_build_array(
      public.tc_refresh_logistics_matches(v_rec.routing_attempt_id)
    );
  end loop;

  update public.movements
     set state='CANCELLED',
         version=version+1
   where id=p_movement_id;

  return jsonb_build_object(
    'movement_id',p_movement_id,
    'recovery_case_id',v_case,
    'released_reservation_count',v_released,
    'match_refreshes',v_refreshed
  );
end;
$$;

revoke all on function public.tc_release_materialized_movement_before_departure(uuid,text)
  from public,anon,authenticated;
grant execute on function public.tc_release_materialized_movement_before_departure(uuid,text)
  to service_role;

comment on function public.tc_release_materialized_movement_before_departure(uuid,text) is
'Movement-level recovery before physical departure. Shared MOV users are released together because a failed real TRIP/segment affects every demand consolidated on that MOV. No custody mutation is permitted once a phase has progressed.';

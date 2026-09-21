
create or replace function public.tc_reconcile_execution_plan_completion(
  p_execution_plan_id uuid
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_plan public.logistics_execution_plans%rowtype;
  v_effective_count integer;
  v_completed_count integer;
  v_new_state text;
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

    update public.logistics_demands
       set state='DELIVERED',version=version+1,updated_at=now()
     where id=v_plan.demand_id
       and state not in ('DELIVERED','CANCELLED');

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
    'completed_hop_count',v_completed_count
  );
end;
$$;

create or replace function public.tc_continue_execution_after_movement(
  p_movement_id uuid
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_movement public.movements%rowtype;
  v_rec record;
  v_next_hop public.logistics_routing_hops%rowtype;
  v_next_he public.logistics_hop_executions%rowtype;
  v_next_movement public.movements%rowtype;
  v_owner uuid;
  v_demand_pkg_count integer;
  v_ready_pkg_count integer;
  v_action text;
  v_reason text;
  v_key text;
  v_case uuid;
  v_results jsonb := '[]'::jsonb;
  v_completion jsonb;
begin
  select * into v_movement
  from public.movements m
  where m.id=p_movement_id;

  if v_movement.id is null then
    raise exception using errcode='P0001', message='TC_MOVEMENT_NOT_FOUND';
  end if;

  if v_movement.state<>'COMPLETED' then
    raise exception using errcode='P0001', message='TC_CONTINUATION_MOVEMENT_NOT_COMPLETED';
  end if;

  for v_rec in
    select
      he.execution_plan_id,
      he.routing_hop_id,
      h.hop_sequence,
      ep.routing_attempt_id,
      ep.demand_id
    from public.logistics_hop_executions he
    join public.logistics_execution_plans ep on ep.id=he.execution_plan_id
    join public.logistics_routing_hops h on h.id=he.routing_hop_id
    where he.movement_id=p_movement_id
      and not exists(
        select 1 from public.logistics_hop_executions nx
        where nx.supersedes_hop_execution_id=he.id
      )
  loop
    v_completion:=public.tc_reconcile_execution_plan_completion(v_rec.execution_plan_id);

    select * into v_next_hop
    from public.logistics_routing_hops h
    where h.routing_attempt_id=v_rec.routing_attempt_id
      and h.hop_sequence=v_rec.hop_sequence+1;

    if v_next_hop.id is null then
      v_action:='PLAN_COMPLETE';
      v_reason:=null;
      v_next_he:=null;
      v_next_movement:=null;
    else
      select he.* into v_next_he
      from public.logistics_hop_executions he
      where he.execution_plan_id=v_rec.execution_plan_id
        and he.routing_hop_id=v_next_hop.id
        and not exists(
          select 1 from public.logistics_hop_executions nx
          where nx.supersedes_hop_execution_id=he.id
        )
      order by he.created_at desc,he.id desc
      limit 1;

      if v_next_he.id is null then
        v_action:='RECANDIDATE_REQUIRED';
        v_reason:='NEXT_HOP_NOT_MATERIALIZED';
        v_next_movement:=null;
      else
        select * into v_next_movement
        from public.movements m
        where m.id=v_next_he.movement_id;

        if v_next_movement.origin_operational_location_id
           is distinct from v_movement.destination_operational_location_id then
          v_action:='RECOVERY_REQUIRED';
          v_reason:='CHAIN_DISCONTINUITY';

          insert into public.logistics_recovery_cases(
            case_key,case_type,movement_id,execution_plan_id,routing_hop_id
          ) values(
            'CHAIN_DISCONTINUITY:'||v_rec.execution_plan_id::text||':'||v_next_hop.id::text,
            'CHAIN_DISCONTINUITY',
            p_movement_id,v_rec.execution_plan_id,v_next_hop.id
          )
          on conflict (case_key) do nothing
          returning id into v_case;

          if v_case is not null then
            insert into public.logistics_recovery_events(
              recovery_case_id,event_type,reason_code,metadata
            ) values(
              v_case,'OPENED','CHAIN_DISCONTINUITY',
              jsonb_build_object(
                'completed_movement_id',p_movement_id,
                'next_movement_id',v_next_movement.id
              )
            );
          end if;
        elsif v_next_movement.state='CANCELLED' then
          v_action:='RECANDIDATE_REQUIRED';
          v_reason:='NEXT_MOVEMENT_CANCELLED';
        elsif v_next_movement.state in ('IN_TRANSIT','ARRIVED','TRANSFER_PENDING','COMPLETED') then
          v_action:='ALREADY_IN_PROGRESS';
          v_reason:=null;
        elsif v_next_movement.state in ('PLANNED','ASSIGNED','READY') then
          perform public.tc_prepare_canonical_movement_custody(v_next_movement.id);

          select o.owner_profile_id into v_owner
          from public.operational_locations o
          where o.id=v_next_movement.origin_operational_location_id;

          select count(*) into v_demand_pkg_count
          from public.logistics_demand_packages dp
          where dp.demand_id=v_rec.demand_id;

          select count(*) into v_ready_pkg_count
          from public.logistics_demand_packages dp
          join public.packages p on p.id=dp.package_id
          where dp.demand_id=v_rec.demand_id
            and p.current_custodian_id=v_owner;

          if v_ready_pkg_count=v_demand_pkg_count and v_demand_pkg_count>0 then
            v_action:='CONTINUE_READY';
            v_reason:=null;
          else
            v_action:='WAITING_FOR_PACKAGES';
            v_reason:='PACKAGE_NOT_AT_NEXT_ORIGIN';
          end if;
        else
          v_action:='RECOVERY_REQUIRED';
          v_reason:='NEXT_MOVEMENT_STATE_UNSUPPORTED';
        end if;
      end if;
    end if;

    v_key:='CONT:'||p_movement_id::text||':'||v_rec.execution_plan_id::text||':'||
      coalesce(v_next_hop.id::text,'END')||':'||v_action;

    insert into public.logistics_continuation_events(
      execution_plan_id,completed_movement_id,
      next_hop_execution_id,next_movement_id,
      action,reason_code,idempotency_key,
      metadata
    ) values(
      v_rec.execution_plan_id,p_movement_id,
      v_next_he.id,v_next_movement.id,
      v_action,v_reason,v_key,
      jsonb_build_object(
        'completed_hop_sequence',v_rec.hop_sequence,
        'next_hop_sequence',v_next_hop.hop_sequence,
        'plan_completion',v_completion
      )
    )
    on conflict (idempotency_key) do nothing;

    v_results:=v_results||jsonb_build_array(jsonb_build_object(
      'execution_plan_id',v_rec.execution_plan_id,
      'demand_id',v_rec.demand_id,
      'action',v_action,
      'reason_code',v_reason,
      'next_hop_id',v_next_hop.id,
      'next_hop_execution_id',v_next_he.id,
      'next_movement_id',v_next_movement.id
    ));
  end loop;

  return jsonb_build_object(
    'completed_movement_id',p_movement_id,
    'continuations',v_results
  );
end;
$$;

create or replace function public.tc_apply_canonical_arrival_receive(
  p_movement_id uuid,
  p_package_ids uuid[],
  p_actor_profile_id uuid,
  p_idempotency_key text,
  p_occurred_at timestamptz default now()
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_gate jsonb;
  v_state text;
  v_version bigint;
  v_result jsonb;
  v_plan record;
  v_completion jsonb := '[]'::jsonb;
begin
  v_gate:=public.tc_internal_event_replay_or_begin(
    p_idempotency_key,'CANONICAL_ARRIVAL_RECEIVE',
    p_actor_profile_id,p_movement_id,p_occurred_at,
    jsonb_build_object('package_ids',to_jsonb(p_package_ids))
  );

  if coalesce((v_gate->>'replay')::boolean,false) then
    select state,version into v_state,v_version
    from public.movements where id=p_movement_id;

    for v_plan in
      select distinct he.execution_plan_id
      from public.logistics_hop_executions he
      where he.movement_id=p_movement_id
    loop
      v_completion:=v_completion||jsonb_build_array(
        public.tc_reconcile_execution_plan_completion(v_plan.execution_plan_id)
      );
    end loop;

    return jsonb_build_object(
      'event_id',v_gate->>'event_id',
      'movement_state',v_state,
      'movement_version',v_version,
      'idempotent',true,
      'plan_completion',v_completion
    );
  end if;

  v_result:=public.tc_apply_canonical_arrival_receive_once(
    p_movement_id,p_package_ids,p_actor_profile_id,p_idempotency_key,p_occurred_at
  );

  for v_plan in
    select distinct he.execution_plan_id
    from public.logistics_hop_executions he
    where he.movement_id=p_movement_id
  loop
    v_completion:=v_completion||jsonb_build_array(
      public.tc_reconcile_execution_plan_completion(v_plan.execution_plan_id)
    );
  end loop;

  return v_result||jsonb_build_object(
    'idempotent',false,
    'plan_completion',v_completion
  );
end;
$$;

revoke all on function public.tc_reconcile_execution_plan_completion(uuid)
  from public,anon,authenticated;
revoke all on function public.tc_continue_execution_after_movement(uuid)
  from public,anon,authenticated;
revoke all on function public.tc_apply_canonical_arrival_receive(uuid,uuid[],uuid,text,timestamptz)
  from public,anon,authenticated;

grant execute on function public.tc_reconcile_execution_plan_completion(uuid)
  to service_role;
grant execute on function public.tc_continue_execution_after_movement(uuid)
  to service_role;
grant execute on function public.tc_apply_canonical_arrival_receive(uuid,uuid[],uuid,text,timestamptz)
  to service_role;


create or replace function public.tc_release_match_before_execution(
  p_match_id uuid,
  p_reason_code text
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_match public.logistics_matches%rowtype;
  v_reservation public.logistics_capacity_reservations%rowtype;
  v_hop_count integer;
  v_active_accepted integer;
  v_new_state text;
  v_refresh jsonb;
  v_eval uuid;
begin
  select * into v_match
  from public.logistics_matches m
  where m.id=p_match_id
  for update;

  if v_match.id is null then
    raise exception using errcode='P0001', message='TC_MATCH_NOT_FOUND';
  end if;

  if v_match.state <> 'ACCEPTED' then
    raise exception using errcode='P0001', message='TC_MATCH_NOT_ACCEPTED';
  end if;

  if exists (
    select 1
    from public.logistics_hop_executions he
    where he.match_id=v_match.id
  ) then
    raise exception using errcode='P0001', message='TC_MATCH_ALREADY_MATERIALIZED';
  end if;

  select * into v_reservation
  from public.logistics_capacity_reservations r
  where r.id=v_match.capacity_reservation_id
  for update;

  if v_reservation.id is null
     or v_reservation.state not in ('HELD','CONFIRMED') then
    raise exception using errcode='P0001', message='TC_MATCH_RESERVATION_NOT_RELEASABLE';
  end if;

  update public.logistics_capacity_reservations
     set state='RELEASED',
         updated_at=now()
   where id=v_reservation.id;

  update public.logistics_matches
     set state='INVALIDATED',
         responded_at=coalesce(responded_at,now()),
         updated_at=now()
   where id=v_match.id;

  insert into public.logistics_match_events(
    match_id,event_type,reason_code,metadata
  ) values(
    v_match.id,'INVALIDATED',
    coalesce(nullif(btrim(coalesce(p_reason_code,'')),''),'PRE_EXECUTION_RELEASE'),
    jsonb_build_object(
      'capacity_reservation_id',v_reservation.id,
      'released_before_execution',true
    )
  );

  select count(*) into v_hop_count
  from public.logistics_routing_hops h
  where h.routing_attempt_id=v_match.routing_attempt_id;

  select count(distinct m.routing_hop_id)
    into v_active_accepted
  from public.logistics_matches m
  join public.logistics_capacity_reservations r
    on r.id=m.capacity_reservation_id
  where m.routing_attempt_id=v_match.routing_attempt_id
    and m.state='ACCEPTED'
    and r.state in ('CONFIRMED','CONSUMED');

  v_new_state := case
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
   where id=v_match.demand_id
     and state not in ('DELIVERED','CANCELLED');

  v_eval := public.tc_evaluate_logistics_promise(
    v_match.demand_id,
    v_match.routing_attempt_id
  );

  v_refresh := public.tc_refresh_logistics_matches(
    v_match.routing_attempt_id
  );

  return jsonb_build_object(
    'match_id',v_match.id,
    'released_reservation_id',v_reservation.id,
    'demand_state',v_new_state,
    'promise_evaluation_id',v_eval,
    'match_refresh',v_refresh
  );
end;
$$;

revoke all on function public.tc_release_match_before_execution(uuid,text)
  from public,anon,authenticated;
grant execute on function public.tc_release_match_before_execution(uuid,text)
  to service_role;

comment on function public.tc_release_match_before_execution(uuid,text) is
'Pre-materialization failure/recovery only: releases confirmed capacity, invalidates the accepted candidate, preserves append-only commitment history, and re-candidates locally on the same routing attempt. In-transit/materialized recovery is deliberately a separate later contract.';

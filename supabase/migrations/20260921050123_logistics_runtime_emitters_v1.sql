
create or replace function public.tc_enqueue_logistics_runtime_event(
  p_event_key text,
  p_event_type text,
  p_entity_type text,
  p_entity_id uuid,
  p_demand_id uuid default null,
  p_trip_id uuid default null,
  p_match_id uuid default null,
  p_movement_id uuid default null,
  p_reconciliation_run_id uuid default null,
  p_payload jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if nullif(btrim(coalesce(p_event_key,'')),'') is null
     or nullif(btrim(coalesce(p_entity_type,'')),'') is null
     or p_entity_id is null then
    raise exception using errcode='P0001', message='TC_RUNTIME_EVENT_INVALID';
  end if;

  insert into public.logistics_runtime_outbox(
    event_key,event_type,entity_type,entity_id,
    demand_id,trip_id,match_id,movement_id,reconciliation_run_id,payload
  ) values(
    p_event_key,upper(btrim(p_event_type)),upper(btrim(p_entity_type)),p_entity_id,
    p_demand_id,p_trip_id,p_match_id,p_movement_id,p_reconciliation_run_id,
    coalesce(p_payload,'{}'::jsonb)
  )
  on conflict (event_key) do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id
    from public.logistics_runtime_outbox
    where event_key=p_event_key;
  end if;

  return v_id;
end;
$$;

revoke all on function public.tc_enqueue_logistics_runtime_event(
  text,text,text,uuid,uuid,uuid,uuid,uuid,uuid,jsonb
) from public,anon,authenticated,service_role;

create or replace function public.tc_emit_demand_runtime_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.state in ('READY_FOR_ROUTING','ROUTING','PARTIALLY_ASSIGNED')
     and (
       tg_op='INSERT'
       or old.state is distinct from new.state
     ) then
    perform public.tc_enqueue_logistics_runtime_event(
      'DEMAND_ROUTABLE:'||new.id::text||':'||new.version::text||':'||new.state,
      'DEMAND_ROUTABLE','LOGISTICS_DEMAND',new.id,
      new.id,null,null,null,null,
      jsonb_build_object('state',new.state,'version',new.version)
    );
  end if;
  return new;
end;
$$;

create or replace function public.tc_emit_trip_runtime_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.state in ('PUBLISHED','ACCEPTING')
     and old.state is distinct from new.state then
    perform public.tc_enqueue_logistics_runtime_event(
      'TRIP_AVAILABLE:'||new.id::text||':'||new.version::text||':'||new.state,
      'TRIP_AVAILABLE','LOGISTICS_TRIP',new.id,
      null,new.id,null,null,null,
      jsonb_build_object('state',new.state,'version',new.version)
    );
  end if;
  return new;
end;
$$;

create or replace function public.tc_emit_match_runtime_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.state='ACCEPTED'
     and old.state is distinct from new.state then
    perform public.tc_enqueue_logistics_runtime_event(
      'MATCH_ACCEPTED:'||new.id::text||':'||new.capacity_reservation_id::text,
      'MATCH_ACCEPTED','LOGISTICS_MATCH',new.id,
      new.demand_id,new.trip_id,new.id,null,null,
      jsonb_build_object(
        'routing_attempt_id',new.routing_attempt_id,
        'routing_hop_id',new.routing_hop_id,
        'capacity_reservation_id',new.capacity_reservation_id
      )
    );
  end if;
  return new;
end;
$$;

create or replace function public.tc_emit_movement_runtime_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.state='COMPLETED'
     and old.state is distinct from new.state then
    perform public.tc_enqueue_logistics_runtime_event(
      'MOVEMENT_COMPLETED:'||new.id::text||':'||new.version::text,
      'MOVEMENT_COMPLETED','MOVEMENT',new.id,
      null,new.logistics_trip_id,null,new.id,null,
      jsonb_build_object('state',new.state,'version',new.version)
    );
  end if;
  return new;
end;
$$;

create or replace function public.tc_emit_reconciliation_runtime_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status='MISMATCH' then
    perform public.tc_enqueue_logistics_runtime_event(
      'ARRIVAL_MISMATCH:'||new.id::text,
      'ARRIVAL_MISMATCH','RECONCILIATION_RUN',new.id,
      null,null,null,new.movement_id,new.id,
      jsonb_build_object(
        'manifest_id',new.manifest_id,
        'missing_count',new.missing_count,
        'unexpected_count',new.unexpected_count
      )
    );
  end if;
  return new;
end;
$$;

revoke all on function public.tc_emit_demand_runtime_event() from public,anon,authenticated,service_role;
revoke all on function public.tc_emit_trip_runtime_event() from public,anon,authenticated,service_role;
revoke all on function public.tc_emit_match_runtime_event() from public,anon,authenticated,service_role;
revoke all on function public.tc_emit_movement_runtime_event() from public,anon,authenticated,service_role;
revoke all on function public.tc_emit_reconciliation_runtime_event() from public,anon,authenticated,service_role;

create trigger logistics_demands_runtime_outbox
after insert or update of state on public.logistics_demands
for each row execute function public.tc_emit_demand_runtime_event();

create trigger logistics_trips_runtime_outbox
after update of state on public.logistics_trips
for each row execute function public.tc_emit_trip_runtime_event();

create trigger logistics_matches_runtime_outbox
after update of state on public.logistics_matches
for each row execute function public.tc_emit_match_runtime_event();

create trigger movements_runtime_outbox
after update of state on public.movements
for each row execute function public.tc_emit_movement_runtime_event();

create trigger logistics_reconciliation_runtime_outbox
after insert on public.logistics_movement_reconciliation_runs
for each row execute function public.tc_emit_reconciliation_runtime_event();

comment on function public.tc_enqueue_logistics_runtime_event(
  text,text,text,uuid,uuid,uuid,uuid,uuid,uuid,jsonb
) is
'Private trigger-only transactional outbox insert. Heavy logistics orchestration is deliberately deferred to the runtime worker.';

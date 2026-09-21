
create table public.logistics_routing_transition_events (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('RTEV'),
  demand_id uuid not null references public.logistics_demands(id) on delete restrict,
  routing_attempt_id uuid references public.logistics_routing_attempts(id) on delete restrict,
  from_operational_location_id uuid not null references public.operational_locations(id) on delete restrict,
  to_operational_location_id uuid not null references public.operational_locations(id) on delete restrict,
  transition_kind text not null
    check (transition_kind in ('PLANNED','RECOVERY','RETURN','OBSERVED')),
  loop_detected boolean not null default false,
  loop_code text,
  metadata jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  check (public_id like 'RTEV-%'),
  check (from_operational_location_id <> to_operational_location_id),
  check (
    (loop_detected and loop_code is not null)
    or
    (not loop_detected and loop_code is null)
  )
);

create index logistics_routing_transition_events_demand_idx
  on public.logistics_routing_transition_events(demand_id,occurred_at desc,created_at desc);

create or replace function public.tc_record_routing_transition(
  p_demand_id uuid,
  p_from_operational_location_id uuid,
  p_to_operational_location_id uuid,
  p_transition_kind text,
  p_routing_attempt_id uuid default null,
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_kind text := upper(btrim(coalesce(p_transition_kind,'')));
  v_prev1 record;
  v_prev2 record;
  v_loop boolean := false;
  v_code text;
  v_event uuid;
begin
  if v_kind not in ('PLANNED','RECOVERY','RETURN','OBSERVED') then
    raise exception using errcode='P0001', message='TC_ROUTING_TRANSITION_KIND_INVALID';
  end if;

  if p_from_operational_location_id=p_to_operational_location_id then
    raise exception using errcode='P0001', message='TC_ROUTING_SELF_TRANSITION_INVALID';
  end if;

  select x.from_operational_location_id,x.to_operational_location_id
    into v_prev1
  from (
    select e.from_operational_location_id,e.to_operational_location_id
    from public.logistics_routing_transition_events e
    where e.demand_id=p_demand_id
    order by e.occurred_at desc,e.created_at desc,e.id desc
    limit 1
  ) x;

  select x.from_operational_location_id,x.to_operational_location_id
    into v_prev2
  from (
    select e.from_operational_location_id,e.to_operational_location_id,
           row_number() over(order by e.occurred_at desc,e.created_at desc,e.id desc) rn
    from public.logistics_routing_transition_events e
    where e.demand_id=p_demand_id
  ) x
  where x.rn=2;

  if v_prev2.from_operational_location_id is not null
     and v_prev2.from_operational_location_id=p_from_operational_location_id
     and v_prev2.to_operational_location_id=p_to_operational_location_id
     and v_prev1.from_operational_location_id=p_to_operational_location_id
     and v_prev1.to_operational_location_id=p_from_operational_location_id then
    v_loop := true;
    v_code := 'LOOP_DETECTED_OSCILLATION';
  end if;

  insert into public.logistics_routing_transition_events(
    demand_id,routing_attempt_id,
    from_operational_location_id,to_operational_location_id,
    transition_kind,loop_detected,loop_code,metadata
  ) values(
    p_demand_id,p_routing_attempt_id,
    p_from_operational_location_id,p_to_operational_location_id,
    v_kind,v_loop,v_code,coalesce(p_metadata,'{}'::jsonb)
  ) returning id into v_event;

  if v_loop then
    update public.logistics_demands
       set state='ROUTING_EXCEPTION',
           routing_exception_code='LOOP_DETECTED',
           routing_exception_detail=jsonb_build_object(
             'transition_event_id',v_event,
             'loop_code',v_code,
             'from_operational_location_id',p_from_operational_location_id,
             'to_operational_location_id',p_to_operational_location_id
           ),
           version=version+1,
           updated_at=now()
     where id=p_demand_id
       and state not in ('DELIVERED','CANCELLED');
  end if;

  return v_event;
end;
$$;

create trigger logistics_routing_transition_events_append_only
before update or delete on public.logistics_routing_transition_events
for each row execute function public.tc_guard_logistics_append_only();

alter table public.logistics_routing_transition_events enable row level security;
revoke all on public.logistics_routing_transition_events from public,anon,authenticated;
grant select,insert on public.logistics_routing_transition_events to service_role;

revoke all on function public.tc_record_routing_transition(uuid,uuid,uuid,text,uuid,jsonb)
  from public,anon,authenticated;
grant execute on function public.tc_record_routing_transition(uuid,uuid,uuid,text,uuid,jsonb)
  to service_role;

comment on table public.logistics_routing_transition_events is
'Append-only routing progression/recovery evidence. A→B, B→A, A→B is classified as LOOP_DETECTED_OSCILLATION. One explicit return/recovery reversal is not itself a loop.';

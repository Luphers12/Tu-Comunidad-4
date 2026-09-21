
create table public.logistics_routing_commitments (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('RCM'),
  routing_attempt_id uuid not null references public.logistics_routing_attempts(id) on delete restrict,
  routing_hop_id uuid not null references public.logistics_routing_hops(id) on delete restrict,
  capacity_reservation_id uuid not null references public.logistics_capacity_reservations(id) on delete restrict,
  committed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (routing_attempt_id,routing_hop_id),
  unique (capacity_reservation_id),
  check (public_id like 'RCM-%')
);

create table public.logistics_promise_evaluations (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('PME'),
  demand_id uuid not null references public.logistics_demands(id) on delete restrict,
  routing_attempt_id uuid references public.logistics_routing_attempts(id) on delete restrict,
  promise_state text not null
    check (promise_state in (
      'UNREACHABLE',
      'ADAPTER_REQUIRED',
      'STRUCTURAL_ONLY',
      'CURRENT_EXECUTABLE',
      'END_TO_END_COMMITTED',
      'ROUTING_EXCEPTION',
      'ALREADY_AT_DESTINATION'
    )),
  structural_reachable boolean not null,
  current_executable boolean not null,
  end_to_end_committed boolean not null,
  no_trip_now boolean not null,
  reason_code text,
  detail jsonb not null default '{}'::jsonb,
  evaluated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  check (public_id like 'PME-%'),
  check (not no_trip_now or structural_reachable),
  check (not end_to_end_committed or current_executable),
  check (not current_executable or structural_reachable)
);

create index logistics_promise_evaluations_demand_idx
  on public.logistics_promise_evaluations(demand_id,evaluated_at desc);

create or replace function public.tc_evaluate_logistics_promise(
  p_demand_id uuid,
  p_routing_attempt_id uuid default null
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_attempt uuid;
  v_result text;
  v_structural boolean;
  v_current boolean;
  v_no_trip boolean;
  v_hops integer;
  v_committed integer;
  v_state text;
  v_reason text;
  v_eval uuid;
begin
  if p_routing_attempt_id is null then
    select a.id,a.result_code,a.structural_reachable,a.current_executable,a.no_trip_now,a.hop_count
      into v_attempt,v_result,v_structural,v_current,v_no_trip,v_hops
    from public.logistics_routing_attempts a
    where a.demand_id=p_demand_id
    order by a.attempted_at desc,a.created_at desc,a.id desc
    limit 1;
  else
    select a.id,a.result_code,a.structural_reachable,a.current_executable,a.no_trip_now,a.hop_count
      into v_attempt,v_result,v_structural,v_current,v_no_trip,v_hops
    from public.logistics_routing_attempts a
    where a.id=p_routing_attempt_id
      and a.demand_id=p_demand_id;
  end if;

  if v_attempt is null then
    raise exception using errcode='P0001', message='TC_ROUTING_ATTEMPT_NOT_FOUND';
  end if;

  select count(*) into v_committed
  from public.logistics_routing_hops h
  join public.logistics_routing_commitments c
    on c.routing_hop_id=h.id
   and c.routing_attempt_id=h.routing_attempt_id
  join public.logistics_capacity_reservations r
    on r.id=c.capacity_reservation_id
  where h.routing_attempt_id=v_attempt
    and r.state in ('CONFIRMED','CONSUMED');

  if v_result='STRUCTURAL_UNREACHABLE' then
    v_state := 'UNREACHABLE';
    v_reason := 'STRUCTURAL_UNREACHABLE';
  elsif v_result='ADAPTER_REQUIRED' then
    v_state := 'ADAPTER_REQUIRED';
    v_reason := 'ENDPOINT_ADAPTER_REQUIRED';
  elsif v_result='LOOP_DETECTED' then
    v_state := 'ROUTING_EXCEPTION';
    v_reason := 'LOOP_DETECTED';
  elsif v_result='ALREADY_AT_DESTINATION' then
    v_state := 'ALREADY_AT_DESTINATION';
    v_structural := true;
    v_current := true;
    v_no_trip := false;
  elsif v_current and v_hops > 0 and v_committed=v_hops then
    v_state := 'END_TO_END_COMMITTED';
  elsif v_current then
    v_state := 'CURRENT_EXECUTABLE';
  else
    v_state := 'STRUCTURAL_ONLY';
    v_reason := 'NO_TRIP_NOW';
  end if;

  insert into public.logistics_promise_evaluations(
    demand_id,routing_attempt_id,promise_state,
    structural_reachable,current_executable,end_to_end_committed,no_trip_now,
    reason_code,detail
  ) values(
    p_demand_id,v_attempt,v_state,
    v_structural,v_current,
    (v_state='END_TO_END_COMMITTED'),
    v_no_trip,
    v_reason,
    jsonb_build_object(
      'hop_count',v_hops,
      'committed_hop_count',v_committed,
      'routing_result',v_result
    )
  ) returning id into v_eval;

  return v_eval;
end;
$$;

create or replace function public.tc_commit_routing_attempt(
  p_routing_attempt_id uuid
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_attempt public.logistics_routing_attempts%rowtype;
  v_hop public.logistics_routing_hops%rowtype;
  v_demand public.logistics_demands%rowtype;
  v_package_count integer;
  v_reservation uuid;
  v_eval uuid;
begin
  select * into v_attempt
  from public.logistics_routing_attempts a
  where a.id=p_routing_attempt_id;

  if v_attempt.id is null then
    raise exception using errcode='P0001', message='TC_ROUTING_ATTEMPT_NOT_FOUND';
  end if;

  if v_attempt.result_code <> 'CURRENT_EXECUTABLE'
     or not v_attempt.current_executable then
    raise exception using errcode='P0001', message='TC_ROUTING_ATTEMPT_NOT_COMMITTABLE';
  end if;

  select * into v_demand
  from public.logistics_demands d
  where d.id=v_attempt.demand_id
  for update;

  select count(*) into v_package_count
  from public.logistics_demand_packages dp
  where dp.demand_id=v_demand.id;

  if v_package_count < 1 then
    raise exception using errcode='P0001', message='TC_ROUTING_DEMAND_HAS_NO_PACKAGES';
  end if;

  for v_hop in
    select *
    from public.logistics_routing_hops h
    where h.routing_attempt_id=v_attempt.id
    order by h.hop_sequence
  loop
    if v_hop.selected_trip_id is null then
      raise exception using errcode='P0001', message='TC_ROUTING_HOP_NO_TRIP';
    end if;

    select c.capacity_reservation_id into v_reservation
    from public.logistics_routing_commitments c
    where c.routing_attempt_id=v_attempt.id
      and c.routing_hop_id=v_hop.id;

    if v_reservation is null then
      insert into public.logistics_capacity_reservations(
        trip_id,demand_id,board_stop_sequence,alight_stop_sequence,
        reserved_weight_kg,reserved_volume_m3,reserved_packages,
        state,idempotency_key
      ) values(
        v_hop.selected_trip_id,
        v_demand.id,
        v_hop.board_stop_sequence,
        v_hop.alight_stop_sequence,
        v_demand.total_weight_kg,
        v_demand.total_volume_m3,
        v_package_count,
        'CONFIRMED',
        'RTA:'||v_attempt.public_id||':HOP:'||v_hop.hop_sequence::text
      )
      returning id into v_reservation;

      insert into public.logistics_routing_commitments(
        routing_attempt_id,routing_hop_id,capacity_reservation_id
      ) values(
        v_attempt.id,v_hop.id,v_reservation
      );
    end if;
  end loop;

  update public.logistics_demands
     set state='ASSIGNED',
         routing_exception_code=null,
         routing_exception_detail=null,
         version=version+1,
         updated_at=now()
   where id=v_demand.id
     and state not in ('DELIVERED','CANCELLED');

  v_eval := public.tc_evaluate_logistics_promise(
    v_demand.id,
    v_attempt.id
  );

  return v_eval;
end;
$$;

create trigger logistics_routing_commitments_append_only
before update or delete on public.logistics_routing_commitments
for each row execute function public.tc_guard_logistics_append_only();

create trigger logistics_promise_evaluations_append_only
before update or delete on public.logistics_promise_evaluations
for each row execute function public.tc_guard_logistics_append_only();

alter table public.logistics_routing_commitments enable row level security;
alter table public.logistics_promise_evaluations enable row level security;

revoke all on public.logistics_routing_commitments from public,anon,authenticated;
revoke all on public.logistics_promise_evaluations from public,anon,authenticated;
grant select,insert on public.logistics_routing_commitments to service_role;
grant select,insert on public.logistics_promise_evaluations to service_role;

revoke all on function public.tc_evaluate_logistics_promise(uuid,uuid) from public,anon,authenticated;
revoke all on function public.tc_commit_routing_attempt(uuid) from public,anon,authenticated;
grant execute on function public.tc_evaluate_logistics_promise(uuid,uuid) to service_role;
grant execute on function public.tc_commit_routing_attempt(uuid) to service_role;

comment on table public.logistics_promise_evaluations is
'Append-only Promise Engine evidence. STRUCTURAL_ONLY means a path exists but no complete current trip set; END_TO_END_COMMITTED means every hop has confirmed/consumed segment capacity. It is not a delivery guarantee.';
comment on table public.logistics_routing_commitments is
'Atomic routing-hop→capacity reservation commitment evidence. Commitment reserves logistics capacity only; it does not create custody or payment state.';

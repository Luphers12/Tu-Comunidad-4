
create table public.logistics_match_requirement_snapshots (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('REQ'),
  demand_id uuid not null references public.logistics_demands(id) on delete restrict,
  routing_attempt_id uuid not null references public.logistics_routing_attempts(id) on delete restrict,
  snapshot_no bigint not null check (snapshot_no >= 1),
  total_weight_kg numeric not null check (total_weight_kg >= 0),
  total_volume_m3 numeric not null check (total_volume_m3 >= 0),
  package_count integer not null check (package_count >= 0),
  requires_cold_chain boolean not null,
  requires_fragile_handling boolean not null,
  required_capability_codes text[] not null default '{}'::text[],
  earliest_ready_at timestamptz,
  latest_delivery_at timestamptz,
  package_requirements jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  unique (routing_attempt_id,snapshot_no),
  check (public_id like 'REQ-%')
);

create table public.logistics_matches (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('MAT'),
  demand_id uuid not null references public.logistics_demands(id) on delete restrict,
  routing_attempt_id uuid not null references public.logistics_routing_attempts(id) on delete restrict,
  routing_hop_id uuid not null references public.logistics_routing_hops(id) on delete restrict,
  requirement_snapshot_id uuid not null references public.logistics_match_requirement_snapshots(id) on delete restrict,
  candidate_kind text not null check (candidate_kind in ('TRIP')),
  trip_id uuid not null references public.logistics_trips(id) on delete restrict,
  board_stop_sequence integer not null,
  alight_stop_sequence integer not null,
  commitment_mode text not null
    check (commitment_mode in ('ACCEPTANCE_REQUIRED','AUTO_ALLOCATABLE')),
  state text not null default 'OFFERED'
    check (state in ('OFFERED','ACCEPTED','REJECTED','EXPIRED','INVALIDATED')),
  capacity_reservation_id uuid references public.logistics_capacity_reservations(id) on delete restrict,
  compatibility jsonb not null default '{}'::jsonb,
  offered_at timestamptz not null default now(),
  responded_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (routing_attempt_id,routing_hop_id,trip_id),
  check (public_id like 'MAT-%'),
  check (board_stop_sequence < alight_stop_sequence),
  check (
    (state='ACCEPTED' and capacity_reservation_id is not null and responded_at is not null)
    or
    (state in ('REJECTED','EXPIRED','INVALIDATED') and responded_at is not null)
    or
    (state='OFFERED' and capacity_reservation_id is null)
  )
);

create table public.logistics_match_events (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('MEV'),
  match_id uuid not null references public.logistics_matches(id) on delete restrict,
  event_type text not null
    check (event_type in ('OFFERED','ACCEPTED','REJECTED','EXPIRED','INVALIDATED')),
  actor_profile_id uuid references public.profiles(id) on delete set null,
  reason_code text,
  metadata jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  check (public_id like 'MEV-%')
);

create index logistics_match_requirement_snapshots_demand_idx
  on public.logistics_match_requirement_snapshots(demand_id,created_at desc);

create index logistics_matches_hop_state_idx
  on public.logistics_matches(routing_hop_id,state,offered_at);

create index logistics_matches_trip_state_idx
  on public.logistics_matches(trip_id,state,offered_at);

create index logistics_matches_demand_idx
  on public.logistics_matches(demand_id,routing_attempt_id,state);

create index logistics_match_events_match_idx
  on public.logistics_match_events(match_id,occurred_at,created_at);

create or replace function public.tc_refresh_logistics_matches(
  p_routing_attempt_id uuid
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_attempt public.logistics_routing_attempts%rowtype;
  v_demand public.logistics_demands%rowtype;
  v_snapshot uuid;
  v_snapshot_no bigint;
  v_package_count integer;
  v_inserted integer := 0;
  v_invalidated integer := 0;
  v_match uuid;
  v_now timestamptz := now();
begin
  select * into v_attempt
  from public.logistics_routing_attempts a
  where a.id=p_routing_attempt_id;

  if v_attempt.id is null then
    raise exception using errcode='P0001', message='TC_ROUTING_ATTEMPT_NOT_FOUND';
  end if;

  if v_attempt.result_code in ('STRUCTURAL_UNREACHABLE','ADAPTER_REQUIRED','LOOP_DETECTED','ALREADY_AT_DESTINATION') then
    return jsonb_build_object(
      'routing_attempt_id',v_attempt.id,
      'offered',0,
      'invalidated',0,
      'status','NO_MATCH_DISCOVERY_FOR_RESULT',
      'result_code',v_attempt.result_code
    );
  end if;

  select * into v_demand
  from public.logistics_demands d
  where d.id=v_attempt.demand_id;

  select count(*) into v_package_count
  from public.logistics_demand_packages dp
  where dp.demand_id=v_demand.id;

  select coalesce(max(s.snapshot_no),0)+1
    into v_snapshot_no
  from public.logistics_match_requirement_snapshots s
  where s.routing_attempt_id=v_attempt.id;

  insert into public.logistics_match_requirement_snapshots(
    demand_id,routing_attempt_id,snapshot_no,
    total_weight_kg,total_volume_m3,package_count,
    requires_cold_chain,requires_fragile_handling,
    required_capability_codes,earliest_ready_at,latest_delivery_at,
    package_requirements
  )
  select
    v_demand.id,
    v_attempt.id,
    v_snapshot_no,
    v_demand.total_weight_kg,
    v_demand.total_volume_m3,
    v_package_count,
    v_demand.requires_cold_chain,
    v_demand.requires_fragile_handling,
    v_demand.required_capability_codes,
    v_demand.earliest_ready_at,
    v_demand.latest_delivery_at,
    coalesce(jsonb_agg(
      jsonb_build_object(
        'package_public_id',p.public_id,
        'weight_kg',p.weight_kg,
        'volume_m3',p.volume_m3,
        'requires_cold_chain',p.requires_cold_chain,
        'requires_fragile_handling',p.requires_fragile_handling,
        'length_cm',p.length_cm,
        'width_cm',p.width_cm,
        'height_cm',p.height_cm,
        'package_form',p.package_form
      )
      order by p.public_id
    ) filter (where p.id is not null),'[]'::jsonb)
  from public.logistics_demand_packages dp
  left join public.packages p on p.id=dp.package_id
  where dp.demand_id=v_demand.id
  returning id into v_snapshot;

  -- Invalidate only unaccepted opportunities that are no longer eligible.
  for v_match in
    select m.id
    from public.logistics_matches m
    join public.logistics_routing_hops h on h.id=m.routing_hop_id
    where m.routing_attempt_id=v_attempt.id
      and m.state='OFFERED'
      and not exists (
        select 1
        from public.logistics_trips t
        join public.logistics_trip_stops s1
          on s1.trip_id=t.id
         and s1.operational_location_id=h.origin_operational_location_id
         and s1.stop_sequence=m.board_stop_sequence
        join public.logistics_trip_stops s2
          on s2.trip_id=t.id
         and s2.operational_location_id=h.destination_operational_location_id
         and s2.stop_sequence=m.alight_stop_sequence
         and s2.stop_sequence>s1.stop_sequence
        join public.logistics_trip_capacity c on c.trip_id=t.id
        where t.id=m.trip_id
          and t.state in ('PUBLISHED','ACCEPTING')
          and (not v_demand.requires_cold_chain or c.accepts_cold_chain)
          and (not v_demand.requires_fragile_handling or c.accepts_fragile)
          and (v_demand.earliest_ready_at is null or t.planned_departure_at >= v_demand.earliest_ready_at)
          and (
            v_demand.latest_delivery_at is null
            or (
              t.planned_arrival_at is not null
              and t.planned_arrival_at <= v_demand.latest_delivery_at
            )
          )
      )
  loop
    update public.logistics_matches
       set state='INVALIDATED',
           responded_at=v_now,
           updated_at=v_now
     where id=v_match;

    insert into public.logistics_match_events(match_id,event_type,reason_code)
    values(v_match,'INVALIDATED','NO_LONGER_ELIGIBLE');

    v_invalidated := v_invalidated + 1;
  end loop;

  with candidates as (
    select
      h.id as routing_hop_id,
      t.id as trip_id,
      s1.stop_sequence as board_stop_sequence,
      s2.stop_sequence as alight_stop_sequence,
      row_number() over(
        partition by h.id,t.id
        order by s1.stop_sequence,s2.stop_sequence
      ) as rn
    from public.logistics_routing_hops h
    join public.logistics_edges e on e.id=h.edge_id
    join public.logistics_trips t
      on t.state in ('PUBLISHED','ACCEPTING')
    join public.logistics_trip_stops s1
      on s1.trip_id=t.id
     and s1.operational_location_id=h.origin_operational_location_id
    join public.logistics_trip_stops s2
      on s2.trip_id=t.id
     and s2.operational_location_id=h.destination_operational_location_id
     and s2.stop_sequence>s1.stop_sequence
    join public.logistics_trip_capacity c on c.trip_id=t.id
    where h.routing_attempt_id=v_attempt.id
      and e.structural_status='ACTIVE'
      and coalesce((
        select ese.state
        from public.logistics_edge_state_events ese
        where ese.edge_id=e.id
          and ese.effective_at <= v_now
        order by ese.effective_at desc,ese.created_at desc,ese.id desc
        limit 1
      ),'CLOSED')='OPEN'
      and (not v_demand.requires_cold_chain or c.accepts_cold_chain)
      and (not v_demand.requires_fragile_handling or c.accepts_fragile)
      and (v_demand.earliest_ready_at is null or t.planned_departure_at >= v_demand.earliest_ready_at)
      and (
        v_demand.latest_delivery_at is null
        or (
          t.planned_arrival_at is not null
          and t.planned_arrival_at <= v_demand.latest_delivery_at
        )
      )
      and not exists (
        select 1
        from public.logistics_demand_packages dp
        join public.packages pkg on pkg.id=dp.package_id
        where dp.demand_id=v_demand.id
          and (
            (e.max_single_package_weight_kg is not null
              and pkg.weight_kg > e.max_single_package_weight_kg)
            or
            (e.max_single_package_volume_m3 is not null
              and pkg.volume_m3 > e.max_single_package_volume_m3)
          )
      )
      and not exists (
        select 1
        from generate_series(s1.stop_sequence,s2.stop_sequence-1) seg(n)
        where
          (
            select coalesce(sum(r.reserved_weight_kg),0)
            from public.logistics_capacity_reservations r
            where r.trip_id=t.id
              and r.state in ('HELD','CONFIRMED')
              and r.board_stop_sequence <= seg.n
              and r.alight_stop_sequence > seg.n
          ) + v_demand.total_weight_kg > c.declared_free_weight_kg
          or
          (
            select coalesce(sum(r.reserved_volume_m3),0)
            from public.logistics_capacity_reservations r
            where r.trip_id=t.id
              and r.state in ('HELD','CONFIRMED')
              and r.board_stop_sequence <= seg.n
              and r.alight_stop_sequence > seg.n
          ) + v_demand.total_volume_m3 > c.declared_free_volume_m3
          or
          (
            select coalesce(sum(r.reserved_packages),0)
            from public.logistics_capacity_reservations r
            where r.trip_id=t.id
              and r.state in ('HELD','CONFIRMED')
              and r.board_stop_sequence <= seg.n
              and r.alight_stop_sequence > seg.n
          ) + v_package_count > c.declared_free_packages
      )
  ),
  inserted as (
    insert into public.logistics_matches(
      demand_id,routing_attempt_id,routing_hop_id,
      requirement_snapshot_id,candidate_kind,trip_id,
      board_stop_sequence,alight_stop_sequence,
      commitment_mode,state,compatibility
    )
    select
      v_demand.id,
      v_attempt.id,
      c.routing_hop_id,
      v_snapshot,
      'TRIP',
      c.trip_id,
      c.board_stop_sequence,
      c.alight_stop_sequence,
      'ACCEPTANCE_REQUIRED',
      'OFFERED',
      jsonb_build_object(
        'exact_declared_points',true,
        'board_stop_sequence',c.board_stop_sequence,
        'alight_stop_sequence',c.alight_stop_sequence,
        'capacity_observed_at',v_now
      )
    from candidates c
    where c.rn=1
    on conflict (routing_attempt_id,routing_hop_id,trip_id)
      do nothing
    returning id
  )
  select count(*) into v_inserted from inserted;

  insert into public.logistics_match_events(match_id,event_type,reason_code)
  select m.id,'OFFERED','AUTO_MATCH_EXACT_DECLARED_POINTS'
  from public.logistics_matches m
  where m.routing_attempt_id=v_attempt.id
    and m.requirement_snapshot_id=v_snapshot
    and m.state='OFFERED'
    and not exists (
      select 1
      from public.logistics_match_events ev
      where ev.match_id=m.id and ev.event_type='OFFERED'
    );

  return jsonb_build_object(
    'routing_attempt_id',v_attempt.id,
    'requirement_snapshot_id',v_snapshot,
    'offered',v_inserted,
    'invalidated',v_invalidated,
    'status','REFRESHED'
  );
end;
$$;

create trigger logistics_match_requirement_snapshots_append_only
before update or delete on public.logistics_match_requirement_snapshots
for each row execute function public.tc_guard_logistics_append_only();

create trigger logistics_match_events_append_only
before update or delete on public.logistics_match_events
for each row execute function public.tc_guard_logistics_append_only();

create trigger logistics_matches_set_updated_at
before update on public.logistics_matches
for each row execute function public.tc_set_updated_at();

alter table public.logistics_match_requirement_snapshots enable row level security;
alter table public.logistics_matches enable row level security;
alter table public.logistics_match_events enable row level security;

revoke all on public.logistics_match_requirement_snapshots from public,anon,authenticated;
revoke all on public.logistics_matches from public,anon,authenticated;
revoke all on public.logistics_match_events from public,anon,authenticated;
grant select,insert on public.logistics_match_requirement_snapshots to service_role;
grant select,insert,update on public.logistics_matches to service_role;
grant select,insert on public.logistics_match_events to service_role;

revoke all on function public.tc_refresh_logistics_matches(uuid)
  from public,anon,authenticated;
grant execute on function public.tc_refresh_logistics_matches(uuid)
  to service_role;

comment on table public.logistics_match_requirement_snapshots is
'PII-free logistics requirement snapshot derived from LGD + PKG physical requirements. Used for candidate discovery; recipient name/address/phone are not stored here.';
comment on table public.logistics_matches is
'Automatic capability/capacity compatibility between one routing hop and a real candidate. TRIP candidates match only exact declared ordered stops. CON uses ACCEPTANCE_REQUIRED.';
comment on table public.logistics_match_events is
'Append-only opportunity lifecycle evidence. Reject/expire/invalidate before commitment is not a custody or performance violation.';

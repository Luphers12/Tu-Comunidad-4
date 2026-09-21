
create table public.logistics_trips (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('TRP'),
  driver_profile_id uuid not null references public.profiles(id) on delete restrict,
  vehicle_id uuid not null references public.vehicles(id) on delete restrict,
  origin_operational_location_id uuid not null references public.operational_locations(id) on delete restrict,
  destination_operational_location_id uuid not null references public.operational_locations(id) on delete restrict,
  source_type text not null default 'DRIVER_DECLARED'
    check (source_type in ('DRIVER_DECLARED','LEGACY_ADAPTER')),
  trip_reason text not null,
  state text not null default 'DRAFT'
    check (state in ('DRAFT','PUBLISHED','ACCEPTING','DEPARTED','COMPLETED','CANCELLED')),
  planned_departure_at timestamptz not null,
  planned_arrival_at timestamptz,
  return_expected_at timestamptz,
  max_detour_km numeric not null default 0 check (max_detour_km >= 0),
  accepted_cargo jsonb not null default '{}'::jsonb,
  conditions jsonb not null default '{}'::jsonb,
  legacy_route_opportunity_id uuid references public.route_opportunities(id) on delete set null,
  legacy_route_assignment_id uuid references public.route_assignments(id) on delete set null,
  published_at timestamptz,
  version bigint not null default 0 check (version >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (public_id like 'TRP-%'),
  check (btrim(trip_reason) <> ''),
  check (origin_operational_location_id <> destination_operational_location_id),
  check (planned_arrival_at is null or planned_arrival_at >= planned_departure_at),
  check (return_expected_at is null or planned_arrival_at is null or return_expected_at >= planned_arrival_at),
  check (source_type <> 'LEGACY_ADAPTER' or legacy_route_opportunity_id is not null)
);

create unique index logistics_trips_legacy_route_assignment_uidx
  on public.logistics_trips(legacy_route_assignment_id)
  where legacy_route_assignment_id is not null;

create index logistics_trips_driver_departure_idx
  on public.logistics_trips(driver_profile_id, planned_departure_at);

create index logistics_trips_origin_departure_idx
  on public.logistics_trips(origin_operational_location_id, planned_departure_at)
  where state in ('PUBLISHED','ACCEPTING');

create table public.logistics_trip_stops (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('TST'),
  trip_id uuid not null references public.logistics_trips(id) on delete restrict,
  stop_sequence integer not null check (stop_sequence > 0),
  operational_location_id uuid not null references public.operational_locations(id) on delete restrict,
  stop_kind text not null
    check (stop_kind in ('START','WAYPOINT','END','RETURN')),
  planned_arrival_at timestamptz,
  planned_departure_at timestamptz,
  detour_limit_km numeric not null default 0 check (detour_limit_km >= 0),
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (trip_id, stop_sequence),
  check (public_id like 'TST-%'),
  check (planned_departure_at is null or planned_arrival_at is null or planned_departure_at >= planned_arrival_at)
);

create index logistics_trip_stops_location_idx
  on public.logistics_trip_stops(operational_location_id, trip_id, stop_sequence);

create or replace function public.tc_validate_logistics_trip()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_route_id uuid;
  v_driver uuid;
  v_vehicle uuid;
begin
  if not exists (
    select 1 from public.profiles p
    where p.id=new.driver_profile_id
      and p.profile_type='CON'
      and p.status='active'
  ) then
    raise exception using errcode='P0001', message='TC_TRIP_DRIVER_NOT_ACTIVE_CON';
  end if;

  if not exists (
    select 1 from public.vehicles v
    where v.id=new.vehicle_id and v.is_active
  ) then
    raise exception using errcode='P0001', message='TC_TRIP_VEHICLE_NOT_ACTIVE';
  end if;

  if not exists (
    select 1
    from public.driver_vehicle_authorizations a
    where a.driver_profile_id=new.driver_profile_id
      and a.vehicle_id=new.vehicle_id
      and a.is_active
      and a.valid_from <= new.planned_departure_at
      and (a.valid_until is null or a.valid_until >= new.planned_departure_at)
  ) then
    raise exception using errcode='P0001', message='TC_TRIP_DRIVER_VEHICLE_NOT_AUTHORIZED';
  end if;

  if not exists (
    select 1 from public.operational_locations o
    where o.id=new.origin_operational_location_id
      and o.active and o.network_enabled
  ) then
    raise exception using errcode='P0001', message='TC_TRIP_ORIGIN_NOT_NETWORK_NODE';
  end if;

  if not exists (
    select 1 from public.operational_locations o
    where o.id=new.destination_operational_location_id
      and o.active and o.network_enabled
  ) then
    raise exception using errcode='P0001', message='TC_TRIP_DESTINATION_NOT_NETWORK_NODE';
  end if;

  if new.legacy_route_assignment_id is not null then
    select ra.route_id,ra.driver_profile_id,ra.vehicle_id
      into v_route_id,v_driver,v_vehicle
    from public.route_assignments ra
    where ra.id=new.legacy_route_assignment_id;

    if v_route_id is null
       or v_route_id is distinct from new.legacy_route_opportunity_id
       or v_driver is distinct from new.driver_profile_id
       or v_vehicle is distinct from new.vehicle_id then
      raise exception using errcode='P0001', message='TC_TRIP_LEGACY_ASSIGNMENT_MISMATCH';
    end if;
  end if;

  return new;
end;
$$;

create or replace function public.tc_guard_trip_state_transition()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.state = new.state then
    return new;
  end if;

  if not (
    (old.state='DRAFT' and new.state in ('PUBLISHED','CANCELLED'))
    or (old.state='PUBLISHED' and new.state in ('ACCEPTING','DEPARTED','CANCELLED'))
    or (old.state='ACCEPTING' and new.state in ('DEPARTED','CANCELLED'))
    or (old.state='DEPARTED' and new.state in ('COMPLETED','CANCELLED'))
  ) then
    raise exception using errcode='P0001', message='TC_TRIP_STATE_TRANSITION_INVALID';
  end if;

  new.version := old.version + 1;
  return new;
end;
$$;

create or replace function public.tc_guard_trip_stop_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_trip_id uuid;
  v_state text;
  v_location uuid;
begin
  v_trip_id := case when tg_op='DELETE' then old.trip_id else new.trip_id end;

  select t.state into v_state
  from public.logistics_trips t
  where t.id=v_trip_id;

  if v_state is distinct from 'DRAFT' then
    raise exception using errcode='P0001', message='TC_TRIP_PLAN_LOCKED';
  end if;

  if tg_op <> 'DELETE' then
    select o.id into v_location
    from public.operational_locations o
    where o.id=new.operational_location_id
      and o.active and o.network_enabled;

    if v_location is null then
      raise exception using errcode='P0001', message='TC_TRIP_STOP_NOT_NETWORK_NODE';
    end if;

    return new;
  end if;

  return old;
end;
$$;

create trigger logistics_trips_validate
before insert or update on public.logistics_trips
for each row execute function public.tc_validate_logistics_trip();

create trigger logistics_trips_state_transition
before update of state on public.logistics_trips
for each row execute function public.tc_guard_trip_state_transition();

create trigger logistics_trips_set_updated_at
before update on public.logistics_trips
for each row execute function public.tc_set_updated_at();

create trigger logistics_trip_stops_guard
before insert or update or delete on public.logistics_trip_stops
for each row execute function public.tc_guard_trip_stop_mutation();

create trigger logistics_trip_stops_set_updated_at
before update on public.logistics_trip_stops
for each row execute function public.tc_set_updated_at();

alter table public.logistics_trips enable row level security;
alter table public.logistics_trip_stops enable row level security;

revoke all on public.logistics_trips from public, anon, authenticated;
revoke all on public.logistics_trip_stops from public, anon, authenticated;
grant select,insert,update on public.logistics_trips to service_role;
grant select,insert,update,delete on public.logistics_trip_stops to service_role;

revoke all on function public.tc_validate_logistics_trip() from public, anon, authenticated;
revoke all on function public.tc_guard_trip_state_transition() from public, anon, authenticated;
revoke all on function public.tc_guard_trip_stop_mutation() from public, anon, authenticated;
grant execute on function public.tc_validate_logistics_trip() to service_role;
grant execute on function public.tc_guard_trip_state_transition() to service_role;
grant execute on function public.tc_guard_trip_stop_mutation() to service_role;

comment on table public.logistics_trips is
'Canonical real TRIP declared by a CON or bridged from legacy route_*; TU COMUNIDAD does not create an empty transport journey.';
comment on column public.logistics_trips.source_type is
'DRIVER_DECLARED is canonical. LEGACY_ADAPTER is a bridge only; SYSTEM_GENERATED is intentionally not allowed.';
comment on table public.logistics_trip_stops is
'Declared real-trip timeline. The stop plan is editable only while the trip is DRAFT.';

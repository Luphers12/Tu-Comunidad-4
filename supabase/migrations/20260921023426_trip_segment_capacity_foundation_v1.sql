
create table public.logistics_trip_capacity (
  trip_id uuid primary key references public.logistics_trips(id) on delete restrict,
  declared_free_weight_kg numeric not null check (declared_free_weight_kg >= 0),
  declared_free_volume_m3 numeric not null check (declared_free_volume_m3 >= 0),
  declared_free_packages integer not null check (declared_free_packages >= 0),
  accepts_cold_chain boolean not null default false,
  accepts_fragile boolean not null default false,
  accepts_bulky boolean not null default false,
  accepts_rural_cargo boolean not null default false,
  declared_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    declared_free_weight_kg > 0
    or declared_free_volume_m3 > 0
    or declared_free_packages > 0
  )
);

create table public.logistics_capacity_reservations (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('RSV'),
  trip_id uuid not null references public.logistics_trips(id) on delete restrict,
  demand_id uuid not null references public.logistics_demands(id) on delete restrict,
  board_stop_sequence integer not null,
  alight_stop_sequence integer not null,
  reserved_weight_kg numeric not null default 0 check (reserved_weight_kg >= 0),
  reserved_volume_m3 numeric not null default 0 check (reserved_volume_m3 >= 0),
  reserved_packages integer not null default 0 check (reserved_packages >= 0),
  state text not null default 'HELD'
    check (state in ('HELD','CONFIRMED','RELEASED','CONSUMED','CANCELLED')),
  idempotency_key text not null unique,
  version bigint not null default 0 check (version >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (public_id like 'RSV-%'),
  check (board_stop_sequence < alight_stop_sequence),
  check (
    reserved_weight_kg > 0
    or reserved_volume_m3 > 0
    or reserved_packages > 0
  ),
  foreign key (trip_id, board_stop_sequence)
    references public.logistics_trip_stops(trip_id, stop_sequence) on delete restrict,
  foreign key (trip_id, alight_stop_sequence)
    references public.logistics_trip_stops(trip_id, stop_sequence) on delete restrict
);

create index logistics_capacity_reservations_trip_segment_idx
  on public.logistics_capacity_reservations(trip_id, board_stop_sequence, alight_stop_sequence)
  where state in ('HELD','CONFIRMED');

create index logistics_capacity_reservations_demand_idx
  on public.logistics_capacity_reservations(demand_id, trip_id);

create or replace function public.tc_validate_trip_capacity()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_state text;
  v_max_weight numeric;
  v_max_volume numeric;
  v_max_packages integer;
  v_cold boolean;
  v_fragile boolean;
  v_bulky boolean;
  v_rural boolean;
begin
  select t.state,
         v.max_weight_kg,v.max_volume_m3,v.max_packages,
         v.supports_cold_chain,v.supports_fragile,v.supports_bulky,v.supports_rural_cargo
    into v_state,
         v_max_weight,v_max_volume,v_max_packages,
         v_cold,v_fragile,v_bulky,v_rural
  from public.logistics_trips t
  join public.vehicles v on v.id=t.vehicle_id
  where t.id=new.trip_id;

  if v_state is null then
    raise exception using errcode='P0001', message='TC_TRIP_NOT_FOUND';
  end if;

  if v_state <> 'DRAFT' then
    raise exception using errcode='P0001', message='TC_TRIP_CAPACITY_LOCKED';
  end if;

  if new.declared_free_weight_kg > v_max_weight
     or new.declared_free_volume_m3 > v_max_volume
     or (v_max_packages is not null and new.declared_free_packages > v_max_packages) then
    raise exception using errcode='P0001', message='TC_TRIP_CAPACITY_EXCEEDS_VEHICLE';
  end if;

  if (new.accepts_cold_chain and not v_cold)
     or (new.accepts_fragile and not v_fragile)
     or (new.accepts_bulky and not v_bulky)
     or (new.accepts_rural_cargo and not v_rural) then
    raise exception using errcode='P0001', message='TC_TRIP_CAPABILITY_EXCEEDS_VEHICLE';
  end if;

  return new;
end;
$$;

create or replace function public.tc_validate_trip_publishability()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_first_location uuid;
  v_first_kind text;
  v_destination_count integer;
  v_stop_count integer;
begin
  if old.state='DRAFT' and new.state='PUBLISHED' then
    select count(*) into v_stop_count
    from public.logistics_trip_stops s
    where s.trip_id=new.id;

    if v_stop_count < 2 then
      raise exception using errcode='P0001', message='TC_TRIP_NEEDS_STOPS';
    end if;

    select s.operational_location_id,s.stop_kind
      into v_first_location,v_first_kind
    from public.logistics_trip_stops s
    where s.trip_id=new.id
    order by s.stop_sequence
    limit 1;

    if v_first_location is distinct from new.origin_operational_location_id
       or v_first_kind is distinct from 'START' then
      raise exception using errcode='P0001', message='TC_TRIP_START_STOP_INVALID';
    end if;

    select count(*) into v_destination_count
    from public.logistics_trip_stops s
    where s.trip_id=new.id
      and s.operational_location_id=new.destination_operational_location_id
      and s.stop_kind='END';

    if v_destination_count <> 1 then
      raise exception using errcode='P0001', message='TC_TRIP_END_STOP_INVALID';
    end if;

    if not exists (
      select 1 from public.logistics_trip_capacity c where c.trip_id=new.id
    ) then
      raise exception using errcode='P0001', message='TC_TRIP_CAPACITY_REQUIRED';
    end if;

    new.published_at := coalesce(new.published_at, now());
  end if;

  return new;
end;
$$;

create or replace function public.tc_validate_capacity_reservation()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_trip_state text;
  v_cap_weight numeric;
  v_cap_volume numeric;
  v_cap_packages integer;
  v_segment integer;
  v_weight numeric;
  v_volume numeric;
  v_packages bigint;
begin
  if tg_op='UPDATE' then
    if old.trip_id is distinct from new.trip_id
       or old.demand_id is distinct from new.demand_id
       or old.board_stop_sequence is distinct from new.board_stop_sequence
       or old.alight_stop_sequence is distinct from new.alight_stop_sequence
       or old.reserved_weight_kg is distinct from new.reserved_weight_kg
       or old.reserved_volume_m3 is distinct from new.reserved_volume_m3
       or old.reserved_packages is distinct from new.reserved_packages
       or old.idempotency_key is distinct from new.idempotency_key then
      raise exception using errcode='P0001', message='TC_CAPACITY_RESERVATION_IMMUTABLE_FIELDS';
    end if;

    if old.state <> new.state then
      if not (
        (old.state='HELD' and new.state in ('CONFIRMED','RELEASED','CANCELLED'))
        or (old.state='CONFIRMED' and new.state in ('CONSUMED','RELEASED','CANCELLED'))
      ) then
        raise exception using errcode='P0001', message='TC_CAPACITY_RESERVATION_TRANSITION_INVALID';
      end if;
      new.version := old.version + 1;
    end if;
  end if;

  select t.state into v_trip_state
  from public.logistics_trips t
  where t.id=new.trip_id;

  if new.state in ('HELD','CONFIRMED') then
    if v_trip_state not in ('PUBLISHED','ACCEPTING') then
      raise exception using errcode='P0001', message='TC_TRIP_NOT_ACCEPTING_CAPACITY';
    end if;

    select c.declared_free_weight_kg,c.declared_free_volume_m3,c.declared_free_packages
      into v_cap_weight,v_cap_volume,v_cap_packages
    from public.logistics_trip_capacity c
    where c.trip_id=new.trip_id
    for update;

    if v_cap_weight is null then
      raise exception using errcode='P0001', message='TC_TRIP_CAPACITY_REQUIRED';
    end if;

    for v_segment in new.board_stop_sequence..(new.alight_stop_sequence-1) loop
      select
        coalesce(sum(r.reserved_weight_kg),0),
        coalesce(sum(r.reserved_volume_m3),0),
        coalesce(sum(r.reserved_packages),0)
      into v_weight,v_volume,v_packages
      from public.logistics_capacity_reservations r
      where r.trip_id=new.trip_id
        and r.id <> new.id
        and r.state in ('HELD','CONFIRMED')
        and r.board_stop_sequence <= v_segment
        and r.alight_stop_sequence > v_segment;

      if v_weight + new.reserved_weight_kg > v_cap_weight
         or v_volume + new.reserved_volume_m3 > v_cap_volume
         or v_packages + new.reserved_packages > v_cap_packages then
        raise exception using errcode='P0001', message='TC_TRIP_CAPACITY_OVERBOOKED';
      end if;
    end loop;
  end if;

  return new;
end;
$$;

create trigger logistics_trip_capacity_validate
before insert or update on public.logistics_trip_capacity
for each row execute function public.tc_validate_trip_capacity();

create trigger logistics_trip_capacity_set_updated_at
before update on public.logistics_trip_capacity
for each row execute function public.tc_set_updated_at();

create trigger logistics_trips_publishability
before update of state on public.logistics_trips
for each row execute function public.tc_validate_trip_publishability();

create trigger logistics_capacity_reservations_validate
before insert or update on public.logistics_capacity_reservations
for each row execute function public.tc_validate_capacity_reservation();

create trigger logistics_capacity_reservations_set_updated_at
before update on public.logistics_capacity_reservations
for each row execute function public.tc_set_updated_at();

alter table public.logistics_trip_capacity enable row level security;
alter table public.logistics_capacity_reservations enable row level security;

revoke all on public.logistics_trip_capacity from public, anon, authenticated;
revoke all on public.logistics_capacity_reservations from public, anon, authenticated;
grant select,insert,update on public.logistics_trip_capacity to service_role;
grant select,insert,update on public.logistics_capacity_reservations to service_role;

revoke all on function public.tc_validate_trip_capacity() from public, anon, authenticated;
revoke all on function public.tc_validate_trip_publishability() from public, anon, authenticated;
revoke all on function public.tc_validate_capacity_reservation() from public, anon, authenticated;
grant execute on function public.tc_validate_trip_capacity() to service_role;
grant execute on function public.tc_validate_trip_publishability() to service_role;
grant execute on function public.tc_validate_capacity_reservation() to service_role;

comment on table public.logistics_trip_capacity is
'Driver-declared free logistics capacity for one real TRIP. It is bounded by the selected vehicle and locked once the trip is published.';
comment on table public.logistics_capacity_reservations is
'Segment/timeline capacity reservation [board_stop, alight_stop). Active reservations are checked per segment to prevent overbooking. Not inventory or custody.';

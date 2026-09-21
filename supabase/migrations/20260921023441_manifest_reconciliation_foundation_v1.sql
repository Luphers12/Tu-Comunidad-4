
create table public.logistics_manifests (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('MNF'),
  trip_id uuid not null references public.logistics_trips(id) on delete restrict,
  version_no bigint not null check (version_no >= 1),
  manifest_type text not null
    check (manifest_type in ('LOAD_PLAN','DEPARTURE','IN_TRANSIT','ARRIVAL','RECOVERY')),
  supersedes_manifest_id uuid references public.logistics_manifests(id) on delete restrict,
  published_at timestamptz not null default now(),
  created_by_person_id uuid references public.persons(id) on delete set null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (trip_id, version_no),
  check (public_id like 'MNF-%'),
  check (supersedes_manifest_id is null or supersedes_manifest_id <> id)
);

create table public.logistics_manifest_items (
  manifest_id uuid not null references public.logistics_manifests(id) on delete restrict,
  package_id uuid not null references public.packages(id) on delete restrict,
  demand_id uuid not null references public.logistics_demands(id) on delete restrict,
  capacity_reservation_id uuid not null references public.logistics_capacity_reservations(id) on delete restrict,
  board_stop_sequence integer not null,
  alight_stop_sequence integer not null,
  movement_id uuid references public.movements(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (manifest_id, package_id),
  check (board_stop_sequence < alight_stop_sequence)
);

create table public.logistics_reconciliation_events (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('RCE'),
  manifest_id uuid not null references public.logistics_manifests(id) on delete restrict,
  package_id uuid references public.packages(id) on delete restrict,
  event_type text not null
    check (event_type in (
      'OBSERVED_PRESENT','EXPECTED_MISSING','UNEXPECTED_PRESENT',
      'COUNT_MISMATCH','CAPACITY_MISMATCH','RESOLVED'
    )),
  observed_operational_location_id uuid references public.operational_locations(id) on delete restrict,
  movement_id uuid references public.movements(id) on delete restrict,
  note text,
  metadata jsonb not null default '{}'::jsonb,
  actor_person_id uuid references public.persons(id) on delete set null,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  check (public_id like 'RCE-%'),
  check (
    event_type in ('COUNT_MISMATCH','CAPACITY_MISMATCH','RESOLVED')
    or package_id is not null
  )
);

create index logistics_manifests_trip_version_idx
  on public.logistics_manifests(trip_id, version_no desc);

create index logistics_manifest_items_demand_idx
  on public.logistics_manifest_items(demand_id, manifest_id);

create index logistics_manifest_items_movement_idx
  on public.logistics_manifest_items(movement_id)
  where movement_id is not null;

create index logistics_reconciliation_events_manifest_idx
  on public.logistics_reconciliation_events(manifest_id, occurred_at, created_at);

create or replace function public.tc_validate_logistics_manifest()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_trip_state text;
  v_max_version bigint;
  v_super_trip uuid;
  v_super_version bigint;
begin
  select t.state into v_trip_state
  from public.logistics_trips t
  where t.id=new.trip_id
  for update;

  if v_trip_state is null or v_trip_state in ('DRAFT','CANCELLED') then
    raise exception using errcode='P0001', message='TC_MANIFEST_TRIP_NOT_PUBLISHED';
  end if;

  select coalesce(max(m.version_no),0) into v_max_version
  from public.logistics_manifests m
  where m.trip_id=new.trip_id;

  if new.version_no <> v_max_version + 1 then
    raise exception using errcode='P0001', message='TC_MANIFEST_VERSION_NOT_NEXT';
  end if;

  if new.supersedes_manifest_id is not null then
    select m.trip_id,m.version_no into v_super_trip,v_super_version
    from public.logistics_manifests m
    where m.id=new.supersedes_manifest_id;

    if v_super_trip is distinct from new.trip_id
       or v_super_version is distinct from v_max_version then
      raise exception using errcode='P0001', message='TC_MANIFEST_SUPERSEDES_INVALID';
    end if;
  elsif v_max_version > 0 then
    raise exception using errcode='P0001', message='TC_MANIFEST_SUPERSEDES_REQUIRED';
  end if;

  return new;
end;
$$;

create or replace function public.tc_validate_manifest_item()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_trip uuid;
  v_r_trip uuid;
  v_r_demand uuid;
  v_r_board integer;
  v_r_alight integer;
  v_r_state text;
  v_m_trip uuid;
begin
  select m.trip_id into v_trip
  from public.logistics_manifests m
  where m.id=new.manifest_id;

  select r.trip_id,r.demand_id,r.board_stop_sequence,r.alight_stop_sequence,r.state
    into v_r_trip,v_r_demand,v_r_board,v_r_alight,v_r_state
  from public.logistics_capacity_reservations r
  where r.id=new.capacity_reservation_id;

  if v_r_trip is distinct from v_trip
     or v_r_demand is distinct from new.demand_id
     or v_r_board is distinct from new.board_stop_sequence
     or v_r_alight is distinct from new.alight_stop_sequence
     or v_r_state <> 'CONFIRMED' then
    raise exception using errcode='P0001', message='TC_MANIFEST_RESERVATION_MISMATCH';
  end if;

  if not exists (
    select 1
    from public.logistics_demand_packages dp
    where dp.demand_id=new.demand_id
      and dp.package_id=new.package_id
  ) then
    raise exception using errcode='P0001', message='TC_MANIFEST_PACKAGE_NOT_IN_DEMAND';
  end if;

  if new.movement_id is not null then
    select m.logistics_trip_id into v_m_trip
    from public.movements m
    where m.id=new.movement_id;

    if v_m_trip is distinct from v_trip then
      raise exception using errcode='P0001', message='TC_MANIFEST_MOVEMENT_TRIP_MISMATCH';
    end if;

    if not exists (
      select 1 from public.movement_packages mp
      where mp.movement_id=new.movement_id
        and mp.package_id=new.package_id
    ) then
      raise exception using errcode='P0001', message='TC_MANIFEST_PACKAGE_NOT_IN_MOVEMENT';
    end if;

    if not exists (
      select 1 from public.logistics_movement_demands md
      where md.movement_id=new.movement_id
        and md.demand_id=new.demand_id
        and md.capacity_reservation_id=new.capacity_reservation_id
    ) then
      raise exception using errcode='P0001', message='TC_MANIFEST_MOVEMENT_DEMAND_NOT_LINKED';
    end if;
  end if;

  return new;
end;
$$;

create trigger logistics_manifests_validate
before insert on public.logistics_manifests
for each row execute function public.tc_validate_logistics_manifest();

create trigger logistics_manifests_append_only
before update or delete on public.logistics_manifests
for each row execute function public.tc_guard_logistics_append_only();

create trigger logistics_manifest_items_validate
before insert on public.logistics_manifest_items
for each row execute function public.tc_validate_manifest_item();

create trigger logistics_manifest_items_append_only
before update or delete on public.logistics_manifest_items
for each row execute function public.tc_guard_logistics_append_only();

create trigger logistics_reconciliation_events_append_only
before update or delete on public.logistics_reconciliation_events
for each row execute function public.tc_guard_logistics_append_only();

alter table public.logistics_manifests enable row level security;
alter table public.logistics_manifest_items enable row level security;
alter table public.logistics_reconciliation_events enable row level security;

revoke all on public.logistics_manifests from public, anon, authenticated;
revoke all on public.logistics_manifest_items from public, anon, authenticated;
revoke all on public.logistics_reconciliation_events from public, anon, authenticated;
grant select,insert on public.logistics_manifests to service_role;
grant select,insert on public.logistics_manifest_items to service_role;
grant select,insert on public.logistics_reconciliation_events to service_role;

revoke all on function public.tc_validate_logistics_manifest() from public, anon, authenticated;
revoke all on function public.tc_validate_manifest_item() from public, anon, authenticated;
grant execute on function public.tc_validate_logistics_manifest() to service_role;
grant execute on function public.tc_validate_manifest_item() to service_role;

comment on table public.logistics_manifests is
'Immutable published manifest snapshots for a real TRIP. New versions supersede prior snapshots; historical manifests are never rewritten.';
comment on table public.logistics_manifest_items is
'Manifest timeline item linking PKG/LGD/reservation and optional MOV. It does not itself transfer custody.';
comment on table public.logistics_reconciliation_events is
'Append-only expected-vs-observed manifest reconciliation. These events never change custody; custody remains in custody_events/handshakes.';


create table public.logistics_rsg_availability (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('RAV'),
  rsg_profile_id uuid not null references public.profiles(id) on delete restrict,
  community_id uuid not null references public.communities(id) on delete restrict,
  service_mode text not null check (service_mode in ('RSG_MOTO','RSG_CAR','WALK')),
  vehicle_id uuid references public.vehicles(id) on delete restrict,
  state text not null default 'AVAILABLE'
    check (state in ('AVAILABLE','PAUSED','OFFLINE')),
  available_weight_kg numeric not null check (available_weight_kg >= 0),
  available_volume_m3 numeric not null check (available_volume_m3 >= 0),
  available_packages integer not null check (available_packages >= 0),
  supports_cold_chain boolean not null default false,
  supports_fragile boolean not null default false,
  supports_bulky boolean not null default false,
  max_radius_km numeric check (max_radius_km is null or max_radius_km > 0),
  available_from timestamptz,
  available_until timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (public_id like 'RAV-%'),
  check (available_until is null or available_from is null or available_until >= available_from)
);

create table public.logistics_last_mile_tasks (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('LMT'),
  task_key text not null unique,
  origin_operational_location_id uuid not null references public.operational_locations(id) on delete restrict,
  destination_version_id uuid not null references public.logistics_destination_versions(id) on delete restrict,
  state text not null default 'PENDING'
    check (state in ('PENDING','OFFERED','ASSIGNED','PICKED_UP','OUT_FOR_DELIVERY','DELIVERED','CANCELLED','RECOVERY')),
  total_weight_kg numeric not null check (total_weight_kg >= 0),
  total_volume_m3 numeric not null check (total_volume_m3 >= 0),
  package_count integer not null check (package_count >= 1),
  requires_cold_chain boolean not null default false,
  requires_fragile_handling boolean not null default false,
  requires_bulky boolean not null default false,
  earliest_ready_at timestamptz,
  latest_delivery_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (public_id like 'LMT-%'),
  check (latest_delivery_at is null or earliest_ready_at is null or latest_delivery_at >= earliest_ready_at)
);

create table public.logistics_last_mile_task_packages (
  task_id uuid not null references public.logistics_last_mile_tasks(id) on delete restrict,
  package_id uuid not null references public.packages(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (task_id,package_id)
);

create table public.logistics_rsg_capacity_reservations (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('LMR'),
  availability_id uuid not null references public.logistics_rsg_availability(id) on delete restrict,
  task_id uuid not null references public.logistics_last_mile_tasks(id) on delete restrict,
  reserved_weight_kg numeric not null check (reserved_weight_kg >= 0),
  reserved_volume_m3 numeric not null check (reserved_volume_m3 >= 0),
  reserved_packages integer not null check (reserved_packages >= 1),
  state text not null default 'CONFIRMED'
    check (state in ('CONFIRMED','RELEASED','CONSUMED')),
  idempotency_key text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (public_id like 'LMR-%')
);

create table public.logistics_last_mile_matches (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('LMC'),
  task_id uuid not null references public.logistics_last_mile_tasks(id) on delete restrict,
  availability_id uuid not null references public.logistics_rsg_availability(id) on delete restrict,
  rsg_profile_id uuid not null references public.profiles(id) on delete restrict,
  state text not null default 'OFFERED'
    check (state in ('OFFERED','ACCEPTED','REJECTED','EXPIRED','INVALIDATED')),
  capacity_reservation_id uuid references public.logistics_rsg_capacity_reservations(id) on delete restrict,
  offered_at timestamptz not null default now(),
  responded_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (task_id,availability_id),
  check (public_id like 'LMC-%'),
  check (
    (state='OFFERED' and capacity_reservation_id is null)
    or
    (state='ACCEPTED' and capacity_reservation_id is not null and responded_at is not null)
    or
    (state in ('REJECTED','EXPIRED','INVALIDATED') and responded_at is not null)
  )
);

create table public.logistics_last_mile_match_events (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('LME'),
  match_id uuid not null references public.logistics_last_mile_matches(id) on delete restrict,
  event_type text not null check (event_type in ('OFFERED','ACCEPTED','REJECTED','EXPIRED','INVALIDATED')),
  actor_profile_id uuid references public.profiles(id) on delete set null,
  reason_code text,
  metadata jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  check (public_id like 'LME-%')
);

create table public.logistics_last_mile_assignments (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('LMA'),
  task_id uuid not null references public.logistics_last_mile_tasks(id) on delete restrict,
  match_id uuid not null unique references public.logistics_last_mile_matches(id) on delete restrict,
  rsg_profile_id uuid not null references public.profiles(id) on delete restrict,
  capacity_reservation_id uuid not null references public.logistics_rsg_capacity_reservations(id) on delete restrict,
  state text not null default 'ACTIVE'
    check (state in ('ACTIVE','COMPLETED','CANCELLED')),
  movement_id uuid references public.movements(id) on delete restrict,
  accepted_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (public_id like 'LMA-%')
);

create unique index logistics_last_mile_one_accepted_match_uidx
  on public.logistics_last_mile_matches(task_id)
  where state='ACCEPTED';

create unique index logistics_rsg_one_active_reservation_per_task_uidx
  on public.logistics_rsg_capacity_reservations(task_id)
  where state='CONFIRMED';

create unique index logistics_last_mile_one_active_assignment_uidx
  on public.logistics_last_mile_assignments(task_id)
  where state='ACTIVE';

create index logistics_rsg_availability_lookup_idx
  on public.logistics_rsg_availability(community_id,state,available_from,available_until);

create index logistics_last_mile_tasks_state_idx
  on public.logistics_last_mile_tasks(state,created_at);

create index logistics_last_mile_matches_rsg_state_idx
  on public.logistics_last_mile_matches(rsg_profile_id,state,offered_at);

create trigger logistics_rsg_availability_updated_at
before update on public.logistics_rsg_availability
for each row execute function public.tc_set_updated_at();

create trigger logistics_last_mile_tasks_updated_at
before update on public.logistics_last_mile_tasks
for each row execute function public.tc_set_updated_at();

create trigger logistics_rsg_capacity_reservations_updated_at
before update on public.logistics_rsg_capacity_reservations
for each row execute function public.tc_set_updated_at();

create trigger logistics_last_mile_matches_updated_at
before update on public.logistics_last_mile_matches
for each row execute function public.tc_set_updated_at();

create trigger logistics_last_mile_assignments_updated_at
before update on public.logistics_last_mile_assignments
for each row execute function public.tc_set_updated_at();

create trigger logistics_last_mile_match_events_append_only
before update or delete on public.logistics_last_mile_match_events
for each row execute function public.tc_guard_logistics_append_only();

alter table public.logistics_rsg_availability enable row level security;
alter table public.logistics_last_mile_tasks enable row level security;
alter table public.logistics_last_mile_task_packages enable row level security;
alter table public.logistics_rsg_capacity_reservations enable row level security;
alter table public.logistics_last_mile_matches enable row level security;
alter table public.logistics_last_mile_match_events enable row level security;
alter table public.logistics_last_mile_assignments enable row level security;

revoke all on public.logistics_rsg_availability from public,anon,authenticated;
revoke all on public.logistics_last_mile_tasks from public,anon,authenticated;
revoke all on public.logistics_last_mile_task_packages from public,anon,authenticated;
revoke all on public.logistics_rsg_capacity_reservations from public,anon,authenticated;
revoke all on public.logistics_last_mile_matches from public,anon,authenticated;
revoke all on public.logistics_last_mile_match_events from public,anon,authenticated;
revoke all on public.logistics_last_mile_assignments from public,anon,authenticated;

grant select,insert,update on public.logistics_rsg_availability to service_role;
grant select,insert,update on public.logistics_last_mile_tasks to service_role;
grant select,insert on public.logistics_last_mile_task_packages to service_role;
grant select,insert,update on public.logistics_rsg_capacity_reservations to service_role;
grant select,insert,update on public.logistics_last_mile_matches to service_role;
grant select,insert on public.logistics_last_mile_match_events to service_role;
grant select,insert,update on public.logistics_last_mile_assignments to service_role;

create or replace function public.tc_validate_rsg_capacity_reservation()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_av public.logistics_rsg_availability%rowtype;
  v_task public.logistics_last_mile_tasks%rowtype;
  v_used_weight numeric;
  v_used_volume numeric;
  v_used_packages integer;
  v_dest_community uuid;
begin
  select * into v_av
  from public.logistics_rsg_availability a
  where a.id=new.availability_id
  for update;

  if v_av.id is null or v_av.state<>'AVAILABLE' then
    raise exception using errcode='P0001', message='TC_RSG_AVAILABILITY_NOT_AVAILABLE';
  end if;

  if not exists(
    select 1 from public.profiles p
    where p.id=v_av.rsg_profile_id
      and p.profile_type='RSG'
      and p.status='active'
  ) then
    raise exception using errcode='P0001', message='TC_RSG_PROFILE_INACTIVE';
  end if;

  select * into v_task
  from public.logistics_last_mile_tasks t
  where t.id=new.task_id
  for update;

  if v_task.id is null or v_task.state not in ('PENDING','OFFERED','ASSIGNED') then
    raise exception using errcode='P0001', message='TC_LAST_MILE_TASK_NOT_ASSIGNABLE';
  end if;

  select dsv.community_id into v_dest_community
  from public.logistics_destination_versions dsv
  where dsv.id=v_task.destination_version_id
    and dsv.target_kind='PRIVATE_LOCATION';

  if v_dest_community is distinct from v_av.community_id then
    raise exception using errcode='P0001', message='TC_RSG_COMMUNITY_MISMATCH';
  end if;

  if not exists(
    select 1 from public.service_coverage sc
    where sc.community_id=v_av.community_id
      and sc.is_active
      and sc.home_delivery_available
  ) then
    raise exception using errcode='P0001', message='TC_HOME_DELIVERY_NOT_AVAILABLE';
  end if;

  if v_task.requires_cold_chain and not v_av.supports_cold_chain then
    raise exception using errcode='P0001', message='TC_RSG_REQUIREMENT_COLD_CHAIN';
  end if;

  if v_task.requires_fragile_handling and not v_av.supports_fragile then
    raise exception using errcode='P0001', message='TC_RSG_REQUIREMENT_FRAGILE';
  end if;

  if v_task.requires_bulky and not v_av.supports_bulky then
    raise exception using errcode='P0001', message='TC_RSG_REQUIREMENT_BULKY';
  end if;

  if v_av.available_from is not null
     and v_task.latest_delivery_at is not null
     and v_av.available_from>v_task.latest_delivery_at then
    raise exception using errcode='P0001', message='TC_RSG_TIME_WINDOW_MISMATCH';
  end if;

  if v_av.available_until is not null
     and v_task.earliest_ready_at is not null
     and v_av.available_until<v_task.earliest_ready_at then
    raise exception using errcode='P0001', message='TC_RSG_TIME_WINDOW_MISMATCH';
  end if;

  select
    coalesce(sum(r.reserved_weight_kg),0),
    coalesce(sum(r.reserved_volume_m3),0),
    coalesce(sum(r.reserved_packages),0)
  into v_used_weight,v_used_volume,v_used_packages
  from public.logistics_rsg_capacity_reservations r
  where r.availability_id=v_av.id
    and r.state='CONFIRMED'
    and r.id is distinct from new.id;

  if v_used_weight+new.reserved_weight_kg>v_av.available_weight_kg
     or v_used_volume+new.reserved_volume_m3>v_av.available_volume_m3
     or v_used_packages+new.reserved_packages>v_av.available_packages then
    raise exception using errcode='P0001', message='TC_RSG_CAPACITY_EXCEEDED';
  end if;

  return new;
end;
$$;

create trigger logistics_rsg_capacity_reservation_validate
before insert on public.logistics_rsg_capacity_reservations
for each row execute function public.tc_validate_rsg_capacity_reservation();

create or replace function public.tc_guard_rsg_reservation_state()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.state=new.state then
    return new;
  end if;

  if old.state='CONFIRMED' and new.state in ('RELEASED','CONSUMED') then
    return new;
  end if;

  raise exception using errcode='P0001', message='TC_RSG_RESERVATION_STATE_INVALID';
end;
$$;

create trigger logistics_rsg_capacity_reservation_state_guard
before update of state on public.logistics_rsg_capacity_reservations
for each row execute function public.tc_guard_rsg_reservation_state();

revoke all on function public.tc_validate_rsg_capacity_reservation()
  from public,anon,authenticated;
revoke all on function public.tc_guard_rsg_reservation_state()
  from public,anon,authenticated;

grant execute on function public.tc_validate_rsg_capacity_reservation()
  to service_role;
grant execute on function public.tc_guard_rsg_reservation_state()
  to service_role;

comment on table public.logistics_rsg_availability is
'RSG-local declared availability/capacity. Separate from CON TRIP and may be community/radius based.';
comment on table public.logistics_last_mile_tasks is
'Last-mile need from an operational NODE to one immutable PRIVATE_LOCATION destination contract.';

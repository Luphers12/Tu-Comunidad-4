
create or replace function public.tc_guard_logistics_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception using errcode='P0001', message='TC_APPEND_ONLY';
end;
$$;

revoke all on function public.tc_guard_logistics_append_only() from public;
revoke all on function public.tc_guard_logistics_append_only() from anon;
revoke all on function public.tc_guard_logistics_append_only() from authenticated;
grant execute on function public.tc_guard_logistics_append_only() to service_role;

create table public.logistics_destinations (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('DST'),
  status text not null default 'ACTIVE'
    check (status in ('ACTIVE','RETIRED')),
  created_by_person_id uuid references public.persons(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (public_id like 'DST-%')
);

create table public.private_destination_snapshots (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('PDS'),
  source_customer_location_id uuid references public.customer_locations(id) on delete set null,
  country_id uuid not null references public.countries(id) on delete restrict,
  department_id uuid not null references public.departments(id) on delete restrict,
  municipality_id uuid not null references public.municipalities(id) on delete restrict,
  community_id uuid not null references public.communities(id) on delete restrict,
  label text,
  point extensions.geography(Point,4326),
  visual_reference text,
  access_instructions text,
  authorized_contact text,
  photo_refs text[] not null default '{}'::text[],
  safe_location_ref text,
  created_at timestamptz not null default now(),
  check (public_id like 'PDS-%')
);

create table public.logistics_destination_versions (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('DSV'),
  destination_id uuid not null references public.logistics_destinations(id) on delete restrict,
  version_no bigint not null,
  target_kind text not null
    check (target_kind in ('PRIVATE_LOCATION','OPERATIONAL_NODE')),
  private_snapshot_id uuid references public.private_destination_snapshots(id) on delete restrict,
  operational_location_id uuid references public.operational_locations(id) on delete restrict,
  country_id uuid not null references public.countries(id) on delete restrict,
  department_id uuid not null references public.departments(id) on delete restrict,
  municipality_id uuid not null references public.municipalities(id) on delete restrict,
  community_id uuid not null references public.communities(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (destination_id, version_no),
  check (public_id like 'DSV-%'),
  check (version_no >= 1),
  check (
    (target_kind='PRIVATE_LOCATION' and private_snapshot_id is not null and operational_location_id is null)
    or
    (target_kind='OPERATIONAL_NODE' and operational_location_id is not null and private_snapshot_id is null)
  )
);

create unique index logistics_destination_versions_private_snapshot_uidx
  on public.logistics_destination_versions(private_snapshot_id)
  where private_snapshot_id is not null;

create index logistics_destination_versions_destination_idx
  on public.logistics_destination_versions(destination_id, version_no desc);

create index logistics_destination_versions_community_idx
  on public.logistics_destination_versions(community_id);

alter table public.orders
  add column destination_contract_id uuid
  references public.logistics_destination_versions(id) on delete restrict;

create index orders_destination_contract_idx
  on public.orders(destination_contract_id)
  where destination_contract_id is not null;

create trigger logistics_destinations_set_updated_at
before update on public.logistics_destinations
for each row execute function public.tc_set_updated_at();

create trigger logistics_destination_versions_append_only
before update or delete on public.logistics_destination_versions
for each row execute function public.tc_guard_logistics_append_only();

create trigger private_destination_snapshots_append_only
before update or delete on public.private_destination_snapshots
for each row execute function public.tc_guard_logistics_append_only();

alter table public.logistics_destinations enable row level security;
alter table public.private_destination_snapshots enable row level security;
alter table public.logistics_destination_versions enable row level security;

revoke all on public.logistics_destinations from public, anon, authenticated;
revoke all on public.private_destination_snapshots from public, anon, authenticated;
revoke all on public.logistics_destination_versions from public, anon, authenticated;

grant select,insert,update on public.logistics_destinations to service_role;
grant select,insert on public.private_destination_snapshots to service_role;
grant select,insert on public.logistics_destination_versions to service_role;

comment on table public.logistics_destinations is
'Stable DST identity. Delivery/routing details live in immutable logistics_destination_versions.';
comment on table public.private_destination_snapshots is
'Private immutable delivery snapshot. Keep recipient/contact/location-detail data out of routing-facing contracts.';
comment on table public.logistics_destination_versions is
'Immutable DSV contract version. Orders may reference a DSV through orders.destination_contract_id; legacy destination_type/destination_id remains valid while null.';
comment on column public.orders.destination_contract_id is
'Nullable immutable destination contract version. NULL means use the legacy destination_type/destination_id adapter.';

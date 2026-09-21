
create table public.logistics_capability_catalog (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('LCP'),
  code text not null unique,
  family text not null
    check (family in ('COMMERCIAL_COMMITMENT','PHYSICAL_CAPACITY','OPERATIONAL_CAPACITY')),
  description text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (public_id like 'LCP-%'),
  check (code = upper(code) and btrim(code) <> '')
);

create table public.operational_location_capabilities (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('OLC'),
  operational_location_id uuid not null references public.operational_locations(id) on delete restrict,
  capability_id uuid not null references public.logistics_capability_catalog(id) on delete restrict,
  status text not null default 'PENDING'
    check (status in ('PENDING','ENABLED','DISABLED')),
  configuration jsonb not null default '{}'::jsonb,
  set_by_person_id uuid references public.persons(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (operational_location_id, capability_id),
  check (public_id like 'OLC-%')
);

create index operational_location_capabilities_enabled_idx
  on public.operational_location_capabilities(operational_location_id, capability_id)
  where status='ENABLED';

create trigger logistics_capability_catalog_set_updated_at
before update on public.logistics_capability_catalog
for each row execute function public.tc_set_updated_at();

create trigger operational_location_capabilities_set_updated_at
before update on public.operational_location_capabilities
for each row execute function public.tc_set_updated_at();

alter table public.logistics_capability_catalog enable row level security;
alter table public.operational_location_capabilities enable row level security;

revoke all on public.logistics_capability_catalog from public, anon, authenticated;
revoke all on public.operational_location_capabilities from public, anon, authenticated;
grant select,insert,update on public.logistics_capability_catalog to service_role;
grant select,insert,update on public.operational_location_capabilities to service_role;

insert into public.logistics_capability_catalog(code,family,description) values
('INVENTORY_COMMITMENT','COMMERCIAL_COMMITMENT','Location can make a precommitted commercial inventory promise; this is not a logistics capacity reservation.'),
('RECEIVE_CARGO','OPERATIONAL_CAPACITY','Location can physically receive cargo.'),
('HANDOFF_CARGO','OPERATIONAL_CAPACITY','Location can perform a controlled cargo handoff.'),
('STAGE_CARGO','PHYSICAL_CAPACITY','Location can safely stage cargo; actual space/capacity is modeled separately.'),
('SORT_CARGO','OPERATIONAL_CAPACITY','Location can sort cargo for onward movement.'),
('LAST_MILE_ORIGIN','OPERATIONAL_CAPACITY','Location can originate last-mile delivery work.'),
('BOX_HOST','PHYSICAL_CAPACITY','Location can host an approved BOX endpoint; declaration does not itself transfer custody.')
on conflict (code) do nothing;

comment on table public.logistics_capability_catalog is
'LOGISTICS capability catalog. Deliberately separate from public.capabilities, which is authorization/RBAC.';
comment on table public.operational_location_capabilities is
'Declared node capabilities. Declaration/status is not inventory, trip capacity, custody, or a capacity reservation.';

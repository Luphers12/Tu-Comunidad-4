
create table public.logistics_demands (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('LGD'),
  source_type text not null
    check (source_type in (
      'CLIENT_ORDER','STORE_RESTOCK','STORE_TO_STORE','SUPPLIER_DELIVERY',
      'PTC_TRANSFER','RETURN','AGRICULTURAL_CARGO'
    )),
  source_id text not null,
  origin_destination_version_id uuid not null references public.logistics_destination_versions(id) on delete restrict,
  destination_version_id uuid not null references public.logistics_destination_versions(id) on delete restrict,
  state text not null default 'CREATED'
    check (state in (
      'CREATED','READY_FOR_ROUTING','ROUTING','PARTIALLY_ASSIGNED','ASSIGNED',
      'IN_TRANSIT','DELIVERED','CANCELLED','ROUTING_EXCEPTION'
    )),
  version bigint not null default 0 check (version >= 0),
  cargo_class text,
  total_weight_kg numeric not null default 0 check (total_weight_kg >= 0),
  total_volume_m3 numeric not null default 0 check (total_volume_m3 >= 0),
  requires_cold_chain boolean not null default false,
  requires_fragile_handling boolean not null default false,
  required_capability_codes text[] not null default '{}'::text[],
  earliest_ready_at timestamptz,
  latest_delivery_at timestamptz,
  requirements jsonb not null default '{}'::jsonb,
  routing_exception_code text,
  routing_exception_detail jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (public_id like 'LGD-%'),
  check (btrim(source_id) <> ''),
  check (latest_delivery_at is null or earliest_ready_at is null or latest_delivery_at >= earliest_ready_at),
  check (state='ROUTING_EXCEPTION' or routing_exception_code is null)
);

create table public.logistics_demand_packages (
  demand_id uuid not null references public.logistics_demands(id) on delete restrict,
  package_id uuid not null references public.packages(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (demand_id, package_id)
);

create index logistics_demands_source_idx
  on public.logistics_demands(source_type, source_id);

create index logistics_demands_state_window_idx
  on public.logistics_demands(state, earliest_ready_at, latest_delivery_at);

create index logistics_demands_destination_idx
  on public.logistics_demands(destination_version_id);

create index logistics_demand_packages_package_idx
  on public.logistics_demand_packages(package_id);

create trigger logistics_demands_set_updated_at
before update on public.logistics_demands
for each row execute function public.tc_set_updated_at();

create trigger logistics_demand_packages_append_only
before update or delete on public.logistics_demand_packages
for each row execute function public.tc_guard_logistics_append_only();

alter table public.logistics_demands enable row level security;
alter table public.logistics_demand_packages enable row level security;

revoke all on public.logistics_demands from public, anon, authenticated;
revoke all on public.logistics_demand_packages from public, anon, authenticated;
grant select,insert,update on public.logistics_demands to service_role;
grant select,insert on public.logistics_demand_packages to service_role;

comment on table public.logistics_demands is
'LGD: logistics demand separated from Source Operation. It does not reserve inventory, trip capacity, custody, payment, or MOV.';
comment on table public.logistics_demand_packages is
'Append-only PKG↔LGD relationship. It records demand membership only; it is not capacity ownership, reservation, or custody.';
comment on column public.logistics_demands.routing_exception_code is
'ROUTING_EXCEPTION state support only. Candidate/dead-end detection belongs to the later routing resolver; NO TRIP NOW is not automatically a dead end.';

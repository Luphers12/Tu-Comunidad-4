
alter table public.operational_locations
  add column network_enabled boolean not null default false,
  add column network_enabled_at timestamptz,
  add column network_enabled_by_person_id uuid references public.persons(id) on delete set null;

create index operational_locations_network_enabled_idx
  on public.operational_locations(community_id, id)
  where network_enabled and active;

comment on column public.operational_locations.network_enabled is
'Orthogonal NODE promotion flag. purpose remains functional (STORE_PICKUP/PTC_PICKUP); ordinary location RPCs do not set this flag.';
comment on column public.operational_locations.network_enabled_by_person_id is
'Last privileged actor recorded when enabling network participation. No ordinary-user RPC is added by this migration.';

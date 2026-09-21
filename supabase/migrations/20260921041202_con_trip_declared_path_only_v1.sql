
alter table public.logistics_trips
  drop constraint logistics_trips_max_detour_km_check,
  drop column max_detour_km;

alter table public.logistics_trip_stops
  drop constraint logistics_trip_stops_detour_limit_km_check,
  drop column detour_limit_km;

comment on table public.logistics_trips is
'Canonical real TRIP declared by a CON or bridged from legacy route_*. CON matching is based on declared ordered stops actually traversed; no detour-radius field exists in the canonical CON model.';

comment on table public.logistics_trip_stops is
'Declared ordered points the real TRIP actually passes. CON compatibility requires board/alight points to exist in this ordered timeline; RSG last-mile logic is separate.';

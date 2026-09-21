
alter table public.movements
  drop constraint movements_movement_type_check;

alter table public.movements
  add constraint movements_movement_type_check
  check (movement_type = any (array[
    'STORE_TO_PTC'::text,
    'STORE_TO_DRIVER'::text,
    'PTC_TO_PTC'::text,
    'PTC_TO_DRIVER'::text,
    'DRIVER_TO_PTC'::text,
    'PTC_TO_DELIVERY'::text,
    'DELIVERY_TO_CUSTOMER'::text,
    'RETURN'::text,
    'NODE_TO_NODE'::text
  ]));

alter table public.movements
  add column logistics_trip_id uuid references public.logistics_trips(id) on delete restrict,
  add column origin_operational_location_id uuid references public.operational_locations(id) on delete restrict,
  add column destination_operational_location_id uuid references public.operational_locations(id) on delete restrict,
  add column logistics_edge_id uuid references public.logistics_edges(id) on delete restrict,
  add column board_stop_sequence integer,
  add column alight_stop_sequence integer;

alter table public.movements
  add constraint movements_logistics_bridge_shape_check
  check (
    (
      logistics_trip_id is null
      and origin_operational_location_id is null
      and destination_operational_location_id is null
      and logistics_edge_id is null
      and board_stop_sequence is null
      and alight_stop_sequence is null
    )
    or
    (
      logistics_trip_id is not null
      and origin_operational_location_id is not null
      and destination_operational_location_id is not null
      and logistics_edge_id is not null
      and board_stop_sequence is not null
      and alight_stop_sequence is not null
      and board_stop_sequence < alight_stop_sequence
    )
  ),
  add constraint movements_board_stop_fkey
    foreign key (logistics_trip_id, board_stop_sequence)
    references public.logistics_trip_stops(trip_id, stop_sequence) on delete restrict,
  add constraint movements_alight_stop_fkey
    foreign key (logistics_trip_id, alight_stop_sequence)
    references public.logistics_trip_stops(trip_id, stop_sequence) on delete restrict;

create index movements_logistics_trip_idx
  on public.movements(logistics_trip_id, board_stop_sequence, alight_stop_sequence)
  where logistics_trip_id is not null;

create index movements_logistics_edge_idx
  on public.movements(logistics_edge_id)
  where logistics_edge_id is not null;

create table public.logistics_movement_demands (
  movement_id uuid not null references public.movements(id) on delete restrict,
  demand_id uuid not null references public.logistics_demands(id) on delete restrict,
  capacity_reservation_id uuid not null references public.logistics_capacity_reservations(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (movement_id, demand_id),
  unique (movement_id, capacity_reservation_id)
);

create index logistics_movement_demands_demand_idx
  on public.logistics_movement_demands(demand_id, movement_id);

create or replace function public.tc_validate_movement_trip_bridge()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_board_location uuid;
  v_alight_location uuid;
  v_edge_origin uuid;
  v_edge_destination uuid;
  v_trip_state text;
begin
  if new.logistics_trip_id is null then
    return new;
  end if;

  select t.state into v_trip_state
  from public.logistics_trips t
  where t.id=new.logistics_trip_id;

  if v_trip_state in ('DRAFT','CANCELLED') or v_trip_state is null then
    raise exception using errcode='P0001', message='TC_MOVEMENT_TRIP_NOT_EXECUTABLE';
  end if;

  select s.operational_location_id into v_board_location
  from public.logistics_trip_stops s
  where s.trip_id=new.logistics_trip_id
    and s.stop_sequence=new.board_stop_sequence;

  select s.operational_location_id into v_alight_location
  from public.logistics_trip_stops s
  where s.trip_id=new.logistics_trip_id
    and s.stop_sequence=new.alight_stop_sequence;

  if v_board_location is distinct from new.origin_operational_location_id
     or v_alight_location is distinct from new.destination_operational_location_id then
    raise exception using errcode='P0001', message='TC_MOVEMENT_STOP_LOCATION_MISMATCH';
  end if;

  select e.origin_operational_location_id,e.destination_operational_location_id
    into v_edge_origin,v_edge_destination
  from public.logistics_edges e
  where e.id=new.logistics_edge_id
    and e.structural_status='ACTIVE';

  if v_edge_origin is distinct from new.origin_operational_location_id
     or v_edge_destination is distinct from new.destination_operational_location_id then
    raise exception using errcode='P0001', message='TC_MOVEMENT_EDGE_DIRECTION_MISMATCH';
  end if;

  return new;
end;
$$;

create or replace function public.tc_validate_movement_demand_bridge()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_trip uuid;
  v_board integer;
  v_alight integer;
  v_r_trip uuid;
  v_r_demand uuid;
  v_r_board integer;
  v_r_alight integer;
  v_r_state text;
begin
  select m.logistics_trip_id,m.board_stop_sequence,m.alight_stop_sequence
    into v_trip,v_board,v_alight
  from public.movements m
  where m.id=new.movement_id;

  if v_trip is null then
    raise exception using errcode='P0001', message='TC_MOVEMENT_NOT_TRIP_BRIDGED';
  end if;

  select r.trip_id,r.demand_id,r.board_stop_sequence,r.alight_stop_sequence,r.state
    into v_r_trip,v_r_demand,v_r_board,v_r_alight,v_r_state
  from public.logistics_capacity_reservations r
  where r.id=new.capacity_reservation_id;

  if v_r_trip is distinct from v_trip
     or v_r_demand is distinct from new.demand_id
     or v_r_state not in ('CONFIRMED','CONSUMED')
     or v_r_board > v_board
     or v_r_alight < v_alight then
    raise exception using errcode='P0001', message='TC_MOVEMENT_CAPACITY_BRIDGE_MISMATCH';
  end if;

  return new;
end;
$$;

create trigger movements_validate_logistics_bridge
before insert or update of logistics_trip_id,origin_operational_location_id,destination_operational_location_id,logistics_edge_id,board_stop_sequence,alight_stop_sequence
on public.movements
for each row execute function public.tc_validate_movement_trip_bridge();

create trigger logistics_movement_demands_validate
before insert on public.logistics_movement_demands
for each row execute function public.tc_validate_movement_demand_bridge();

create trigger logistics_movement_demands_append_only
before update or delete on public.logistics_movement_demands
for each row execute function public.tc_guard_logistics_append_only();

alter table public.logistics_movement_demands enable row level security;
revoke all on public.logistics_movement_demands from public, anon, authenticated;
grant select,insert on public.logistics_movement_demands to service_role;

revoke all on function public.tc_validate_movement_trip_bridge() from public, anon, authenticated;
revoke all on function public.tc_validate_movement_demand_bridge() from public, anon, authenticated;
grant execute on function public.tc_validate_movement_trip_bridge() to service_role;
grant execute on function public.tc_validate_movement_demand_bridge() to service_role;

comment on column public.movements.logistics_trip_id is
'Canonical TRIP bridge. Legacy route_id/route_assignment_id remain supported while this column is NULL.';
comment on table public.logistics_movement_demands is
'Many-to-many MOV↔LGD bridge tied to a confirmed/consumed segment capacity reservation. It does not transfer custody.';

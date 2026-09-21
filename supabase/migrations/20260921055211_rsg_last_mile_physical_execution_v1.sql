
alter table public.logistics_movement_custody_phases
  drop constraint logistics_movement_custody_phases_phase_check;

alter table public.logistics_movement_custody_phases
  add constraint logistics_movement_custody_phases_phase_check
  check (phase in ('DEPARTURE','ARRIVAL','LAST_MILE_PICKUP','LAST_MILE_DELIVERY'));

create table public.logistics_last_mile_arrival_events (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('LAR'),
  task_id uuid not null references public.logistics_last_mile_tasks(id) on delete restrict,
  assignment_id uuid not null references public.logistics_last_mile_assignments(id) on delete restrict,
  movement_id uuid not null references public.movements(id) on delete restrict,
  rsg_profile_id uuid not null references public.profiles(id) on delete restrict,
  event_type text not null default 'ARRIVAL_CANDIDATE'
    check (event_type='ARRIVAL_CANDIDATE'),
  source_type text not null
    check (source_type in ('GPS','MANUAL_REFERENCE','OFFLINE_SYNC')),
  latitude numeric,
  longitude numeric,
  distance_to_destination_m numeric check (distance_to_destination_m is null or distance_to_destination_m >= 0),
  idempotency_key text not null unique,
  metadata jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null,
  created_at timestamptz not null default now(),
  check (public_id like 'LAR-%'),
  check (
    (latitude is null and longitude is null)
    or
    (latitude between -90 and 90 and longitude between -180 and 180)
  )
);

create index logistics_last_mile_arrival_movement_idx
  on public.logistics_last_mile_arrival_events(movement_id,occurred_at);

create trigger logistics_last_mile_arrival_events_append_only
before update or delete on public.logistics_last_mile_arrival_events
for each row execute function public.tc_guard_logistics_append_only();

alter table public.logistics_last_mile_arrival_events enable row level security;
revoke all on public.logistics_last_mile_arrival_events from public,anon,authenticated;
grant select,insert on public.logistics_last_mile_arrival_events to service_role;

create or replace function public.tc_materialize_last_mile_assignment(
  p_assignment_id uuid
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_assignment public.logistics_last_mile_assignments%rowtype;
  v_task public.logistics_last_mile_tasks%rowtype;
  v_origin_owner uuid;
  v_client_profiles uuid[];
  v_client uuid;
  v_movement uuid;
  v_expected_from timestamptz;
  v_expected_to timestamptz;
  v_expected_count integer;
  v_origin_count integer;
begin
  select * into v_assignment
  from public.logistics_last_mile_assignments a
  where a.id=p_assignment_id
  for update;

  if v_assignment.id is null then
    raise exception using errcode='P0001', message='TC_LAST_MILE_ASSIGNMENT_NOT_FOUND';
  end if;

  if v_assignment.movement_id is not null then
    return v_assignment.movement_id;
  end if;

  if v_assignment.state<>'ACTIVE' then
    raise exception using errcode='P0001', message='TC_LAST_MILE_ASSIGNMENT_NOT_ACTIVE';
  end if;

  select * into v_task
  from public.logistics_last_mile_tasks t
  where t.id=v_assignment.task_id
  for update;

  if v_task.id is null or v_task.state<>'ASSIGNED' then
    raise exception using errcode='P0001', message='TC_LAST_MILE_TASK_NOT_ASSIGNED';
  end if;

  select o.owner_profile_id into v_origin_owner
  from public.operational_locations o
  where o.id=v_task.origin_operational_location_id
    and o.active and o.network_enabled;

  if v_origin_owner is null then
    raise exception using errcode='P0001', message='TC_LAST_MILE_ORIGIN_OWNER_REQUIRED';
  end if;

  select array_agg(distinct ord.client_profile_id)
    into v_client_profiles
  from public.logistics_last_mile_task_packages tp
  join public.packages p on p.id=tp.package_id
  join public.sub_orders so on so.id=p.sub_order_id
  join public.orders ord on ord.id=so.order_id
  where tp.task_id=v_task.id;

  if cardinality(v_client_profiles)<>1 then
    raise exception using errcode='P0001', message='TC_LAST_MILE_SINGLE_CLIENT_REQUIRED';
  end if;

  v_client:=v_client_profiles[1];

  if not exists(
    select 1 from public.profiles p
    where p.id=v_client
      and p.profile_type='CLI'
      and p.status='active'
  ) then
    raise exception using errcode='P0001', message='TC_LAST_MILE_CLIENT_PROFILE_INVALID';
  end if;

  select count(*) into v_expected_count
  from public.logistics_last_mile_task_packages tp
  where tp.task_id=v_task.id;

  select count(*) into v_origin_count
  from public.logistics_last_mile_task_packages tp
  join public.packages p on p.id=tp.package_id
  where tp.task_id=v_task.id
    and p.current_custodian_id=v_origin_owner;

  if v_expected_count<1 or v_origin_count<>v_expected_count then
    raise exception using errcode='P0001', message='TC_LAST_MILE_PACKAGE_NOT_AT_ORIGIN';
  end if;

  v_expected_from:=coalesce(v_task.earliest_ready_at,now());
  v_expected_to:=v_task.latest_delivery_at;

  insert into public.movements(
    from_profile_id,to_profile_id,
    movement_type,state,sequence_number,
    expected_from_at,expected_to_at
  ) values(
    v_origin_owner,v_client,
    'DELIVERY_TO_CUSTOMER','PLANNED',1,
    v_expected_from,v_expected_to
  )
  returning id into v_movement;

  insert into public.movement_packages(movement_id,package_id)
  select v_movement,tp.package_id
  from public.logistics_last_mile_task_packages tp
  where tp.task_id=v_task.id
  on conflict do nothing;

  insert into public.logistics_movement_custody_phases(
    movement_id,package_id,phase,from_profile_id,to_profile_id,status
  )
  select
    v_movement,tp.package_id,'LAST_MILE_PICKUP',
    v_origin_owner,v_assignment.rsg_profile_id,'PLANNED'
  from public.logistics_last_mile_task_packages tp
  where tp.task_id=v_task.id;

  insert into public.logistics_movement_custody_phases(
    movement_id,package_id,phase,from_profile_id,to_profile_id,status
  )
  select
    v_movement,tp.package_id,'LAST_MILE_DELIVERY',
    v_assignment.rsg_profile_id,v_client,'PLANNED'
  from public.logistics_last_mile_task_packages tp
  where tp.task_id=v_task.id;

  update public.logistics_last_mile_assignments
     set movement_id=v_movement,
         updated_at=now()
   where id=v_assignment.id;

  return v_movement;
end;
$$;

create or replace function public.tc_materialize_last_mile_assignment_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.tc_materialize_last_mile_assignment(new.id);
  return new;
end;
$$;

create trigger logistics_last_mile_assignment_materialize
after insert on public.logistics_last_mile_assignments
for each row execute function public.tc_materialize_last_mile_assignment_trigger();

revoke all on function public.tc_materialize_last_mile_assignment(uuid)
  from public,anon,authenticated;
revoke all on function public.tc_materialize_last_mile_assignment_trigger()
  from public,anon,authenticated,service_role;

grant execute on function public.tc_materialize_last_mile_assignment(uuid)
  to service_role;

comment on table public.logistics_movement_custody_phases is
'Custody-handshake coordination across canonical intercommunity and last-mile MOV. custody_events remains the single append-only transfer ledger.';
comment on table public.logistics_last_mile_arrival_events is
'Arrival-candidate evidence only. GPS/reference proximity may support delivery workflow but never equals custody transfer or DELIVERED.';

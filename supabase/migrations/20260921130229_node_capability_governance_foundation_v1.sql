
insert into public.capabilities(name)
values
  ('logistics.node_capability.review'),
  ('logistics.node_capability.approve')
on conflict (name) do nothing;

create table public.node_capability_requests (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('NCR'),
  operational_location_id uuid not null references public.operational_locations(id) on delete restrict,
  capability_id uuid not null references public.logistics_capability_catalog(id) on delete restrict,
  requested_by_profile_id uuid not null references public.profiles(id) on delete restrict,
  state text not null default 'DRAFT'
    check (state in (
      'DRAFT','SUBMITTED','UNDER_REVIEW','CHANGES_REQUESTED',
      'APPROVED','REJECTED','WITHDRAWN'
    )),
  justification text,
  requested_configuration jsonb not null default '{}'::jsonb,
  submitted_at timestamptz,
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (public_id like 'NCR-%')
);

create unique index node_capability_requests_one_open_uidx
  on public.node_capability_requests(operational_location_id,capability_id)
  where state in ('DRAFT','SUBMITTED','UNDER_REVIEW','CHANGES_REQUESTED');

create index node_capability_requests_queue_idx
  on public.node_capability_requests(state,operational_location_id,created_at);

create table public.node_capability_request_requirements (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('NQR'),
  request_id uuid not null references public.node_capability_requests(id) on delete restrict,
  requirement_code text not null,
  source_type text not null check (source_type in ('SYSTEM','APPLICANT')),
  required boolean not null default true,
  status text not null default 'PENDING'
    check (status in ('PENDING','PROVIDED','VERIFIED','REJECTED')),
  evidence jsonb not null default '{}'::jsonb,
  reviewer_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(request_id,requirement_code),
  check (public_id like 'NQR-%')
);

create table public.node_capability_request_events (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('NCE'),
  event_seq bigint generated always as identity unique,
  request_id uuid not null references public.node_capability_requests(id) on delete restrict,
  event_type text not null check (event_type in (
    'STARTED','REQUIREMENT_PROVIDED','SUBMITTED','UNDER_REVIEW',
    'REQUIREMENT_VERIFIED','REQUIREMENT_REJECTED',
    'CHANGES_REQUESTED','APPROVED','REJECTED','WITHDRAWN'
  )),
  actor_profile_id uuid references public.profiles(id) on delete set null,
  metadata jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  check (public_id like 'NCE-%')
);

create trigger node_capability_requests_updated_at
before update on public.node_capability_requests
for each row execute function public.tc_set_updated_at();

create trigger node_capability_request_requirements_updated_at
before update on public.node_capability_request_requirements
for each row execute function public.tc_set_updated_at();

create trigger node_capability_request_events_append_only
before update or delete on public.node_capability_request_events
for each row execute function public.tc_guard_logistics_append_only();

alter table public.node_capability_requests enable row level security;
alter table public.node_capability_request_requirements enable row level security;
alter table public.node_capability_request_events enable row level security;

revoke all on public.node_capability_requests from public,anon,authenticated;
revoke all on public.node_capability_request_requirements from public,anon,authenticated;
revoke all on public.node_capability_request_events from public,anon,authenticated;

grant select,insert,update on public.node_capability_requests to service_role;
grant select,insert,update on public.node_capability_request_requirements to service_role;
grant select,insert on public.node_capability_request_events to service_role;

create or replace function public.tc_refresh_node_capability_requirements(
  p_request_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_req public.node_capability_requests%rowtype;
  v_node public.operational_locations%rowtype;
  v_cap text;
  v_owner_ok boolean;
  v_network_ok boolean;
  v_receive_ok boolean;
  v_handoff_ok boolean;
  v_home_ok boolean;
begin
  select * into v_req
  from public.node_capability_requests r
  where r.id=p_request_id
  for update;

  if v_req.id is null then
    raise exception using errcode='P0001', message='TC_NODE_CAPABILITY_REQUEST_NOT_FOUND';
  end if;

  select * into v_node
  from public.operational_locations o
  where o.id=v_req.operational_location_id;

  select c.code into v_cap
  from public.logistics_capability_catalog c
  where c.id=v_req.capability_id;

  select exists(
    select 1
    from public.profiles p
    where p.id=v_req.requested_by_profile_id
      and p.status='active'
      and p.profile_type in ('TIE','PTC')
      and v_node.owner_profile_id=p.id
  ) into v_owner_ok;

  v_network_ok:=coalesce(v_node.active,false) and coalesce(v_node.network_enabled,false);

  select exists(
    select 1
    from public.operational_location_capabilities olc
    join public.logistics_capability_catalog c on c.id=olc.capability_id
    where olc.operational_location_id=v_node.id
      and c.code='RECEIVE_CARGO'
      and c.active
      and olc.status='ENABLED'
  ) into v_receive_ok;

  select exists(
    select 1
    from public.operational_location_capabilities olc
    join public.logistics_capability_catalog c on c.id=olc.capability_id
    where olc.operational_location_id=v_node.id
      and c.code='HANDOFF_CARGO'
      and c.active
      and olc.status='ENABLED'
  ) into v_handoff_ok;

  select exists(
    select 1
    from public.service_coverage sc
    where sc.community_id=v_node.community_id
      and sc.is_active
      and sc.home_delivery_available
  ) into v_home_ok;

  update public.node_capability_request_requirements
     set status=case when v_owner_ok then 'VERIFIED' else 'PENDING' end,
         evidence=jsonb_build_object('system_check','NODE_OWNERSHIP','passed',v_owner_ok)
   where request_id=v_req.id
     and requirement_code='NODE_OWNERSHIP'
     and source_type='SYSTEM';

  update public.node_capability_request_requirements
     set status=case when v_network_ok then 'VERIFIED' else 'PENDING' end,
         evidence=jsonb_build_object('system_check','NETWORK_ENABLED','passed',v_network_ok)
   where request_id=v_req.id
     and requirement_code='NETWORK_ENABLED'
     and source_type='SYSTEM';

  if v_cap='LAST_MILE_ORIGIN' then
    update public.node_capability_request_requirements
       set status=case when v_receive_ok then 'VERIFIED' else 'PENDING' end,
           evidence=jsonb_build_object('system_check','RECEIVE_CARGO_ENABLED','passed',v_receive_ok)
     where request_id=v_req.id
       and requirement_code='RECEIVE_CARGO_ENABLED'
       and source_type='SYSTEM';

    update public.node_capability_request_requirements
       set status=case when v_handoff_ok then 'VERIFIED' else 'PENDING' end,
           evidence=jsonb_build_object('system_check','HANDOFF_CARGO_ENABLED','passed',v_handoff_ok)
     where request_id=v_req.id
       and requirement_code='HANDOFF_CARGO_ENABLED'
       and source_type='SYSTEM';

    update public.node_capability_request_requirements
       set status=case when v_home_ok then 'VERIFIED' else 'PENDING' end,
           evidence=jsonb_build_object(
             'system_check','HOME_DELIVERY_COVERAGE',
             'passed',v_home_ok,
             'community_id',v_node.community_id
           )
     where request_id=v_req.id
       and requirement_code='HOME_DELIVERY_COVERAGE'
       and source_type='SYSTEM';
  end if;
end;
$$;

revoke all on function public.tc_refresh_node_capability_requirements(uuid)
  from public,anon,authenticated,service_role;

comment on table public.node_capability_requests is
'Governed request to enable a logistics capability on an operational NODE. Direct authenticated writes to operational_location_capabilities remain closed.';

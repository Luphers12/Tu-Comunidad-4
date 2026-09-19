begin;

create table if not exists public.tc_governance_profiles (
  profile_id uuid primary key references public.profiles(id) on delete restrict,
  person_id uuid not null references public.persons(id) on delete restrict,
  governance_status text not null default 'PENDING'
    check (governance_status in ('PENDING','ACTIVE','SUSPENDED','RETIRED')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (person_id)
);

alter table public.tc_governance_profiles enable row level security;
revoke all on public.tc_governance_profiles from anon, authenticated;

create table if not exists public.tc_governance_workspaces (
  id uuid primary key default gen_random_uuid(),
  workspace_code text not null unique default public.tc_generate_public_id('GWS'),
  council_term_id uuid not null references public.tc_governance_council_terms(id) on delete restrict,
  seat_id uuid not null references public.tc_governance_seat_catalog(id) on delete restrict,
  governance_profile_id uuid not null references public.tc_governance_profiles(profile_id) on delete restrict,
  status text not null default 'PENDING'
    check (status in ('PENDING','ACTIVE','SUSPENDED','CLOSED')),
  opened_at timestamptz,
  closed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (council_term_id, seat_id),
  unique (council_term_id, governance_profile_id)
);

alter table public.tc_governance_workspaces enable row level security;
revoke all on public.tc_governance_workspaces from anon, authenticated;

alter table public.tc_governance_council_memberships
  add column if not exists governance_workspace_id uuid references public.tc_governance_workspaces(id) on delete restrict;

create or replace function public.tc_guard_governance_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_person uuid;
  v_type text;
begin
  select p.person_id, p.profile_type
    into v_person, v_type
  from public.profiles p
  where p.id = new.profile_id;

  if v_person is null then
    raise exception 'GOVERNANCE_PROFILE_NOT_FOUND';
  end if;
  if v_type <> 'GOV' then
    raise exception 'GOVERNANCE_PROFILE_TYPE_REQUIRED';
  end if;
  if new.person_id <> v_person then
    raise exception 'GOVERNANCE_PROFILE_PERSON_MISMATCH';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_governance_profile on public.tc_governance_profiles;
create trigger trg_guard_governance_profile
before insert or update on public.tc_governance_profiles
for each row execute function public.tc_guard_governance_profile();

create or replace function public.tc_guard_governance_workspace()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_gp record;
  v_seat_status text;
begin
  select gp.governance_status, p.profile_type
    into v_gp
  from public.tc_governance_profiles gp
  join public.profiles p on p.id = gp.profile_id
  where gp.profile_id = new.governance_profile_id;

  if not found or v_gp.profile_type <> 'GOV' then
    raise exception 'DEDICATED_GOVERNANCE_PROFILE_REQUIRED';
  end if;

  if v_gp.governance_status not in ('PENDING','ACTIVE') then
    raise exception 'GOVERNANCE_PROFILE_NOT_ELIGIBLE_FOR_WORKSPACE';
  end if;

  select s.status into v_seat_status
  from public.tc_governance_seat_catalog s
  where s.id = new.seat_id;

  if v_seat_status <> 'DESIGN_APPROVED' then
    raise exception 'GOVERNANCE_SEAT_NOT_AVAILABLE';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_guard_governance_workspace on public.tc_governance_workspaces;
create trigger trg_guard_governance_workspace
before insert or update on public.tc_governance_workspaces
for each row execute function public.tc_guard_governance_workspace();

create or replace function public.tc_guard_governance_membership_workspace()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ws record;
  v_type text;
begin
  select w.council_term_id, w.seat_id, w.governance_profile_id, w.status,
         p.profile_type
    into v_ws
  from public.tc_governance_workspaces w
  join public.profiles p on p.id = w.governance_profile_id
  where w.id = new.governance_workspace_id;

  if not found then
    raise exception 'GOVERNANCE_WORKSPACE_REQUIRED';
  end if;

  if v_ws.profile_type <> 'GOV' then
    raise exception 'DEDICATED_GOVERNANCE_PROFILE_REQUIRED';
  end if;

  if new.profile_id <> v_ws.governance_profile_id then
    raise exception 'MEMBERSHIP_PROFILE_MUST_MATCH_GOVERNANCE_WORKSPACE';
  end if;

  if new.council_term_id <> v_ws.council_term_id or new.seat_id <> v_ws.seat_id then
    raise exception 'MEMBERSHIP_WORKSPACE_SCOPE_MISMATCH';
  end if;

  if new.status = 'ACTIVE' and v_ws.status <> 'ACTIVE' then
    raise exception 'ACTIVE_MEMBERSHIP_REQUIRES_ACTIVE_WORKSPACE';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_guard_governance_membership_workspace on public.tc_governance_council_memberships;
create trigger trg_guard_governance_membership_workspace
before insert or update on public.tc_governance_council_memberships
for each row execute function public.tc_guard_governance_membership_workspace();

comment on table public.tc_governance_profiles is
'Dedicated governance profile layer. Governance powers must not be attached directly to ordinary client, seller, driver, linguistic, learning or other operational profiles.';

comment on table public.tc_governance_workspaces is
'Independent workspace for a governance seat during a council term. Stores seat context separately from the person''s ordinary profiles.';

commit;
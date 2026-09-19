create extension if not exists postgis with schema extensions;

-- ─────────────────────────────────────────────────────────────────────────────
-- PRIVATE CUSTOMER LOCATIONS
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.customer_locations (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('LOC'),
  person_id uuid not null references public.persons(id) on delete restrict,
  country_id uuid not null references public.countries(id) on delete restrict,
  department_id uuid not null references public.departments(id) on delete restrict,
  municipality_id uuid not null references public.municipalities(id) on delete restrict,
  community_id uuid not null references public.communities(id) on delete restrict,
  destination_type text not null default 'HOME'
    check (destination_type in ('HOME','SAFE_LOCATION','TEMPORARY')),
  purpose text not null default 'CUSTOMER_DESTINATION'
    check (purpose = 'CUSTOMER_DESTINATION'),
  label text not null,
  point extensions.geography(Point,4326),
  visual_reference text not null,
  access_instructions text,
  authorized_contact text,
  photo_refs text[] not null default '{}'::text[],
  safe_location_ref text,
  ptc_id uuid references public.ptc_points(id) on delete set null,
  is_default boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_customer_locations_person_active
  on public.customer_locations(person_id, active, is_default);
create index if not exists idx_customer_locations_community
  on public.customer_locations(community_id);
create index if not exists idx_customer_locations_point
  on public.customer_locations using gist(point);
create unique index if not exists uq_customer_locations_one_default
  on public.customer_locations(person_id)
  where active and is_default;

alter table public.customer_locations enable row level security;

create policy customer_locations_self_read
on public.customer_locations
for select to authenticated
using (person_id = public.current_user_person_id());

-- All customer-location mutations go through the hardened RPCs below.
revoke insert, update, delete on public.customer_locations from anon, authenticated;

create table if not exists public.location_change_events (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('LCE'),
  location_id uuid not null references public.customer_locations(id) on delete restrict,
  actor_person_id uuid not null references public.persons(id) on delete restrict,
  event_type text not null check (event_type in ('CREATED','UPDATED','DEFAULT_CHANGED','DEACTIVATED')),
  before_snapshot jsonb,
  after_snapshot jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_location_change_events_location_time
  on public.location_change_events(location_id, created_at desc);
create index if not exists idx_location_change_events_actor_time
  on public.location_change_events(actor_person_id, created_at desc);

alter table public.location_change_events enable row level security;
create policy location_change_events_self_read
on public.location_change_events
for select to authenticated
using (actor_person_id = public.current_user_person_id());
revoke insert, update, delete on public.location_change_events from anon, authenticated;

create or replace function public.tc_log_customer_location_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event text;
  v_actor uuid;
begin
  v_actor := coalesce(public.current_user_person_id(), coalesce(new.person_id, old.person_id));
  if tg_op = 'INSERT' then
    v_event := 'CREATED';
    insert into public.location_change_events(location_id, actor_person_id, event_type, before_snapshot, after_snapshot)
    values (new.id, v_actor, v_event, null, to_jsonb(new) - 'point' - 'authorized_contact' - 'photo_refs');
    return new;
  end if;

  if tg_op = 'UPDATE' then
    if old.active and not new.active then
      v_event := 'DEACTIVATED';
    elsif old.is_default is distinct from new.is_default then
      v_event := 'DEFAULT_CHANGED';
    else
      v_event := 'UPDATED';
    end if;
    insert into public.location_change_events(location_id, actor_person_id, event_type, before_snapshot, after_snapshot)
    values (
      new.id, v_actor, v_event,
      to_jsonb(old) - 'point' - 'authorized_contact' - 'photo_refs',
      to_jsonb(new) - 'point' - 'authorized_contact' - 'photo_refs'
    );
    return new;
  end if;
  return null;
end;
$$;

revoke all on function public.tc_log_customer_location_change() from public, anon, authenticated;

drop trigger if exists trg_customer_location_change on public.customer_locations;
create trigger trg_customer_location_change
after insert or update on public.customer_locations
for each row execute function public.tc_log_customer_location_change();

-- ─────────────────────────────────────────────────────────────────────────────
-- OPERATIONAL LOCATIONS (STORE/PTC ORIGINS; NEVER CUSTOMER HOMES)
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.operational_locations (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('OPL'),
  purpose text not null check (purpose in ('STORE_PICKUP','PTC_PICKUP')),
  external_ref text,
  name text not null,
  country_id uuid not null references public.countries(id) on delete restrict,
  department_id uuid not null references public.departments(id) on delete restrict,
  municipality_id uuid not null references public.municipalities(id) on delete restrict,
  community_id uuid not null references public.communities(id) on delete restrict,
  point extensions.geography(Point,4326),
  visual_reference text,
  access_instructions text,
  operational_contact text,
  created_by_person_id uuid not null references public.persons(id) on delete restrict,
  owner_profile_id uuid references public.profiles(id) on delete set null,
  ptc_id uuid references public.ptc_points(id) on delete set null,
  verification_status text not null default 'UNVERIFIED'
    check (verification_status in ('UNVERIFIED','PENDING_REVIEW','VERIFIED','REJECTED')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (not (purpose = 'STORE_PICKUP' and ptc_id is not null))
);

create index if not exists idx_operational_locations_creator
  on public.operational_locations(created_by_person_id, active);
create index if not exists idx_operational_locations_owner_profile
  on public.operational_locations(owner_profile_id);
create index if not exists idx_operational_locations_ptc
  on public.operational_locations(ptc_id);
create index if not exists idx_operational_locations_community
  on public.operational_locations(community_id, purpose, active);
create index if not exists idx_operational_locations_point
  on public.operational_locations using gist(point);

alter table public.operational_locations enable row level security;
create policy operational_locations_owner_read
on public.operational_locations
for select to authenticated
using (
  created_by_person_id = public.current_user_person_id()
  or exists (
    select 1 from public.profiles p
    where p.id = operational_locations.owner_profile_id
      and p.person_id = public.current_user_person_id()
  )
);
revoke insert, update, delete on public.operational_locations from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- AFFILIATION APPLICATIONS
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.affiliation_applications (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('AFF'),
  person_id uuid not null references public.persons(id) on delete restrict,
  requested_role_code text not null
    check (requested_role_code in ('TIE','VEN','CON','RSG','PTC')),
  community_id uuid references public.communities(id) on delete restrict,
  operational_location_id uuid references public.operational_locations(id) on delete set null,
  state text not null default 'DRAFT'
    check (state in ('DRAFT','SUBMITTED','UNDER_REVIEW','CHANGES_REQUESTED','APPROVED','REJECTED','WITHDRAWN')),
  applicant_note text,
  activated_profile_id uuid references public.profiles(id) on delete set null,
  submitted_at timestamptz,
  resolved_at timestamptz,
  version bigint not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists uq_affiliation_active_role_per_person
  on public.affiliation_applications(person_id, requested_role_code)
  where state in ('DRAFT','SUBMITTED','UNDER_REVIEW','CHANGES_REQUESTED');
create index if not exists idx_affiliation_applications_person_time
  on public.affiliation_applications(person_id, created_at desc);
create index if not exists idx_affiliation_applications_state
  on public.affiliation_applications(state, requested_role_code, created_at);

alter table public.affiliation_applications enable row level security;
create policy affiliation_applications_self_read
on public.affiliation_applications
for select to authenticated
using (person_id = public.current_user_person_id());
revoke insert, update, delete on public.affiliation_applications from anon, authenticated;

create table if not exists public.affiliation_application_requirements (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.affiliation_applications(id) on delete restrict,
  requirement_code text not null,
  required boolean not null default true,
  status text not null default 'PENDING'
    check (status in ('PENDING','PROVIDED','VERIFIED','WAIVED','REJECTED')),
  applicant_payload jsonb not null default '{}'::jsonb,
  reviewer_note text,
  provided_at timestamptz,
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(application_id, requirement_code)
);

create index if not exists idx_affiliation_requirements_application
  on public.affiliation_application_requirements(application_id, status);
alter table public.affiliation_application_requirements enable row level security;
create policy affiliation_requirements_self_read
on public.affiliation_application_requirements
for select to authenticated
using (exists (
  select 1 from public.affiliation_applications a
  where a.id = affiliation_application_requirements.application_id
    and a.person_id = public.current_user_person_id()
));
revoke insert, update, delete on public.affiliation_application_requirements from anon, authenticated;

create table if not exists public.affiliation_application_evidence_links (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.affiliation_applications(id) on delete restrict,
  evidence_id uuid not null references public.evidence(id) on delete restrict,
  requirement_code text,
  created_at timestamptz not null default now(),
  unique(application_id, evidence_id)
);

create index if not exists idx_affiliation_evidence_application
  on public.affiliation_application_evidence_links(application_id);
alter table public.affiliation_application_evidence_links enable row level security;
create policy affiliation_evidence_self_read
on public.affiliation_application_evidence_links
for select to authenticated
using (exists (
  select 1 from public.affiliation_applications a
  where a.id = affiliation_application_evidence_links.application_id
    and a.person_id = public.current_user_person_id()
));
revoke insert, update, delete on public.affiliation_application_evidence_links from anon, authenticated;

create table if not exists public.affiliation_reviews (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.affiliation_applications(id) on delete restrict,
  reviewer_profile_id uuid not null references public.profiles(id) on delete restrict,
  decision text not null check (decision in ('REQUEST_CHANGES','RECOMMEND_APPROVAL','RECOMMEND_REJECTION','APPROVE','REJECT')),
  rationale text,
  created_at timestamptz not null default now()
);
create index if not exists idx_affiliation_reviews_application
  on public.affiliation_reviews(application_id, created_at desc);
alter table public.affiliation_reviews enable row level security;
create policy affiliation_reviews_applicant_read
on public.affiliation_reviews
for select to authenticated
using (exists (
  select 1 from public.affiliation_applications a
  where a.id = affiliation_reviews.application_id
    and a.person_id = public.current_user_person_id()
));
revoke insert, update, delete on public.affiliation_reviews from anon, authenticated;

create table if not exists public.affiliation_events (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('AFE'),
  application_id uuid not null references public.affiliation_applications(id) on delete restrict,
  actor_person_id uuid references public.persons(id) on delete restrict,
  actor_profile_id uuid references public.profiles(id) on delete restrict,
  event_type text not null,
  from_state text,
  to_state text,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists idx_affiliation_events_application_time
  on public.affiliation_events(application_id, created_at desc);
alter table public.affiliation_events enable row level security;
create policy affiliation_events_applicant_read
on public.affiliation_events
for select to authenticated
using (exists (
  select 1 from public.affiliation_applications a
  where a.id = affiliation_events.application_id
    and a.person_id = public.current_user_person_id()
));
revoke insert, update, delete on public.affiliation_events from anon, authenticated;

create or replace function public.tc_log_affiliation_state_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid;
begin
  v_actor := public.current_user_person_id();
  if tg_op = 'INSERT' then
    insert into public.affiliation_events(application_id, actor_person_id, event_type, from_state, to_state)
    values (new.id, coalesce(v_actor,new.person_id), 'APPLICATION_CREATED', null, new.state);
    return new;
  end if;
  if tg_op = 'UPDATE' and (old.state is distinct from new.state) then
    insert into public.affiliation_events(application_id, actor_person_id, event_type, from_state, to_state)
    values (new.id, coalesce(v_actor,new.person_id), 'STATE_CHANGED', old.state, new.state);
  end if;
  return new;
end;
$$;
revoke all on function public.tc_log_affiliation_state_change() from public, anon, authenticated;

drop trigger if exists trg_affiliation_state_change on public.affiliation_applications;
create trigger trg_affiliation_state_change
after insert or update on public.affiliation_applications
for each row execute function public.tc_log_affiliation_state_change();

-- Capability catalog only; grants are deliberately NOT automatic.
insert into public.capabilities(name) values
  ('affiliation.review'),
  ('affiliation.approve'),
  ('affiliation.manage')
on conflict (name) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- RPC: CUSTOMER ADDRESSES
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.tc_my_addresses()
returns table(
  id uuid,
  label text,
  destination_type text,
  community_id uuid,
  community_name text,
  municipality_name text,
  department_name text,
  visual_reference text,
  access_instructions text,
  authorized_contact text,
  lat double precision,
  lng double precision,
  is_default boolean,
  active boolean,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select l.id,l.label,l.destination_type,l.community_id,c.name,m.name,d.name,
         l.visual_reference,l.access_instructions,l.authorized_contact,
         case when l.point is null then null else extensions.st_y(l.point::extensions.geometry) end,
         case when l.point is null then null else extensions.st_x(l.point::extensions.geometry) end,
         l.is_default,l.active,l.created_at
  from public.customer_locations l
  join public.communities c on c.id=l.community_id
  join public.municipalities m on m.id=l.municipality_id
  join public.departments d on d.id=l.department_id
  where auth.uid() is not null
    and l.person_id=public.current_user_person_id()
    and l.active
  order by l.is_default desc,l.created_at;
$$;
revoke all on function public.tc_my_addresses() from public, anon;
grant execute on function public.tc_my_addresses() to authenticated;

create or replace function public.tc_save_address(
  p_location_id uuid,
  p_label text,
  p_community_id uuid,
  p_visual_reference text,
  p_access_instructions text,
  p_authorized_contact text,
  p_lat double precision default null,
  p_lng double precision default null,
  p_make_default boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_person uuid;
  v_country uuid;
  v_department uuid;
  v_municipality uuid;
  v_point extensions.geography(Point,4326);
  v_id uuid;
  v_first boolean;
begin
  if auth.uid() is null then raise exception 'TC_UNAUTHENTICATED' using errcode='P0001'; end if;
  v_person := public.current_user_person_id();
  if v_person is null then raise exception 'PERSON_REQUIRED' using errcode='P0001'; end if;
  if coalesce(btrim(p_label),'')='' then raise exception 'LABEL_REQUIRED' using errcode='P0001'; end if;
  if coalesce(btrim(p_visual_reference),'')='' then raise exception 'REFERENCE_REQUIRED' using errcode='P0001'; end if;
  if (p_lat is null) <> (p_lng is null) then raise exception 'COORDINATES_INCOMPLETE' using errcode='P0001'; end if;
  if p_lat is not null and (p_lat < -90 or p_lat > 90 or p_lng < -180 or p_lng > 180) then raise exception 'COORDINATES_INVALID' using errcode='P0001'; end if;

  select co.id,d.id,m.id
    into v_country,v_department,v_municipality
  from public.communities c
  join public.municipalities m on m.id=c.municipality_id and m.is_active
  join public.departments d on d.id=m.department_id and d.is_active
  join public.countries co on co.id=d.country_id and co.is_active
  where c.id=p_community_id and c.is_active;
  if v_municipality is null then raise exception 'COMMUNITY_REQUIRED' using errcode='P0001'; end if;

  if p_lat is not null then
    v_point := extensions.st_setsrid(extensions.st_makepoint(p_lng,p_lat),4326)::extensions.geography;
  end if;

  if p_location_id is null then
    select not exists(select 1 from public.customer_locations where person_id=v_person and active) into v_first;
    insert into public.customer_locations(person_id,country_id,department_id,municipality_id,community_id,label,point,visual_reference,access_instructions,authorized_contact,is_default)
    values(v_person,v_country,v_department,v_municipality,p_community_id,btrim(p_label),v_point,btrim(p_visual_reference),nullif(btrim(coalesce(p_access_instructions,'')),''),nullif(btrim(coalesce(p_authorized_contact,'')),''),coalesce(v_first,false))
    returning id into v_id;
  else
    update public.customer_locations
       set country_id=v_country,department_id=v_department,municipality_id=v_municipality,community_id=p_community_id,
           label=btrim(p_label),
           point=case when p_lat is null then point else v_point end,
           visual_reference=btrim(p_visual_reference),
           access_instructions=nullif(btrim(coalesce(p_access_instructions,'')),''),
           authorized_contact=nullif(btrim(coalesce(p_authorized_contact,'')),''),
           updated_at=now()
     where id=p_location_id and person_id=v_person
     returning id into v_id;
    if v_id is null then raise exception 'LOCATION_NOT_FOUND' using errcode='P0001'; end if;
  end if;

  if p_make_default or exists(select 1 from public.customer_locations where id=v_id and is_default) then
    update public.customer_locations set is_default=(id=v_id),updated_at=now() where person_id=v_person and active;
  end if;
  return v_id;
end;
$$;
revoke all on function public.tc_save_address(uuid,text,uuid,text,text,text,double precision,double precision,boolean) from public, anon;
grant execute on function public.tc_save_address(uuid,text,uuid,text,text,text,double precision,double precision,boolean) to authenticated;

create or replace function public.tc_set_default_address(p_location_id uuid)
returns boolean
language plpgsql
security definer
set search_path=''
as $$
declare v_person uuid;
begin
  if auth.uid() is null then raise exception 'TC_UNAUTHENTICATED' using errcode='P0001'; end if;
  v_person:=public.current_user_person_id();
  if not exists(select 1 from public.customer_locations where id=p_location_id and person_id=v_person and active) then
    raise exception 'LOCATION_NOT_FOUND' using errcode='P0001';
  end if;
  update public.customer_locations set is_default=(id=p_location_id),updated_at=now() where person_id=v_person and active;
  return true;
end;
$$;
revoke all on function public.tc_set_default_address(uuid) from public, anon;
grant execute on function public.tc_set_default_address(uuid) to authenticated;

create or replace function public.tc_deactivate_address(p_location_id uuid)
returns boolean
language plpgsql
security definer
set search_path=''
as $$
declare v_person uuid; v_was_default boolean;
begin
  if auth.uid() is null then raise exception 'TC_UNAUTHENTICATED' using errcode='P0001'; end if;
  v_person:=public.current_user_person_id();
  select is_default into v_was_default from public.customer_locations where id=p_location_id and person_id=v_person and active;
  if not found then raise exception 'LOCATION_NOT_FOUND' using errcode='P0001'; end if;
  update public.customer_locations set active=false,is_default=false,updated_at=now() where id=p_location_id and person_id=v_person;
  if coalesce(v_was_default,false) then
    update public.customer_locations set is_default=true,updated_at=now()
    where id=(select id from public.customer_locations where person_id=v_person and active order by created_at limit 1);
  end if;
  return true;
end;
$$;
revoke all on function public.tc_deactivate_address(uuid) from public, anon;
grant execute on function public.tc_deactivate_address(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- RPC: OPERATIONAL LOCATIONS
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.tc_operational_locations(p_purpose text default null)
returns table(
  id uuid,
  public_code text,
  purpose text,
  external_ref text,
  name text,
  community_id uuid,
  community_name text,
  municipality_name text,
  department_name text,
  visual_reference text,
  access_instructions text,
  operational_contact text,
  lat double precision,
  lng double precision,
  is_mine boolean,
  active boolean,
  created_at timestamptz
)
language sql
stable
security definer
set search_path=''
as $$
  select l.id,l.public_id,l.purpose,l.external_ref,l.name,l.community_id,c.name,m.name,d.name,
         l.visual_reference,l.access_instructions,l.operational_contact,
         case when l.point is null then null else extensions.st_y(l.point::extensions.geometry) end,
         case when l.point is null then null else extensions.st_x(l.point::extensions.geometry) end,
         true,l.active,l.created_at
  from public.operational_locations l
  join public.communities c on c.id=l.community_id
  join public.municipalities m on m.id=l.municipality_id
  join public.departments d on d.id=l.department_id
  where auth.uid() is not null
    and l.created_by_person_id=public.current_user_person_id()
    and l.active
    and (p_purpose is null or l.purpose=upper(btrim(p_purpose)))
  order by l.created_at;
$$;
revoke all on function public.tc_operational_locations(text) from public, anon;
grant execute on function public.tc_operational_locations(text) to authenticated;

create or replace function public.tc_save_operational_location(
  p_location_id uuid,
  p_purpose text,
  p_name text,
  p_community_id uuid,
  p_external_ref text default null,
  p_visual_reference text default null,
  p_access_instructions text default null,
  p_operational_contact text default null,
  p_lat double precision default null,
  p_lng double precision default null
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  v_person uuid;
  v_country uuid; v_department uuid; v_municipality uuid;
  v_point extensions.geography(Point,4326);
  v_id uuid;
  v_purpose text;
begin
  if auth.uid() is null then raise exception 'TC_UNAUTHENTICATED' using errcode='P0001'; end if;
  v_person:=public.current_user_person_id();
  if v_person is null then raise exception 'PERSON_REQUIRED' using errcode='P0001'; end if;
  v_purpose:=upper(btrim(coalesce(p_purpose,'')));
  if v_purpose not in ('STORE_PICKUP','PTC_PICKUP') then raise exception 'PURPOSE_INVALID' using errcode='P0001'; end if;
  if coalesce(btrim(p_name),'')='' then raise exception 'NAME_REQUIRED' using errcode='P0001'; end if;
  if (p_lat is null) <> (p_lng is null) then raise exception 'COORDINATES_INCOMPLETE' using errcode='P0001'; end if;
  if p_lat is not null and (p_lat < -90 or p_lat > 90 or p_lng < -180 or p_lng > 180) then raise exception 'COORDINATES_INVALID' using errcode='P0001'; end if;

  select co.id,d.id,m.id into v_country,v_department,v_municipality
  from public.communities c
  join public.municipalities m on m.id=c.municipality_id and m.is_active
  join public.departments d on d.id=m.department_id and d.is_active
  join public.countries co on co.id=d.country_id and co.is_active
  where c.id=p_community_id and c.is_active;
  if v_municipality is null then raise exception 'COMMUNITY_REQUIRED' using errcode='P0001'; end if;
  if p_lat is not null then v_point:=extensions.st_setsrid(extensions.st_makepoint(p_lng,p_lat),4326)::extensions.geography; end if;

  if p_location_id is null then
    insert into public.operational_locations(purpose,external_ref,name,country_id,department_id,municipality_id,community_id,point,visual_reference,access_instructions,operational_contact,created_by_person_id)
    values(v_purpose,nullif(btrim(coalesce(p_external_ref,'')),''),btrim(p_name),v_country,v_department,v_municipality,p_community_id,v_point,
           nullif(btrim(coalesce(p_visual_reference,'')),''),nullif(btrim(coalesce(p_access_instructions,'')),''),nullif(btrim(coalesce(p_operational_contact,'')),''),v_person)
    returning id into v_id;
  else
    update public.operational_locations
       set purpose=v_purpose,external_ref=nullif(btrim(coalesce(p_external_ref,'')),''),name=btrim(p_name),country_id=v_country,department_id=v_department,municipality_id=v_municipality,community_id=p_community_id,
           point=case when p_lat is null then point else v_point end,
           visual_reference=nullif(btrim(coalesce(p_visual_reference,'')),''),
           access_instructions=nullif(btrim(coalesce(p_access_instructions,'')),''),
           operational_contact=nullif(btrim(coalesce(p_operational_contact,'')),''),updated_at=now()
     where id=p_location_id and created_by_person_id=v_person
     returning id into v_id;
    if v_id is null then raise exception 'LOCATION_NOT_FOUND' using errcode='P0001'; end if;
  end if;
  return v_id;
end;
$$;
revoke all on function public.tc_save_operational_location(uuid,text,text,uuid,text,text,text,text,double precision,double precision) from public, anon;
grant execute on function public.tc_save_operational_location(uuid,text,text,uuid,text,text,text,text,double precision,double precision) to authenticated;

create or replace function public.tc_set_operational_location_active(p_location_id uuid,p_active boolean)
returns boolean
language plpgsql
security definer
set search_path=''
as $$
declare v_person uuid; v_id uuid;
begin
  if auth.uid() is null then raise exception 'TC_UNAUTHENTICATED' using errcode='P0001'; end if;
  v_person:=public.current_user_person_id();
  update public.operational_locations set active=p_active,updated_at=now()
   where id=p_location_id and created_by_person_id=v_person
   returning id into v_id;
  if v_id is null then raise exception 'LOCATION_NOT_FOUND' using errcode='P0001'; end if;
  return true;
end;
$$;
revoke all on function public.tc_set_operational_location_active(uuid,boolean) from public, anon;
grant execute on function public.tc_set_operational_location_active(uuid,boolean) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- RPC: AFFILIATION APPLICANT FLOW
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.tc_start_affiliation(
  p_requested_role_code text,
  p_community_id uuid default null,
  p_operational_location_id uuid default null,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_person uuid;
  v_role text;
  v_app_id uuid;
  v_public_id text;
begin
  if auth.uid() is null then raise exception 'TC_UNAUTHENTICATED' using errcode='P0001'; end if;
  v_person:=public.current_user_person_id();
  if v_person is null then raise exception 'PERSON_REQUIRED' using errcode='P0001'; end if;
  v_role:=upper(btrim(coalesce(p_requested_role_code,'')));
  if v_role not in ('TIE','VEN','CON','RSG','PTC') then raise exception 'AFFILIATION_ROLE_INVALID' using errcode='P0001'; end if;
  if p_community_id is not null and not exists(select 1 from public.communities where id=p_community_id and is_active) then raise exception 'COMMUNITY_REQUIRED' using errcode='P0001'; end if;
  if p_operational_location_id is not null and not exists(select 1 from public.operational_locations where id=p_operational_location_id and created_by_person_id=v_person and active) then raise exception 'OPERATIONAL_LOCATION_NOT_ALLOWED' using errcode='P0001'; end if;

  select id,public_id into v_app_id,v_public_id
  from public.affiliation_applications
  where person_id=v_person and requested_role_code=v_role and state in ('DRAFT','SUBMITTED','UNDER_REVIEW','CHANGES_REQUESTED')
  order by created_at desc limit 1;
  if v_app_id is not null then
    return jsonb_build_object('application_public_id',v_public_id,'state',(select state from public.affiliation_applications where id=v_app_id),'already_exists',true);
  end if;

  insert into public.affiliation_applications(person_id,requested_role_code,community_id,operational_location_id,applicant_note)
  values(v_person,v_role,p_community_id,p_operational_location_id,nullif(btrim(coalesce(p_note,'')),''))
  returning id,public_id into v_app_id,v_public_id;

  insert into public.affiliation_application_requirements(application_id,requirement_code,required)
  select v_app_id,x.code,x.required
  from (
    values
      ('IDENTITY',true),
      ('COMMUNITY',true),
      ('TERMS',true)
  ) as x(code,required);

  if v_role='TIE' then
    insert into public.affiliation_application_requirements(application_id,requirement_code,required) values
      (v_app_id,'STORE_INFO',true),(v_app_id,'OPERATIONAL_LOCATION',true),(v_app_id,'CONTACT_METHOD',true);
  elsif v_role='VEN' then
    insert into public.affiliation_application_requirements(application_id,requirement_code,required) values
      (v_app_id,'SELLER_INFO',true),(v_app_id,'CONTACT_METHOD',true);
  elsif v_role='CON' then
    insert into public.affiliation_application_requirements(application_id,requirement_code,required) values
      (v_app_id,'LICENSE_OR_PERMIT',true),(v_app_id,'VEHICLE',true),(v_app_id,'SERVICE_AREA',true);
  elsif v_role='RSG' then
    insert into public.affiliation_application_requirements(application_id,requirement_code,required) values
      (v_app_id,'SERVICE_AREA',true),(v_app_id,'CONTACT_METHOD',true);
  elsif v_role='PTC' then
    insert into public.affiliation_application_requirements(application_id,requirement_code,required) values
      (v_app_id,'OPERATIONAL_LOCATION',true),(v_app_id,'CONTACT_METHOD',true);
  end if;

  return jsonb_build_object('application_public_id',v_public_id,'state','DRAFT','already_exists',false);
end;
$$;
revoke all on function public.tc_start_affiliation(text,uuid,uuid,text) from public, anon;
grant execute on function public.tc_start_affiliation(text,uuid,uuid,text) to authenticated;

create or replace function public.tc_my_affiliations()
returns jsonb
language sql
stable
security definer
set search_path=''
as $$
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'application_public_id',a.public_id,
      'requested_role_code',a.requested_role_code,
      'state',a.state,
      'community_id',a.community_id,
      'operational_location_id',a.operational_location_id,
      'submitted_at',a.submitted_at,
      'resolved_at',a.resolved_at,
      'created_at',a.created_at,
      'requirements',(
        select coalesce(jsonb_agg(jsonb_build_object('code',r.requirement_code,'required',r.required,'status',r.status,'payload',r.applicant_payload) order by r.requirement_code),'[]'::jsonb)
        from public.affiliation_application_requirements r where r.application_id=a.id
      )
    ) order by a.created_at desc
  ),'[]'::jsonb)
  from public.affiliation_applications a
  where auth.uid() is not null and a.person_id=public.current_user_person_id();
$$;
revoke all on function public.tc_my_affiliations() from public, anon;
grant execute on function public.tc_my_affiliations() to authenticated;

create or replace function public.tc_provide_affiliation_requirement(
  p_application_public_id text,
  p_requirement_code text,
  p_payload jsonb default '{}'::jsonb
)
returns boolean
language plpgsql
security definer
set search_path=''
as $$
declare v_person uuid; v_app_id uuid; v_state text; v_updated int;
begin
  if auth.uid() is null then raise exception 'TC_UNAUTHENTICATED' using errcode='P0001'; end if;
  v_person:=public.current_user_person_id();
  select id,state into v_app_id,v_state from public.affiliation_applications
  where public_id=upper(btrim(p_application_public_id)) and person_id=v_person;
  if v_app_id is null then raise exception 'AFFILIATION_NOT_FOUND' using errcode='P0001'; end if;
  if v_state not in ('DRAFT','CHANGES_REQUESTED') then raise exception 'AFFILIATION_NOT_EDITABLE' using errcode='P0001'; end if;
  update public.affiliation_application_requirements
     set status='PROVIDED',applicant_payload=coalesce(p_payload,'{}'::jsonb),provided_at=now(),updated_at=now()
   where application_id=v_app_id and requirement_code=upper(btrim(p_requirement_code));
  get diagnostics v_updated=row_count;
  if v_updated<>1 then raise exception 'AFFILIATION_REQUIREMENT_NOT_FOUND' using errcode='P0001'; end if;
  return true;
end;
$$;
revoke all on function public.tc_provide_affiliation_requirement(text,text,jsonb) from public, anon;
grant execute on function public.tc_provide_affiliation_requirement(text,text,jsonb) to authenticated;

create or replace function public.tc_submit_affiliation_application(p_application_public_id text)
returns boolean
language plpgsql
security definer
set search_path=''
as $$
declare v_person uuid; v_app_id uuid; v_state text;
begin
  if auth.uid() is null then raise exception 'TC_UNAUTHENTICATED' using errcode='P0001'; end if;
  v_person:=public.current_user_person_id();
  select id,state into v_app_id,v_state from public.affiliation_applications
  where public_id=upper(btrim(p_application_public_id)) and person_id=v_person for update;
  if v_app_id is null then raise exception 'AFFILIATION_NOT_FOUND' using errcode='P0001'; end if;
  if v_state not in ('DRAFT','CHANGES_REQUESTED') then raise exception 'AFFILIATION_NOT_SUBMITTABLE' using errcode='P0001'; end if;
  if exists(select 1 from public.affiliation_application_requirements where application_id=v_app_id and required and status not in ('PROVIDED','VERIFIED','WAIVED')) then
    raise exception 'AFFILIATION_REQUIREMENTS_INCOMPLETE' using errcode='P0001';
  end if;
  update public.affiliation_applications set state='SUBMITTED',submitted_at=now(),updated_at=now(),version=version+1 where id=v_app_id;
  return true;
end;
$$;
revoke all on function public.tc_submit_affiliation_application(text) from public, anon;
grant execute on function public.tc_submit_affiliation_application(text) to authenticated;

create or replace function public.tc_withdraw_affiliation_application(p_application_public_id text)
returns boolean
language plpgsql
security definer
set search_path=''
as $$
declare v_person uuid; v_updated int;
begin
  if auth.uid() is null then raise exception 'TC_UNAUTHENTICATED' using errcode='P0001'; end if;
  v_person:=public.current_user_person_id();
  update public.affiliation_applications
     set state='WITHDRAWN',resolved_at=now(),updated_at=now(),version=version+1
   where public_id=upper(btrim(p_application_public_id)) and person_id=v_person
     and state in ('DRAFT','SUBMITTED','CHANGES_REQUESTED');
  get diagnostics v_updated=row_count;
  if v_updated<>1 then raise exception 'AFFILIATION_NOT_WITHDRAWABLE' using errcode='P0001'; end if;
  return true;
end;
$$;
revoke all on function public.tc_withdraw_affiliation_application(text) from public, anon;
grant execute on function public.tc_withdraw_affiliation_application(text) to authenticated;


create table public.active_profile_contexts (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references public.persons(id) on delete restrict,
  session_context_key text not null,
  active_profile_id uuid not null references public.profiles(id) on delete restrict,
  activated_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (person_id,session_context_key)
);

create table public.active_profile_context_events (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('APC'),
  switch_seq bigint generated always as identity unique,
  person_id uuid not null references public.persons(id) on delete restrict,
  session_context_key text not null,
  from_profile_id uuid references public.profiles(id) on delete restrict,
  to_profile_id uuid not null references public.profiles(id) on delete restrict,
  event_type text not null default 'PROFILE_SWITCH'
    check (event_type in ('DEFAULT_SELECTED','PROFILE_SWITCH')),
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  check (public_id like 'APC-%')
);

create index active_profile_context_events_person_idx
  on public.active_profile_context_events(person_id,switch_seq desc);

create trigger active_profile_contexts_updated_at
before update on public.active_profile_contexts
for each row execute function public.tc_set_updated_at();

create trigger active_profile_context_events_append_only
before update or delete on public.active_profile_context_events
for each row execute function public.tc_guard_logistics_append_only();

alter table public.active_profile_contexts enable row level security;
alter table public.active_profile_context_events enable row level security;

revoke all on public.active_profile_contexts from public,anon,authenticated;
revoke all on public.active_profile_context_events from public,anon,authenticated;

grant select,insert,update on public.active_profile_contexts to service_role;
grant select,insert on public.active_profile_context_events to service_role;

create or replace function public.tc_session_context_key()
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid:=auth.uid();
  v_session text;
begin
  if v_uid is null then
    raise exception using errcode='P0001', message='TC_UNAUTHENTICATED';
  end if;

  v_session:=nullif(btrim(coalesce(auth.jwt()->>'session_id','')),'');

  return encode(
    extensions.digest(
      convert_to(
        v_uid::text||'|'||coalesce(v_session,'ACCOUNT_FALLBACK'),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
end;
$$;

create or replace function public.tc_active_profile_id()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_person uuid;
  v_profile uuid;
begin
  if auth.uid() is null then
    return null;
  end if;

  select p.id into v_person
  from public.persons p
  where p.auth_user_id=auth.uid();

  if v_person is null then
    return null;
  end if;

  select c.active_profile_id into v_profile
  from public.active_profile_contexts c
  join public.profiles pr on pr.id=c.active_profile_id
  where c.person_id=v_person
    and c.session_context_key=public.tc_session_context_key()
    and pr.person_id=v_person
    and pr.status='active';

  return v_profile;
end;
$$;

create or replace function public.tc_require_active_profile(
  p_profile_public_id text,
  p_expected_profile_type text default null
)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_person uuid;
  v_profile public.profiles%rowtype;
  v_active uuid;
  v_expected text:=upper(btrim(coalesce(p_expected_profile_type,'')));
begin
  if auth.uid() is null then
    raise exception using errcode='P0001', message='TC_UNAUTHENTICATED';
  end if;

  select p.id into v_person
  from public.persons p
  where p.auth_user_id=auth.uid();

  if v_person is null then
    raise exception using errcode='P0001', message='TC_SESSION_PERSON_NOT_FOUND';
  end if;

  select * into v_profile
  from public.profiles p
  where p.person_id=v_person
    and p.public_id=upper(btrim(coalesce(p_profile_public_id,'')))
    and p.status='active';

  if v_profile.id is null then
    raise exception using errcode='P0001', message='TC_PROFILE_NOT_SWITCHABLE';
  end if;

  if v_expected<>'' and v_profile.profile_type<>v_expected then
    raise exception using errcode='P0001', message='TC_ACTIVE_PROFILE_TYPE_MISMATCH';
  end if;

  v_active:=public.tc_active_profile_id();

  if v_active is null then
    raise exception using errcode='P0001', message='TC_ACTIVE_PROFILE_NOT_SELECTED';
  end if;

  if v_active is distinct from v_profile.id then
    raise exception using errcode='P0001', message='TC_ACTIVE_PROFILE_REQUIRED';
  end if;

  return v_profile.id;
end;
$$;

revoke all on function public.tc_session_context_key()
  from public,anon,authenticated,service_role;
revoke all on function public.tc_active_profile_id()
  from public,anon,authenticated,service_role;
revoke all on function public.tc_require_active_profile(text,text)
  from public,anon,authenticated,service_role;

grant execute on function public.tc_active_profile_id()
  to authenticated;

comment on table public.active_profile_contexts is
'One explicit operational subprofile per authenticated session context. A person may own many enabled profiles, but authorization-sensitive actions use only this active profile.';
comment on function public.tc_require_active_profile(text,text) is
'Private role-context guard. Ownership and status=active are necessary but insufficient; requested subprofile must also be the explicit active profile for the current session.';

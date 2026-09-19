create table public.gai_notification_read_states (
  outbox_id uuid primary key references public.gai_notification_outbox(id) on delete restrict,
  profile_id uuid not null references public.profiles(id) on delete restrict,
  read_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_gai_notification_read_states_profile on public.gai_notification_read_states(profile_id, read_at);

alter table public.gai_notification_read_states enable row level security;
revoke all on public.gai_notification_read_states from public, anon, authenticated;
grant select, insert, update, delete on public.gai_notification_read_states to service_role;

create or replace function public.internal_gai_validate_read_state()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1
    from public.gai_notification_outbox o
    where o.id = new.outbox_id
      and o.recipient_profile_id = new.profile_id
      and o.channel = 'IN_APP'
  ) then
    raise exception 'GAI_NOTIFICATION_PROFILE_MISMATCH' using errcode='foreign_key_violation';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

revoke all on function public.internal_gai_validate_read_state() from public, anon, authenticated;

create trigger trg_gai_notification_read_state_validate
before insert or update on public.gai_notification_read_states
for each row execute function public.internal_gai_validate_read_state();

create or replace function public.internal_gai_profile_can_view_incident(
  p_profile_id uuid,
  p_incident_id uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_inc public.gai_incidents%rowtype;
begin
  select * into v_inc
  from public.gai_incidents
  where id = p_incident_id;

  if not found then return false; end if;

  if v_inc.created_by_profile_id = p_profile_id or v_inc.assigned_profile_id = p_profile_id then
    return true;
  end if;

  if exists (
    select 1 from public.gai_incident_recipients r
    where r.incident_id = p_incident_id
      and r.profile_id = p_profile_id
      and r.is_active
  ) then
    return true;
  end if;

  return public.internal_has_capability(
    p_profile_id,
    'incident.read',
    v_inc.scope_type,
    v_inc.scope_target_id
  );
end;
$$;

revoke all on function public.internal_gai_profile_can_view_incident(uuid,uuid) from public, anon, authenticated;

grant execute on function public.internal_gai_profile_can_view_incident(uuid,uuid) to service_role;

create or replace function public.gai_list_my_incidents(
  p_active_profile_id uuid,
  p_state text default null,
  p_severity text default null,
  p_limit integer default 30,
  p_before timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_person_id uuid;
  v_limit int := least(greatest(coalesce(p_limit,30),1),100);
  v_result jsonb;
begin
  select pe.id into v_person_id
  from public.persons pe
  join public.profiles pr on pr.person_id=pe.id
  where pe.auth_user_id=auth.uid() and pr.id=p_active_profile_id;

  if v_person_id is null then
    raise exception 'GAI_SECURITY_VIOLATION' using errcode='invalid_authorization_specification';
  end if;

  if p_state is not null and not exists (
    select 1 from pg_catalog.pg_enum e
    join pg_catalog.pg_type t on t.oid=e.enumtypid
    join pg_catalog.pg_namespace n on n.oid=t.typnamespace
    where n.nspname='public' and t.typname='gai_incident_state' and e.enumlabel=p_state
  ) then raise exception 'GAI_INVALID_STATE_FILTER' using errcode='check_violation'; end if;

  if p_severity is not null and not exists (
    select 1 from pg_catalog.pg_enum e
    join pg_catalog.pg_type t on t.oid=e.enumtypid
    join pg_catalog.pg_namespace n on n.oid=t.typnamespace
    where n.nspname='public' and t.typname='gai_severity' and e.enumlabel=p_severity
  ) then raise exception 'GAI_INVALID_SEVERITY_FILTER' using errcode='check_violation'; end if;

  with visible as (
    select i.*
    from public.gai_incidents i
    where (p_before is null or i.updated_at < p_before)
      and (p_state is null or i.state::text=p_state)
      and (p_severity is null or i.severity::text=p_severity)
      and public.internal_gai_profile_can_view_incident(p_active_profile_id,i.id)
    order by i.updated_at desc, i.id desc
    limit v_limit + 1
  ), items as (
    select * from visible order by updated_at desc,id desc limit v_limit
  )
  select jsonb_build_object(
    'items', coalesce(jsonb_agg(jsonb_build_object(
      'incident_id',x.id,
      'public_id',x.public_id,
      'incident_type',x.incident_type,
      'severity',x.severity,
      'state',x.state,
      'operational',x.operational,
      'scope_type',x.scope_type,
      'scope_target_id',x.scope_target_id,
      'title',x.title,
      'summary',x.summary,
      'assigned_profile_id',x.assigned_profile_id,
      'occurred_at',x.occurred_at,
      'expires_at',x.expires_at,
      'updated_at',x.updated_at,
      'version',x.version
    ) order by x.updated_at desc,x.id desc),'[]'::jsonb),
    'has_more', (select count(*) > v_limit from visible),
    'next_before', (select min(updated_at) from items)
  ) into v_result
  from items x;

  return coalesce(v_result,jsonb_build_object('items','[]'::jsonb,'has_more',false,'next_before',null));
end;
$$;

revoke all on function public.gai_list_my_incidents(uuid,text,text,integer,timestamptz) from public, anon;
grant execute on function public.gai_list_my_incidents(uuid,text,text,integer,timestamptz) to authenticated;

create or replace function public.gai_get_incident_detail(
  p_active_profile_id uuid,
  p_incident_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_person_id uuid;
  v_result jsonb;
begin
  select pe.id into v_person_id
  from public.persons pe
  join public.profiles pr on pr.person_id=pe.id
  where pe.auth_user_id=auth.uid() and pr.id=p_active_profile_id;
  if v_person_id is null then raise exception 'GAI_SECURITY_VIOLATION' using errcode='invalid_authorization_specification'; end if;

  if not public.internal_gai_profile_can_view_incident(p_active_profile_id,p_incident_id) then
    raise exception 'GAI_INCIDENT_NOT_VISIBLE' using errcode='insufficient_privilege';
  end if;

  select jsonb_build_object(
    'incident', jsonb_build_object(
      'incident_id',i.id,'public_id',i.public_id,'incident_type',i.incident_type,
      'severity',i.severity,'state',i.state,'operational',i.operational,
      'scope_type',i.scope_type,'scope_target_id',i.scope_target_id,
      'title',i.title,'summary',i.summary,'assigned_profile_id',i.assigned_profile_id,
      'occurred_at',i.occurred_at,'expires_at',i.expires_at,'resolved_at',i.resolved_at,
      'closed_at',i.closed_at,'resolution_reason',i.resolution_reason,'closure_reason',i.closure_reason,
      'version',i.version,'created_at',i.created_at,'updated_at',i.updated_at
    ),
    'events', coalesce((select jsonb_agg(jsonb_build_object(
      'event_id',e.id,'event_type',e.event_type,'from_state',e.from_state,'to_state',e.to_state,
      'actor_profile_public_id',p.public_id,'actor_profile_type',p.profile_type,
      'reason',e.reason,'created_at',e.created_at
    ) order by e.created_at,e.id)
      from public.gai_incident_events e
      left join public.profiles p on p.id=e.actor_profile_id
      where e.incident_id=i.id),'[]'::jsonb),
    'entity_links', coalesce((select jsonb_agg(jsonb_build_object(
      'entity_type',l.entity_type,'entity_id',l.entity_id,'entity_ref',l.entity_ref,'created_at',l.created_at
    ) order by l.created_at,l.id)
      from public.gai_incident_entity_links l where l.incident_id=i.id),'[]'::jsonb),
    'evidence', coalesce((select jsonb_agg(jsonb_build_object(
      'evidence_id',ev.id,'public_id',ev.public_id,'evidence_type',ev.evidence_type,
      'mime_type',ev.mime_type,'captured_at',ev.captured_at,'status',ev.status
    ) order by ev.captured_at,ev.id)
      from public.gai_incident_evidence_links gl
      join public.evidence ev on ev.id=gl.evidence_id
      where gl.incident_id=i.id),'[]'::jsonb)
  ) into v_result
  from public.gai_incidents i where i.id=p_incident_id;

  if v_result is null then raise exception 'GAI_INCIDENT_NOT_FOUND' using errcode='no_data_found'; end if;
  return v_result;
end;
$$;

revoke all on function public.gai_get_incident_detail(uuid,uuid) from public, anon;
grant execute on function public.gai_get_incident_detail(uuid,uuid) to authenticated;

create or replace function public.gai_list_my_notifications(
  p_active_profile_id uuid,
  p_unread_only boolean default false,
  p_limit integer default 30,
  p_before timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_person_id uuid;
  v_limit int := least(greatest(coalesce(p_limit,30),1),100);
  v_result jsonb;
begin
  select pe.id into v_person_id
  from public.persons pe join public.profiles pr on pr.person_id=pe.id
  where pe.auth_user_id=auth.uid() and pr.id=p_active_profile_id;
  if v_person_id is null then raise exception 'GAI_SECURITY_VIOLATION' using errcode='invalid_authorization_specification'; end if;

  with visible as (
    select o.*, s.read_at, i.public_id as incident_public_id, i.title, i.severity, i.state, e.event_type
    from public.gai_notification_outbox o
    join public.gai_incidents i on i.id=o.incident_id
    join public.gai_incident_events e on e.id=o.incident_event_id
    left join public.gai_notification_read_states s on s.outbox_id=o.id and s.profile_id=p_active_profile_id
    where o.recipient_profile_id=p_active_profile_id
      and o.channel='IN_APP'
      and o.status <> 'CANCELLED'
      and (p_before is null or o.created_at < p_before)
      and (not coalesce(p_unread_only,false) or s.read_at is null)
    order by o.created_at desc,o.id desc
    limit v_limit+1
  ), items as (
    select * from visible order by created_at desc,id desc limit v_limit
  )
  select jsonb_build_object(
    'items',coalesce(jsonb_agg(jsonb_build_object(
      'notification_id',x.id,'incident_id',x.incident_id,'incident_public_id',x.incident_public_id,
      'event_id',x.incident_event_id,'event_type',x.event_type,'category',x.category,
      'title',x.title,'severity',x.severity,'state',x.state,
      'created_at',x.created_at,'read_at',x.read_at,'is_read',(x.read_at is not null)
    ) order by x.created_at desc,x.id desc),'[]'::jsonb),
    'has_more',(select count(*)>v_limit from visible),
    'next_before',(select min(created_at) from items)
  ) into v_result from items x;

  return coalesce(v_result,jsonb_build_object('items','[]'::jsonb,'has_more',false,'next_before',null));
end;
$$;

revoke all on function public.gai_list_my_notifications(uuid,boolean,integer,timestamptz) from public, anon;
grant execute on function public.gai_list_my_notifications(uuid,boolean,integer,timestamptz) to authenticated;

create or replace function public.gai_mark_notification_read(
  p_active_profile_id uuid,
  p_notification_id uuid,
  p_read boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_person_id uuid;
  v_read_at timestamptz;
begin
  select pe.id into v_person_id
  from public.persons pe join public.profiles pr on pr.person_id=pe.id
  where pe.auth_user_id=auth.uid() and pr.id=p_active_profile_id;
  if v_person_id is null then raise exception 'GAI_SECURITY_VIOLATION' using errcode='invalid_authorization_specification'; end if;

  if not exists (
    select 1 from public.gai_notification_outbox o
    where o.id=p_notification_id and o.recipient_profile_id=p_active_profile_id and o.channel='IN_APP'
  ) then raise exception 'GAI_NOTIFICATION_NOT_VISIBLE' using errcode='insufficient_privilege'; end if;

  if coalesce(p_read,true) then
    insert into public.gai_notification_read_states(outbox_id,profile_id,read_at)
    values(p_notification_id,p_active_profile_id,now())
    on conflict (outbox_id) do update set read_at=excluded.read_at, updated_at=now()
    returning read_at into v_read_at;
  else
    insert into public.gai_notification_read_states(outbox_id,profile_id,read_at)
    values(p_notification_id,p_active_profile_id,null)
    on conflict (outbox_id) do update set read_at=null, updated_at=now()
    returning read_at into v_read_at;
  end if;

  return jsonb_build_object('success',true,'notification_id',p_notification_id,'read_at',v_read_at,'is_read',(v_read_at is not null));
end;
$$;

revoke all on function public.gai_mark_notification_read(uuid,uuid,boolean) from public, anon;
grant execute on function public.gai_mark_notification_read(uuid,uuid,boolean) to authenticated;

create or replace function public.gai_my_unread_notification_count(
  p_active_profile_id uuid
)
returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_person_id uuid;
  v_count integer;
begin
  select pe.id into v_person_id
  from public.persons pe join public.profiles pr on pr.person_id=pe.id
  where pe.auth_user_id=auth.uid() and pr.id=p_active_profile_id;
  if v_person_id is null then raise exception 'GAI_SECURITY_VIOLATION' using errcode='invalid_authorization_specification'; end if;

  select count(*)::int into v_count
  from public.gai_notification_outbox o
  left join public.gai_notification_read_states s on s.outbox_id=o.id and s.profile_id=p_active_profile_id
  where o.recipient_profile_id=p_active_profile_id and o.channel='IN_APP' and o.status<>'CANCELLED' and s.read_at is null;
  return v_count;
end;
$$;

revoke all on function public.gai_my_unread_notification_count(uuid) from public, anon;
grant execute on function public.gai_my_unread_notification_count(uuid) to authenticated;
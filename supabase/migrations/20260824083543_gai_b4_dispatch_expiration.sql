alter table public.gai_notification_outbox
  add column if not exists claimed_at timestamptz,
  add column if not exists claimed_by text,
  add column if not exists claim_token uuid,
  add column if not exists claim_expires_at timestamptz,
  add column if not exists last_attempt_at timestamptz,
  add column if not exists last_error text,
  add column if not exists provider_message_id text;

create unique index if not exists uq_gai_outbox_claim_token
  on public.gai_notification_outbox(claim_token)
  where claim_token is not null;

create index if not exists idx_gai_outbox_claimable
  on public.gai_notification_outbox(status, next_attempt_at, claim_expires_at, created_at);

alter table public.gai_incidents
  add column if not exists expired_at timestamptz;

create index if not exists idx_gai_incidents_expiry_due
  on public.gai_incidents(expires_at)
  where expires_at is not null and state <> 'CLOSED';

create table if not exists public.gai_dispatch_settings (
  singleton_id smallint primary key default 1 check (singleton_id = 1),
  max_attempts integer not null default 5 check (max_attempts between 1 and 20),
  base_backoff_seconds integer not null default 30 check (base_backoff_seconds between 1 and 86400),
  max_backoff_seconds integer not null default 3600 check (max_backoff_seconds between 1 and 604800),
  default_lease_seconds integer not null default 120 check (default_lease_seconds between 15 and 3600),
  updated_at timestamptz not null default now(),
  check (max_backoff_seconds >= base_backoff_seconds)
);

insert into public.gai_dispatch_settings(singleton_id)
values (1)
on conflict (singleton_id) do nothing;

alter table public.gai_dispatch_settings enable row level security;
revoke all on public.gai_dispatch_settings from public, anon, authenticated;
revoke all on public.gai_notification_outbox from public, anon, authenticated;

create or replace function public.gai_claim_notification_batch(
  p_worker_id text,
  p_limit integer default 50,
  p_lease_seconds integer default null
)
returns table (
  outbox_id uuid,
  claim_token uuid,
  incident_id uuid,
  incident_event_id uuid,
  recipient_profile_id uuid,
  channel text,
  category text,
  dedup_key text,
  attempt_count integer,
  claim_expires_at timestamptz,
  payload jsonb
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_max_attempts integer;
  v_default_lease integer;
  v_lease integer;
begin
  if p_worker_id is null or btrim(p_worker_id) = '' then
    raise exception 'GAI_WORKER_ID_REQUIRED' using errcode = 'check_violation';
  end if;

  if p_limit is null or p_limit < 1 or p_limit > 200 then
    raise exception 'GAI_INVALID_BATCH_LIMIT' using errcode = 'check_violation';
  end if;

  select max_attempts, default_lease_seconds
    into v_max_attempts, v_default_lease
  from public.gai_dispatch_settings
  where singleton_id = 1;

  v_lease := coalesce(p_lease_seconds, v_default_lease);
  if v_lease < 15 or v_lease > 3600 then
    raise exception 'GAI_INVALID_LEASE_SECONDS' using errcode = 'check_violation';
  end if;

  update public.gai_notification_outbox o
     set status = 'FAILED',
         last_error = coalesce(o.last_error, 'LEASE_EXPIRED_MAX_ATTEMPTS'),
         claimed_at = null,
         claimed_by = null,
         claim_token = null,
         claim_expires_at = null,
         next_attempt_at = null
   where o.status = 'PROCESSING'
     and o.claim_expires_at is not null
     and o.claim_expires_at <= now()
     and o.attempt_count >= v_max_attempts;

  update public.gai_notification_outbox o
     set status = 'FAILED',
         last_error = coalesce(o.last_error, 'MAX_ATTEMPTS_EXHAUSTED'),
         next_attempt_at = null
   where o.status = 'PENDING'
     and o.attempt_count >= v_max_attempts;

  return query
  with eligible as (
    select o.id
    from public.gai_notification_outbox o
    where (
      (o.status = 'PENDING' and coalesce(o.next_attempt_at, o.created_at) <= now())
      or
      (o.status = 'PROCESSING' and o.claim_expires_at is not null and o.claim_expires_at <= now())
    )
      and o.attempt_count < v_max_attempts
    order by case when o.category = 'OPERATIONAL' then 0 else 1 end,
             coalesce(o.next_attempt_at, o.created_at),
             o.created_at,
             o.id
    for update skip locked
    limit p_limit
  ), claimed as (
    update public.gai_notification_outbox o
       set status = 'PROCESSING',
           attempt_count = o.attempt_count + 1,
           last_attempt_at = now(),
           claimed_at = now(),
           claimed_by = p_worker_id,
           claim_token = gen_random_uuid(),
           claim_expires_at = now() + make_interval(secs => v_lease),
           last_error = null
      from eligible e
     where o.id = e.id
    returning o.*
  )
  select c.id,
         c.claim_token,
         c.incident_id,
         c.incident_event_id,
         c.recipient_profile_id,
         c.channel,
         c.category,
         c.dedup_key,
         c.attempt_count,
         c.claim_expires_at,
         c.payload
  from claimed c
  order by case when c.category = 'OPERATIONAL' then 0 else 1 end,
           c.created_at,
           c.id;
end;
$$;

revoke all on function public.gai_claim_notification_batch(text,integer,integer) from public, anon, authenticated;
grant execute on function public.gai_claim_notification_batch(text,integer,integer) to service_role;

create or replace function public.gai_finish_notification(
  p_claim_token uuid,
  p_success boolean,
  p_provider_message_id text default null,
  p_error text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.gai_notification_outbox%rowtype;
  v_max_attempts integer;
  v_base_backoff integer;
  v_max_backoff integer;
  v_delay integer;
  v_status text;
begin
  if p_claim_token is null or p_success is null then
    raise exception 'GAI_INVALID_FINISH_ARGUMENT' using errcode = 'check_violation';
  end if;

  select * into v_row
  from public.gai_notification_outbox
  where claim_token = p_claim_token
    and status = 'PROCESSING'
  for update;

  if not found then
    raise exception 'GAI_CLAIM_NOT_FOUND' using errcode = 'no_data_found';
  end if;

  select max_attempts, base_backoff_seconds, max_backoff_seconds
    into v_max_attempts, v_base_backoff, v_max_backoff
  from public.gai_dispatch_settings
  where singleton_id = 1;

  if p_success then
    update public.gai_notification_outbox
       set status = 'SENT',
           sent_at = now(),
           provider_message_id = p_provider_message_id,
           last_error = null,
           next_attempt_at = null,
           claimed_at = null,
           claimed_by = null,
           claim_token = null,
           claim_expires_at = null
     where id = v_row.id;
    v_status := 'SENT';
  else
    if v_row.attempt_count >= v_max_attempts then
      update public.gai_notification_outbox
         set status = 'FAILED',
             last_error = coalesce(nullif(p_error,''), 'DELIVERY_FAILED'),
             next_attempt_at = null,
             claimed_at = null,
             claimed_by = null,
             claim_token = null,
             claim_expires_at = null
       where id = v_row.id;
      v_status := 'FAILED';
    else
      v_delay := least(
        v_max_backoff,
        greatest(1, round(v_base_backoff * power(2::numeric, greatest(v_row.attempt_count - 1, 0)))::integer)
      );
      update public.gai_notification_outbox
         set status = 'PENDING',
             last_error = coalesce(nullif(p_error,''), 'DELIVERY_FAILED'),
             next_attempt_at = now() + make_interval(secs => v_delay),
             claimed_at = null,
             claimed_by = null,
             claim_token = null,
             claim_expires_at = null
       where id = v_row.id;
      v_status := 'PENDING';
    end if;
  end if;

  return jsonb_build_object(
    'success', true,
    'outbox_id', v_row.id,
    'status', v_status,
    'attempt_count', v_row.attempt_count
  );
end;
$$;

revoke all on function public.gai_finish_notification(uuid,boolean,text,text) from public, anon, authenticated;
grant execute on function public.gai_finish_notification(uuid,boolean,text,text) to service_role;

create or replace function public.gai_process_expired_incidents(
  p_actor_profile_id uuid,
  p_limit integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_person_id uuid;
  v_inc public.gai_incidents%rowtype;
  v_event_id uuid;
  v_processed integer := 0;
  v_closed integer := 0;
  v_escalated integer := 0;
  v_new_severity public.gai_severity;
begin
  if p_limit is null or p_limit < 1 or p_limit > 500 then
    raise exception 'GAI_INVALID_EXPIRY_LIMIT' using errcode = 'check_violation';
  end if;

  select person_id into v_actor_person_id
  from public.profiles
  where id = p_actor_profile_id;

  if v_actor_person_id is null then
    raise exception 'GAI_EXPIRY_ACTOR_NOT_FOUND' using errcode = 'foreign_key_violation';
  end if;

  for v_inc in
    select i.*
    from public.gai_incidents i
    where i.expires_at is not null
      and i.expires_at <= now()
      and i.expired_at is null
      and i.state <> 'CLOSED'
    order by i.expires_at, i.id
    for update skip locked
    limit p_limit
  loop
    v_processed := v_processed + 1;

    if (not v_inc.operational) or v_inc.state = 'RESOLVED' then
      update public.gai_incidents
         set state = 'CLOSED',
             expired_at = now(),
             closed_at = coalesce(closed_at, now()),
             closure_reason = coalesce(closure_reason, 'AUTO_EXPIRED'),
             version = version + 1,
             updated_at = now()
       where id = v_inc.id;

      insert into public.gai_incident_events(
        incident_id,event_type,from_state,to_state,
        actor_person_id,actor_profile_id,actor_namespace,reason,metadata
      ) values (
        v_inc.id,'CLOSED',v_inc.state,'CLOSED',
        v_actor_person_id,p_actor_profile_id,'SERVICE::EXPIRY_WORKER','AUTO_EXPIRED',
        jsonb_build_object('auto_expired',true,'operational',v_inc.operational,'expires_at',v_inc.expires_at)
      ) returning id into v_event_id;

      perform public.internal_gai_enqueue_event_notifications(v_event_id);
      v_closed := v_closed + 1;
    else
      v_new_severity := case v_inc.severity
        when 'INFO' then 'LOW'
        when 'LOW' then 'MEDIUM'
        when 'MEDIUM' then 'HIGH'
        else 'CRITICAL'
      end;

      update public.gai_incidents
         set expired_at = now(),
             severity = v_new_severity,
             version = version + 1,
             updated_at = now()
       where id = v_inc.id;

      insert into public.gai_incident_events(
        incident_id,event_type,from_state,to_state,
        actor_person_id,actor_profile_id,actor_namespace,reason,metadata
      ) values (
        v_inc.id,'ESCALATED',v_inc.state,v_inc.state,
        v_actor_person_id,p_actor_profile_id,'SERVICE::EXPIRY_WORKER','AUTO_EXPIRED_UNRESOLVED',
        jsonb_build_object(
          'auto_expired',true,
          'operational',true,
          'expires_at',v_inc.expires_at,
          'previous_severity',v_inc.severity,
          'new_severity',v_new_severity
        )
      ) returning id into v_event_id;

      perform public.internal_gai_enqueue_event_notifications(v_event_id);
      v_escalated := v_escalated + 1;
    end if;

    insert into public.audit_logs(
      actor_person_id,actor_profile_id,operation,entity_type,entity_public_id,event_id,result,metadata
    ) values (
      v_actor_person_id,p_actor_profile_id,'GAI_INCIDENT_EXPIRY','GAI_INCIDENT',v_inc.public_id,null,'SUCCESS',
      jsonb_build_object('gai_event_id',v_event_id,'previous_state',v_inc.state,'operational',v_inc.operational,'expires_at',v_inc.expires_at)
    );
  end loop;

  return jsonb_build_object(
    'success', true,
    'processed', v_processed,
    'closed', v_closed,
    'escalated', v_escalated
  );
end;
$$;

revoke all on function public.gai_process_expired_incidents(uuid,integer) from public, anon, authenticated;
grant execute on function public.gai_process_expired_incidents(uuid,integer) to service_role;

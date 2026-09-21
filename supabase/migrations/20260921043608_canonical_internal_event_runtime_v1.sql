
create or replace function public.tc_begin_internal_logistics_event(
  p_idempotency_key text,
  p_event_type text,
  p_actor_profile_id uuid,
  p_movement_id uuid,
  p_occurred_at timestamptz,
  p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_key text := btrim(coalesce(p_idempotency_key,''));
  v_type text := upper(btrim(coalesce(p_event_type,'')));
  v_person_id uuid;
  v_auth_user_id uuid;
  v_event_id text;
  v_hash text;
  v_existing public.event_inbox%rowtype;
  v_inserted integer := 0;
begin
  if v_key='' or length(v_key)>200 or v_type='' or p_occurred_at is null then
    raise exception using errcode='P0001', message='TC_INTERNAL_EVENT_INVALID';
  end if;

  select pr.person_id,per.auth_user_id
    into v_person_id,v_auth_user_id
  from public.profiles pr
  join public.persons per on per.id=pr.person_id
  where pr.id=p_actor_profile_id
    and pr.status='active';

  if v_person_id is null or v_auth_user_id is null then
    raise exception using errcode='P0001', message='TC_INTERNAL_EVENT_ACTOR_INVALID';
  end if;

  if not exists(select 1 from public.movements m where m.id=p_movement_id) then
    raise exception using errcode='P0001', message='TC_MOVEMENT_NOT_FOUND';
  end if;

  v_hash := encode(
    extensions.digest(
      convert_to(
        v_key||'|'||v_type||'|'||p_actor_profile_id::text||'|'||
        p_movement_id::text||'|'||
        to_char(p_occurred_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US')||'Z|'||
        coalesce(p_payload,'{}'::jsonb)::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  select * into v_existing
  from public.event_inbox e
  where e.idempotency_key=v_key
  for update;

  if v_existing.id is not null then
    if v_existing.request_hash<>v_hash
       or v_existing.event_type<>v_type
       or v_existing.profile_id<>p_actor_profile_id
       or v_existing.movement_id<>p_movement_id then
      raise exception using errcode='P0001', message='TC_EVENT_IDEMPOTENCY_REUSED';
    end if;

    return jsonb_build_object(
      'event_id',v_existing.event_id,
      'duplicate',true,
      'processing_status',v_existing.processing_status,
      'disposition',v_existing.disposition
    );
  end if;

  v_event_id := public.tc_generate_public_id('EVT');

  insert into public.event_inbox(
    event_id,idempotency_key,request_hash,event_type,
    auth_user_id,person_id,profile_id,movement_id,
    occurred_at,payload,processing_status,last_attempt_at
  ) values(
    v_event_id,v_key,v_hash,v_type,
    v_auth_user_id,v_person_id,p_actor_profile_id,p_movement_id,
    p_occurred_at,coalesce(p_payload,'{}'::jsonb),'PROCESSING',now()
  )
  on conflict (idempotency_key) do nothing;

  get diagnostics v_inserted=row_count;

  if v_inserted=0 then
    select * into v_existing
    from public.event_inbox e
    where e.idempotency_key=v_key
    for update;

    if v_existing.request_hash<>v_hash then
      raise exception using errcode='P0001', message='TC_EVENT_IDEMPOTENCY_REUSED';
    end if;

    return jsonb_build_object(
      'event_id',v_existing.event_id,
      'duplicate',true,
      'processing_status',v_existing.processing_status,
      'disposition',v_existing.disposition
    );
  end if;

  return jsonb_build_object(
    'event_id',v_event_id,
    'duplicate',false,
    'processing_status','PROCESSING',
    'disposition',null
  );
end;
$$;

create or replace function public.tc_finish_internal_logistics_event(
  p_event_id text,
  p_resulting_state text,
  p_resulting_version bigint,
  p_metadata jsonb default '{}'::jsonb
)
returns void
language plpgsql
set search_path = ''
as $$
begin
  update public.event_inbox
     set processing_status='PROCESSED',
         sync_resolution='APPLIED'::public.tc_sync_resolution_type,
         disposition='APPLIED',
         resulting_state=p_resulting_state,
         resulting_version=p_resulting_version,
         observed_entity_version=p_resulting_version,
         error_code=null,
         processed_at=now(),
         last_attempt_at=now(),
         decision_metadata=coalesce(p_metadata,'{}'::jsonb)
   where event_id=p_event_id;
end;
$$;

revoke all on function public.tc_begin_internal_logistics_event(text,text,uuid,uuid,timestamptz,jsonb)
  from public,anon,authenticated;
revoke all on function public.tc_finish_internal_logistics_event(text,text,bigint,jsonb)
  from public,anon,authenticated;

grant execute on function public.tc_begin_internal_logistics_event(text,text,uuid,uuid,timestamptz,jsonb)
  to service_role;
grant execute on function public.tc_finish_internal_logistics_event(text,text,bigint,jsonb)
  to service_role;

comment on function public.tc_begin_internal_logistics_event(text,text,uuid,uuid,timestamptz,jsonb) is
'Service-runtime idempotent event_inbox entry for canonical logistics operations that are not yet exposed through authenticated process_event.';

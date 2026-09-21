
alter function public.tc_record_canonical_load_scan(uuid,uuid,uuid,text,timestamptz)
  rename to tc_record_canonical_load_scan_once;
alter function public.tc_apply_canonical_departure_release(uuid,uuid[],uuid,text,timestamptz)
  rename to tc_apply_canonical_departure_release_once;
alter function public.tc_apply_canonical_departure_receive(uuid,uuid[],uuid,text,timestamptz)
  rename to tc_apply_canonical_departure_receive_once;
alter function public.tc_record_canonical_arrival_scan(uuid,uuid,uuid,text,timestamptz)
  rename to tc_record_canonical_arrival_scan_once;
alter function public.tc_apply_canonical_arrival_release(uuid,uuid[],uuid,text,timestamptz)
  rename to tc_apply_canonical_arrival_release_once;
alter function public.tc_apply_canonical_arrival_receive(uuid,uuid[],uuid,text,timestamptz)
  rename to tc_apply_canonical_arrival_receive_once;

create or replace function public.tc_internal_event_replay_or_begin(
  p_idempotency_key text,
  p_event_type text,
  p_actor_profile_id uuid,
  p_movement_id uuid,
  p_occurred_at timestamptz,
  p_payload jsonb
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_event jsonb;
begin
  v_event:=public.tc_begin_internal_logistics_event(
    p_idempotency_key,p_event_type,p_actor_profile_id,
    p_movement_id,p_occurred_at,p_payload
  );

  if coalesce((v_event->>'duplicate')::boolean,false) then
    if v_event->>'processing_status'='PROCESSED'
       and v_event->>'disposition'='APPLIED' then
      return v_event||jsonb_build_object('replay',true);
    end if;

    raise exception using errcode='P0001', message='TC_EVENT_STILL_PROCESSING';
  end if;

  return v_event||jsonb_build_object('replay',false);
end;
$$;

create or replace function public.tc_record_canonical_load_scan(
  p_movement_id uuid,
  p_package_id uuid,
  p_actor_profile_id uuid,
  p_idempotency_key text,
  p_occurred_at timestamptz default now()
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_gate jsonb;
  v_state text;
  v_version bigint;
  v_scan uuid;
begin
  v_gate:=public.tc_internal_event_replay_or_begin(
    p_idempotency_key,'CANONICAL_LOAD_SCAN',
    p_actor_profile_id,p_movement_id,p_occurred_at,
    jsonb_build_object('package_id',p_package_id)
  );

  if coalesce((v_gate->>'replay')::boolean,false) then
    select state,version into v_state,v_version
    from public.movements where id=p_movement_id;
    select id into v_scan
    from public.logistics_scan_events
    where idempotency_key=p_idempotency_key;

    return jsonb_build_object(
      'event_id',v_gate->>'event_id',
      'scan_event_id',v_scan,
      'movement_state',v_state,
      'movement_version',v_version,
      'idempotent',true
    );
  end if;

  return public.tc_record_canonical_load_scan_once(
    p_movement_id,p_package_id,p_actor_profile_id,p_idempotency_key,p_occurred_at
  )||jsonb_build_object('idempotent',false);
end;
$$;

create or replace function public.tc_apply_canonical_departure_release(
  p_movement_id uuid,
  p_package_ids uuid[],
  p_actor_profile_id uuid,
  p_idempotency_key text,
  p_occurred_at timestamptz default now()
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_gate jsonb;
  v_state text;
  v_version bigint;
begin
  v_gate:=public.tc_internal_event_replay_or_begin(
    p_idempotency_key,'CANONICAL_DEPARTURE_RELEASE',
    p_actor_profile_id,p_movement_id,p_occurred_at,
    jsonb_build_object('package_ids',to_jsonb(p_package_ids))
  );

  if coalesce((v_gate->>'replay')::boolean,false) then
    select state,version into v_state,v_version
    from public.movements where id=p_movement_id;
    return jsonb_build_object(
      'event_id',v_gate->>'event_id',
      'movement_state',v_state,
      'movement_version',v_version,
      'idempotent',true
    );
  end if;

  return public.tc_apply_canonical_departure_release_once(
    p_movement_id,p_package_ids,p_actor_profile_id,p_idempotency_key,p_occurred_at
  )||jsonb_build_object('idempotent',false);
end;
$$;

create or replace function public.tc_apply_canonical_departure_receive(
  p_movement_id uuid,
  p_package_ids uuid[],
  p_actor_profile_id uuid,
  p_idempotency_key text,
  p_occurred_at timestamptz default now()
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_gate jsonb;
  v_state text;
  v_version bigint;
begin
  v_gate:=public.tc_internal_event_replay_or_begin(
    p_idempotency_key,'CANONICAL_DEPARTURE_RECEIVE',
    p_actor_profile_id,p_movement_id,p_occurred_at,
    jsonb_build_object('package_ids',to_jsonb(p_package_ids))
  );

  if coalesce((v_gate->>'replay')::boolean,false) then
    select state,version into v_state,v_version
    from public.movements where id=p_movement_id;
    return jsonb_build_object(
      'event_id',v_gate->>'event_id',
      'movement_state',v_state,
      'movement_version',v_version,
      'idempotent',true
    );
  end if;

  return public.tc_apply_canonical_departure_receive_once(
    p_movement_id,p_package_ids,p_actor_profile_id,p_idempotency_key,p_occurred_at
  )||jsonb_build_object('idempotent',false);
end;
$$;

create or replace function public.tc_record_canonical_arrival_scan(
  p_movement_id uuid,
  p_package_id uuid,
  p_actor_profile_id uuid,
  p_idempotency_key text,
  p_occurred_at timestamptz default now()
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_expected boolean;
  v_type text;
  v_gate jsonb;
  v_state text;
  v_version bigint;
  v_scan uuid;
begin
  select exists(
    select 1 from public.movement_packages mp
    where mp.movement_id=p_movement_id
      and mp.package_id=p_package_id
  ) into v_expected;

  v_type:=case when v_expected
    then 'CANONICAL_ARRIVAL_SCAN'
    else 'CANONICAL_ARRIVAL_UNEXPECTED_SCAN'
  end;

  v_gate:=public.tc_internal_event_replay_or_begin(
    p_idempotency_key,v_type,
    p_actor_profile_id,p_movement_id,p_occurred_at,
    jsonb_build_object('package_id',p_package_id,'expected',v_expected)
  );

  if coalesce((v_gate->>'replay')::boolean,false) then
    select state,version into v_state,v_version
    from public.movements where id=p_movement_id;
    select id into v_scan
    from public.logistics_scan_events
    where idempotency_key=p_idempotency_key;

    return jsonb_build_object(
      'event_id',v_gate->>'event_id',
      'scan_event_id',v_scan,
      'expected',v_expected,
      'movement_state',v_state,
      'movement_version',v_version,
      'idempotent',true
    );
  end if;

  return public.tc_record_canonical_arrival_scan_once(
    p_movement_id,p_package_id,p_actor_profile_id,p_idempotency_key,p_occurred_at
  )||jsonb_build_object('idempotent',false);
end;
$$;

create or replace function public.tc_apply_canonical_arrival_release(
  p_movement_id uuid,
  p_package_ids uuid[],
  p_actor_profile_id uuid,
  p_idempotency_key text,
  p_occurred_at timestamptz default now()
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_gate jsonb;
  v_state text;
  v_version bigint;
begin
  v_gate:=public.tc_internal_event_replay_or_begin(
    p_idempotency_key,'CANONICAL_ARRIVAL_RELEASE',
    p_actor_profile_id,p_movement_id,p_occurred_at,
    jsonb_build_object('package_ids',to_jsonb(p_package_ids))
  );

  if coalesce((v_gate->>'replay')::boolean,false) then
    select state,version into v_state,v_version
    from public.movements where id=p_movement_id;
    return jsonb_build_object(
      'event_id',v_gate->>'event_id',
      'movement_state',v_state,
      'movement_version',v_version,
      'idempotent',true
    );
  end if;

  return public.tc_apply_canonical_arrival_release_once(
    p_movement_id,p_package_ids,p_actor_profile_id,p_idempotency_key,p_occurred_at
  )||jsonb_build_object('idempotent',false);
end;
$$;

create or replace function public.tc_apply_canonical_arrival_receive(
  p_movement_id uuid,
  p_package_ids uuid[],
  p_actor_profile_id uuid,
  p_idempotency_key text,
  p_occurred_at timestamptz default now()
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_gate jsonb;
  v_state text;
  v_version bigint;
begin
  v_gate:=public.tc_internal_event_replay_or_begin(
    p_idempotency_key,'CANONICAL_ARRIVAL_RECEIVE',
    p_actor_profile_id,p_movement_id,p_occurred_at,
    jsonb_build_object('package_ids',to_jsonb(p_package_ids))
  );

  if coalesce((v_gate->>'replay')::boolean,false) then
    select state,version into v_state,v_version
    from public.movements where id=p_movement_id;
    return jsonb_build_object(
      'event_id',v_gate->>'event_id',
      'movement_state',v_state,
      'movement_version',v_version,
      'idempotent',true
    );
  end if;

  return public.tc_apply_canonical_arrival_receive_once(
    p_movement_id,p_package_ids,p_actor_profile_id,p_idempotency_key,p_occurred_at
  )||jsonb_build_object('idempotent',false);
end;
$$;

revoke all on function public.tc_internal_event_replay_or_begin(text,text,uuid,uuid,timestamptz,jsonb)
  from public,anon,authenticated;

revoke all on function public.tc_record_canonical_load_scan(uuid,uuid,uuid,text,timestamptz)
  from public,anon,authenticated;
revoke all on function public.tc_apply_canonical_departure_release(uuid,uuid[],uuid,text,timestamptz)
  from public,anon,authenticated;
revoke all on function public.tc_apply_canonical_departure_receive(uuid,uuid[],uuid,text,timestamptz)
  from public,anon,authenticated;
revoke all on function public.tc_record_canonical_arrival_scan(uuid,uuid,uuid,text,timestamptz)
  from public,anon,authenticated;
revoke all on function public.tc_apply_canonical_arrival_release(uuid,uuid[],uuid,text,timestamptz)
  from public,anon,authenticated;
revoke all on function public.tc_apply_canonical_arrival_receive(uuid,uuid[],uuid,text,timestamptz)
  from public,anon,authenticated;

revoke all on function public.tc_record_canonical_load_scan_once(uuid,uuid,uuid,text,timestamptz)
  from public,anon,authenticated;
revoke all on function public.tc_apply_canonical_departure_release_once(uuid,uuid[],uuid,text,timestamptz)
  from public,anon,authenticated;
revoke all on function public.tc_apply_canonical_departure_receive_once(uuid,uuid[],uuid,text,timestamptz)
  from public,anon,authenticated;
revoke all on function public.tc_record_canonical_arrival_scan_once(uuid,uuid,uuid,text,timestamptz)
  from public,anon,authenticated;
revoke all on function public.tc_apply_canonical_arrival_release_once(uuid,uuid[],uuid,text,timestamptz)
  from public,anon,authenticated;
revoke all on function public.tc_apply_canonical_arrival_receive_once(uuid,uuid[],uuid,text,timestamptz)
  from public,anon,authenticated;

grant execute on function public.tc_internal_event_replay_or_begin(text,text,uuid,uuid,timestamptz,jsonb)
  to service_role;

grant execute on function public.tc_record_canonical_load_scan(uuid,uuid,uuid,text,timestamptz)
  to service_role;
grant execute on function public.tc_apply_canonical_departure_release(uuid,uuid[],uuid,text,timestamptz)
  to service_role;
grant execute on function public.tc_apply_canonical_departure_receive(uuid,uuid[],uuid,text,timestamptz)
  to service_role;
grant execute on function public.tc_record_canonical_arrival_scan(uuid,uuid,uuid,text,timestamptz)
  to service_role;
grant execute on function public.tc_apply_canonical_arrival_release(uuid,uuid[],uuid,text,timestamptz)
  to service_role;
grant execute on function public.tc_apply_canonical_arrival_receive(uuid,uuid[],uuid,text,timestamptz)
  to service_role;

grant execute on function public.tc_record_canonical_load_scan_once(uuid,uuid,uuid,text,timestamptz)
  to service_role;
grant execute on function public.tc_apply_canonical_departure_release_once(uuid,uuid[],uuid,text,timestamptz)
  to service_role;
grant execute on function public.tc_apply_canonical_departure_receive_once(uuid,uuid[],uuid,text,timestamptz)
  to service_role;
grant execute on function public.tc_record_canonical_arrival_scan_once(uuid,uuid,uuid,text,timestamptz)
  to service_role;
grant execute on function public.tc_apply_canonical_arrival_release_once(uuid,uuid[],uuid,text,timestamptz)
  to service_role;
grant execute on function public.tc_apply_canonical_arrival_receive_once(uuid,uuid[],uuid,text,timestamptz)
  to service_role;

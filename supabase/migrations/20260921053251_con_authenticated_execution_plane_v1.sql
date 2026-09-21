
create or replace function public.tc_con_execute_movement_action(
  p_con_public_id text,
  p_movement_public_id text,
  p_action text,
  p_package_public_ids text[] default null,
  p_idempotency_key text default null,
  p_occurred_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_con uuid;
  v_movement public.movements%rowtype;
  v_trip public.logistics_trips%rowtype;
  v_action text:=upper(btrim(coalesce(p_action,'')));
  v_package_ids uuid[];
  v_requested integer;
  v_resolved integer;
  v_run uuid;
  v_run_row public.logistics_movement_reconciliation_runs%rowtype;
begin
  v_con:=public.tc_con_resolve_owned_profile(p_con_public_id);

  select m.* into v_movement
  from public.movements m
  where m.public_id=upper(btrim(coalesce(p_movement_public_id,'')))
  for update;

  if v_movement.id is null or v_movement.logistics_trip_id is null then
    raise exception using errcode='P0001', message='TC_CON_MOVEMENT_NOT_FOUND';
  end if;

  select * into v_trip
  from public.logistics_trips t
  where t.id=v_movement.logistics_trip_id;

  if v_trip.driver_profile_id is distinct from v_con then
    raise exception using errcode='P0001', message='TC_CON_MOVEMENT_FORBIDDEN';
  end if;

  if v_action in ('DEPARTURE_RECEIVE','ARRIVAL_SCAN','ARRIVAL_RELEASE') then
    if nullif(btrim(coalesce(p_idempotency_key,'')),'') is null then
      raise exception using errcode='P0001', message='TC_CON_IDEMPOTENCY_KEY_REQUIRED';
    end if;
  end if;

  if v_action in ('DEPARTURE_RECEIVE','ARRIVAL_SCAN','ARRIVAL_RELEASE') then
    if p_package_public_ids is null or cardinality(p_package_public_ids)<1 then
      raise exception using errcode='P0001', message='TC_EMPTY_EVENT_PACKAGE_SET';
    end if;

    select count(distinct upper(btrim(x)))
      into v_requested
    from unnest(p_package_public_ids) x
    where nullif(btrim(x),'') is not null;

    select array_agg(p.id order by p.public_id),count(*)
      into v_package_ids,v_resolved
    from public.packages p
    where p.public_id in (
      select distinct upper(btrim(x))
      from unnest(p_package_public_ids) x
      where nullif(btrim(x),'') is not null
    )
      and exists(
        select 1
        from public.movement_packages mp
        where mp.movement_id=v_movement.id
          and mp.package_id=p.id
      );

    if v_requested<1 or v_resolved<>v_requested then
      raise exception using errcode='P0001', message='TC_PACKAGE_NOT_IN_MOVEMENT';
    end if;
  end if;

  if v_action='DEPARTURE_RECEIVE' then
    return public.tc_apply_canonical_departure_receive(
      v_movement.id,v_package_ids,v_con,
      p_idempotency_key,coalesce(p_occurred_at,now())
    );

  elsif v_action='ARRIVAL_SCAN' then
    if v_requested<>1 then
      raise exception using errcode='P0001', message='TC_CON_ARRIVAL_SCAN_ONE_PACKAGE_REQUIRED';
    end if;

    return public.tc_record_canonical_arrival_scan(
      v_movement.id,v_package_ids[1],v_con,
      p_idempotency_key,coalesce(p_occurred_at,now())
    );

  elsif v_action='ARRIVAL_RECONCILE' then
    v_run:=public.tc_reconcile_canonical_movement_arrival(
      v_movement.id,v_con
    );

    select * into v_run_row
    from public.logistics_movement_reconciliation_runs
    where id=v_run;

    return jsonb_build_object(
      'reconciliation_run_public_id',v_run_row.public_id,
      'status',v_run_row.status,
      'expected_count',v_run_row.expected_count,
      'observed_expected_count',v_run_row.observed_expected_count,
      'missing_count',v_run_row.missing_count,
      'unexpected_count',v_run_row.unexpected_count
    );

  elsif v_action='ARRIVAL_RELEASE' then
    return public.tc_apply_canonical_arrival_release(
      v_movement.id,v_package_ids,v_con,
      p_idempotency_key,coalesce(p_occurred_at,now())
    );

  else
    raise exception using errcode='P0001', message='TC_CON_MOVEMENT_ACTION_INVALID';
  end if;
end;
$$;

revoke all on function public.tc_con_execute_movement_action(
  text,text,text,text[],text,timestamptz
) from public,anon;

grant execute on function public.tc_con_execute_movement_action(
  text,text,text,text[],text,timestamptz
) to authenticated,service_role;

comment on function public.tc_con_execute_movement_action(
  text,text,text,text[],text,timestamptz
) is
'Authenticated CON execution API. Allows only DEPARTURE_RECEIVE, ARRIVAL_SCAN, ARRIVAL_RECONCILE and ARRIVAL_RELEASE on MOVs belonging to the caller CON. No recipient PII is returned.';

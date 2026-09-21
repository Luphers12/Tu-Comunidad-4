
drop function if exists public.tc_con_save_trip(
  text,text,text,timestamptz,jsonb,jsonb,text,timestamptz,timestamptz,jsonb,jsonb,boolean
);

drop function if exists public.tc_con_set_trip_state(text,text,text);

drop function if exists public.tc_con_workspace(text,integer);

drop function if exists public.tc_con_execute_movement_action(
  text,text,text,text[],text,timestamptz
);

drop function if exists public.tc_con_resolve_owned_profile(text);

create or replace function public.tc_con_respond_opportunity(
  p_con_public_id text,
  p_match_public_id text,
  p_action text,
  p_reason_code text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_con uuid;
  v_match public.logistics_matches%rowtype;
  v_trip_public_id text;
  v_result jsonb;
begin
  v_con:=public.tc_require_my_con_profile(p_con_public_id);

  select m.* into v_match
  from public.logistics_matches m
  join public.logistics_trips t on t.id=m.trip_id
  where m.public_id=upper(btrim(coalesce(p_match_public_id,'')))
    and t.driver_profile_id=v_con;

  if v_match.id is null then
    raise exception using errcode='P0001', message='TC_CON_OPPORTUNITY_NOT_FOUND';
  end if;

  select t.public_id into v_trip_public_id
  from public.logistics_trips t
  where t.id=v_match.trip_id;

  v_result:=public.tc_respond_logistics_match(
    v_match.id,v_con,p_action,p_reason_code
  );

  return (v_result-'match_id')||jsonb_build_object(
    'match_public_id',v_match.public_id,
    'trip_public_id',v_trip_public_id
  );
end;
$$;

revoke all on function public.tc_con_respond_opportunity(text,text,text,text)
  from public,anon,authenticated,service_role;
grant execute on function public.tc_con_respond_opportunity(text,text,text,text)
  to authenticated;

create or replace function public.tc_con_reconcile_arrival(
  p_con_public_id text,
  p_movement_public_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_con uuid;
  v_movement uuid;
  v_run uuid;
  v_row public.logistics_movement_reconciliation_runs%rowtype;
begin
  v_con:=public.tc_require_my_con_profile(p_con_public_id);

  select mv.id into v_movement
  from public.movements mv
  join public.logistics_trips t on t.id=mv.logistics_trip_id
  where mv.public_id=upper(btrim(coalesce(p_movement_public_id,'')))
    and t.driver_profile_id=v_con;

  if v_movement is null then
    raise exception using errcode='P0001', message='TC_CON_MOVEMENT_NOT_FOUND';
  end if;

  v_run:=public.tc_reconcile_canonical_movement_arrival(
    v_movement,v_con
  );

  select * into v_row
  from public.logistics_movement_reconciliation_runs r
  where r.id=v_run;

  return jsonb_build_object(
    'reconciliation_run_public_id',v_row.public_id,
    'status',v_row.status,
    'run_no',v_row.run_no,
    'expected_count',v_row.expected_count,
    'observed_expected_count',v_row.observed_expected_count,
    'missing_count',v_row.missing_count,
    'unexpected_count',v_row.unexpected_count
  );
end;
$$;

revoke all on function public.tc_con_reconcile_arrival(text,text)
  from public,anon,authenticated,service_role;
grant execute on function public.tc_con_reconcile_arrival(text,text)
  to authenticated;

comment on function public.tc_con_reconcile_arrival(text,text) is
'Authenticated CON arrival reconciliation wrapper. Subprofile ownership is enforced; response contains only reconciliation counts/status and no recipient PII.';

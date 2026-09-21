
create or replace function public.tc_con_my_execution_board(
  p_con_public_id text,
  p_trip_public_id text default null,
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_con uuid;
  v_trip_filter text:=nullif(upper(btrim(coalesce(p_trip_public_id,''))),'');
  v_result jsonb;
begin
  v_con:=public.tc_require_my_con_profile(p_con_public_id);

  if p_limit<1 or p_limit>250 then
    raise exception using errcode='P0001', message='TC_LIMIT_INVALID';
  end if;

  select coalesce(jsonb_agg(x.obj order by x.expected_from,x.movement_public_id),'[]'::jsonb)
  into v_result
  from (
    select
      mv.expected_from_at as expected_from,
      mv.public_id as movement_public_id,
      jsonb_build_object(
        'movement_public_id',mv.public_id,
        'movement_state',mv.state,
        'trip_public_id',t.public_id,
        'match_public_id',mat.public_id,
        'hop_sequence',h.hop_sequence,
        'board_stop_sequence',mv.board_stop_sequence,
        'alight_stop_sequence',mv.alight_stop_sequence,
        'expected_from_at',mv.expected_from_at,
        'expected_to_at',mv.expected_to_at,
        'departed_at',mv.departed_at,
        'arrived_at',mv.arrived_at,
        'completed_at',mv.completed_at,
        'origin',jsonb_build_object(
          'node_public_id',oo.public_id,
          'name',oo.name,
          'community_name',oc.name
        ),
        'destination',jsonb_build_object(
          'node_public_id',do_.public_id,
          'name',do_.name,
          'community_name',dc.name
        ),
        'package_count',(
          select count(*) from public.movement_packages mp where mp.movement_id=mv.id
        ),
        'packages',coalesce((
          select jsonb_agg(jsonb_build_object(
            'package_public_id',p.public_id,
            'state',p.state,
            'weight_kg',p.weight_kg,
            'volume_m3',p.volume_m3,
            'departure_phase_status',(
              select ph.status from public.logistics_movement_custody_phases ph
              where ph.movement_id=mv.id and ph.package_id=p.id and ph.phase='DEPARTURE'
            ),
            'arrival_phase_status',(
              select ph.status from public.logistics_movement_custody_phases ph
              where ph.movement_id=mv.id and ph.package_id=p.id and ph.phase='ARRIVAL'
            )
          ) order by p.public_id)
          from public.movement_packages mp
          join public.packages p on p.id=mp.package_id
          where mp.movement_id=mv.id
        ),'[]'::jsonb),
        'latest_reconciliation',(
          select jsonb_build_object(
            'status',rr.status,
            'missing_count',rr.missing_count,
            'unexpected_count',rr.unexpected_count,
            'run_no',rr.run_no
          )
          from public.logistics_movement_reconciliation_runs rr
          where rr.movement_id=mv.id
          order by rr.run_no desc
          limit 1
        )
      ) as obj
    from public.logistics_hop_executions he
    join public.logistics_execution_plans ep on ep.id=he.execution_plan_id
    join public.logistics_routing_hops h on h.id=he.routing_hop_id
    join public.logistics_matches mat on mat.id=he.match_id
    join public.movements mv on mv.id=he.movement_id
    join public.logistics_trips t on t.id=mv.logistics_trip_id
    join public.operational_locations oo on oo.id=mv.origin_operational_location_id
    join public.communities oc on oc.id=oo.community_id
    join public.operational_locations do_ on do_.id=mv.destination_operational_location_id
    join public.communities dc on dc.id=do_.community_id
    where t.driver_profile_id=v_con
      and (v_trip_filter is null or t.public_id=v_trip_filter)
      and not exists(
        select 1 from public.logistics_hop_executions nx
        where nx.supersedes_hop_execution_id=he.id
      )
    order by mv.expected_from_at,mv.public_id
    limit p_limit
  ) x;

  return v_result;
end;
$$;

create or replace function public.tc_con_receive_departure(
  p_con_public_id text,
  p_movement_public_id text,
  p_package_public_ids text[],
  p_idempotency_key text,
  p_occurred_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_con uuid;
  v_movement uuid;
  v_public_ids text[];
  v_package_ids uuid[];
  v_requested integer;
  v_resolved integer;
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

  select array_agg(x order by x),count(*)
    into v_public_ids,v_requested
  from (
    select distinct upper(btrim(v)) as x
    from unnest(p_package_public_ids) v
    where nullif(btrim(v),'') is not null
  ) q;

  if v_requested<1 then
    raise exception using errcode='P0001', message='TC_EMPTY_EVENT_PACKAGE_SET';
  end if;

  select array_agg(p.id order by p.public_id),count(*)
    into v_package_ids,v_resolved
  from public.movement_packages mp
  join public.packages p on p.id=mp.package_id
  where mp.movement_id=v_movement
    and p.public_id=any(v_public_ids);

  if v_resolved<>v_requested then
    raise exception using errcode='P0001', message='TC_PACKAGE_NOT_IN_MOVEMENT';
  end if;

  return public.tc_apply_canonical_departure_receive(
    v_movement,v_package_ids,v_con,p_idempotency_key,p_occurred_at
  );
end;
$$;

create or replace function public.tc_con_scan_arrival(
  p_con_public_id text,
  p_movement_public_id text,
  p_package_public_id text,
  p_idempotency_key text,
  p_occurred_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_con uuid;
  v_movement uuid;
  v_package uuid;
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

  select p.id into v_package
  from public.packages p
  where p.public_id=upper(btrim(coalesce(p_package_public_id,'')));

  if v_package is null then
    raise exception using errcode='P0001', message='TC_PACKAGE_NOT_FOUND';
  end if;

  return public.tc_record_canonical_arrival_scan(
    v_movement,v_package,v_con,p_idempotency_key,p_occurred_at
  );
end;
$$;

create or replace function public.tc_con_release_arrival(
  p_con_public_id text,
  p_movement_public_id text,
  p_package_public_ids text[],
  p_idempotency_key text,
  p_occurred_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_con uuid;
  v_movement uuid;
  v_public_ids text[];
  v_package_ids uuid[];
  v_requested integer;
  v_resolved integer;
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

  select array_agg(x order by x),count(*)
    into v_public_ids,v_requested
  from (
    select distinct upper(btrim(v)) as x
    from unnest(p_package_public_ids) v
    where nullif(btrim(v),'') is not null
  ) q;

  if v_requested<1 then
    raise exception using errcode='P0001', message='TC_EMPTY_EVENT_PACKAGE_SET';
  end if;

  select array_agg(p.id order by p.public_id),count(*)
    into v_package_ids,v_resolved
  from public.movement_packages mp
  join public.packages p on p.id=mp.package_id
  where mp.movement_id=v_movement
    and p.public_id=any(v_public_ids);

  if v_resolved<>v_requested then
    raise exception using errcode='P0001', message='TC_PACKAGE_NOT_IN_MOVEMENT';
  end if;

  return public.tc_apply_canonical_arrival_release(
    v_movement,v_package_ids,v_con,p_idempotency_key,p_occurred_at
  );
end;
$$;

revoke all on function public.tc_con_my_execution_board(text,text,integer)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_con_receive_departure(text,text,text[],text,timestamptz)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_con_scan_arrival(text,text,text,text,timestamptz)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_con_release_arrival(text,text,text[],text,timestamptz)
  from public,anon,authenticated,service_role;

grant execute on function public.tc_con_my_execution_board(text,text,integer)
  to authenticated;
grant execute on function public.tc_con_receive_departure(text,text,text[],text,timestamptz)
  to authenticated;
grant execute on function public.tc_con_scan_arrival(text,text,text,text,timestamptz)
  to authenticated;
grant execute on function public.tc_con_release_arrival(text,text,text[],text,timestamptz)
  to authenticated;

comment on function public.tc_con_my_execution_board(text,text,integer) is
'Authenticated CON execution board. After ACCEPT it may expose PKG public IDs and operational NODE/time data required to move cargo, but never recipient name, private address or phone.';

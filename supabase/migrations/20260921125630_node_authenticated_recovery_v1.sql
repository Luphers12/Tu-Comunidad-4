
create or replace function public.tc_node_my_recovery_cases(
  p_node_public_id text,
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_node uuid;
  v_limit integer;
  v_result jsonb;
begin
  v_node:=public.tc_require_my_operational_node(
    p_node_public_id,'RECEIVE_CARGO'
  );
  v_limit:=least(greatest(coalesce(p_limit,100),1),250);

  select coalesce(jsonb_agg(x.obj order by x.created_at desc,x.case_public_id),'[]'::jsonb)
  into v_result
  from (
    select
      rc.created_at,
      rc.public_id as case_public_id,
      jsonb_build_object(
        'recovery_case_public_id',rc.public_id,
        'case_type',rc.case_type,
        'movement_public_id',mv.public_id,
        'manifest_public_id',m.public_id,
        'latest_event',(
          select jsonb_build_object(
            'event_public_id',e.public_id,
            'event_type',e.event_type,
            'reason_code',e.reason_code,
            'occurred_at',e.occurred_at
          )
          from public.logistics_recovery_events e
          where e.recovery_case_id=rc.id
          order by e.event_seq desc
          limit 1
        ),
        'latest_reconciliation',(
          select jsonb_build_object(
            'run_public_id',r.public_id,
            'status',r.status,
            'expected_count',r.expected_count,
            'observed_expected_count',r.observed_expected_count,
            'missing_count',r.missing_count,
            'unexpected_count',r.unexpected_count
          )
          from public.logistics_movement_reconciliation_runs r
          where r.movement_id=rc.movement_id
            and (rc.manifest_id is null or r.manifest_id=rc.manifest_id)
          order by r.run_no desc,r.id desc
          limit 1
        ),
        'unresolved_unexpected_packages',coalesce((
          select jsonb_agg(jsonb_build_object(
            'scan_event_public_id',s.public_id,
            'package_public_id',p.public_id,
            'occurred_at',s.occurred_at
          ) order by s.occurred_at,s.id)
          from public.logistics_scan_events s
          join public.packages p on p.id=s.package_id
          where s.movement_id=rc.movement_id
            and s.scan_type='EXCEPTION'
            and coalesce((s.metadata->>'expected_in_movement')::boolean,true)=false
            and not exists(
              select 1
              from public.logistics_reconciliation_resolutions rr
              where rr.scan_event_id=s.id
            )
        ),'[]'::jsonb)
      ) as obj
    from public.logistics_recovery_cases rc
    join public.movements mv on mv.id=rc.movement_id
    left join public.logistics_manifests m on m.id=rc.manifest_id
    where mv.destination_operational_location_id=v_node
      and rc.case_type='ARRIVAL_MISMATCH'
    order by rc.created_at desc,rc.id desc
    limit v_limit
  ) x;

  return v_result;
end;
$$;

create or replace function public.tc_node_resolve_unexpected_arrival(
  p_node_public_id text,
  p_scan_event_public_id text,
  p_resolution_type text,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_node uuid;
  v_actor uuid;
  v_scan public.logistics_scan_events%rowtype;
  v_resolution uuid;
  v_resolution_row public.logistics_reconciliation_resolutions%rowtype;
  v_case_public text;
begin
  v_node:=public.tc_require_my_operational_node(
    p_node_public_id,'RECEIVE_CARGO'
  );
  v_actor:=public.tc_active_profile_id();

  select * into v_scan
  from public.logistics_scan_events s
  where s.public_id=upper(btrim(coalesce(p_scan_event_public_id,'')))
    and s.operational_location_id=v_node
    and s.scan_type='EXCEPTION'
    and coalesce((s.metadata->>'expected_in_movement')::boolean,true)=false
    and s.movement_id is not null;

  if v_scan.id is null then
    raise exception using errcode='P0001', message='TC_NODE_UNEXPECTED_SCAN_NOT_FOUND';
  end if;

  if not exists(
    select 1
    from public.movements mv
    where mv.id=v_scan.movement_id
      and mv.destination_operational_location_id=v_node
  ) then
    raise exception using errcode='P0001', message='TC_NODE_UNEXPECTED_SCAN_FORBIDDEN';
  end if;

  v_resolution:=public.tc_resolve_unexpected_arrival_scan(
    v_scan.id,
    v_actor,
    p_resolution_type,
    p_note
  );

  select * into v_resolution_row
  from public.logistics_reconciliation_resolutions rr
  where rr.id=v_resolution;

  select rc.public_id into v_case_public
  from public.logistics_recovery_cases rc
  where rc.id=v_resolution_row.recovery_case_id;

  return jsonb_build_object(
    'resolution_public_id',v_resolution_row.public_id,
    'recovery_case_public_id',v_case_public,
    'scan_event_public_id',v_scan.public_id,
    'resolution_type',v_resolution_row.resolution_type
  );
end;
$$;

revoke all on function public.tc_node_my_recovery_cases(text,integer)
  from public,anon,authenticated,service_role;
revoke all on function public.tc_node_resolve_unexpected_arrival(text,text,text,text)
  from public,anon,authenticated,service_role;

grant execute on function public.tc_node_my_recovery_cases(text,integer)
  to authenticated;
grant execute on function public.tc_node_resolve_unexpected_arrival(text,text,text,text)
  to authenticated;

comment on function public.tc_node_my_recovery_cases(text,integer) is
'Active exact NODE-owner recovery view for ARRIVAL_MISMATCH cases. PII-free; exposes PKG IDs and unresolved unexpected scans only.';

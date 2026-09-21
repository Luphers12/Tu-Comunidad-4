
create or replace function public.tc_con_publish_trip(
  p_con_public_id text,
  p_trip_public_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_con uuid;
  v_trip public.logistics_trips%rowtype;
begin
  v_con:=public.tc_require_my_con_profile(p_con_public_id);

  select * into v_trip
  from public.logistics_trips t
  where t.public_id=upper(btrim(coalesce(p_trip_public_id,'')))
    and t.driver_profile_id=v_con
  for update;

  if v_trip.id is null then
    raise exception using errcode='P0001', message='TC_CON_TRIP_NOT_FOUND';
  end if;

  if v_trip.state='PUBLISHED' then
    return jsonb_build_object(
      'trip_public_id',v_trip.public_id,
      'state','PUBLISHED',
      'version',v_trip.version,
      'idempotent',true
    );
  end if;

  if v_trip.state<>'DRAFT' then
    raise exception using errcode='P0001', message='TC_CON_TRIP_NOT_PUBLISHABLE';
  end if;

  update public.logistics_trips
     set state='PUBLISHED'
   where id=v_trip.id
   returning * into v_trip;

  return jsonb_build_object(
    'trip_public_id',v_trip.public_id,
    'state',v_trip.state,
    'version',v_trip.version,
    'published_at',v_trip.published_at,
    'idempotent',false
  );
end;
$$;

revoke all on function public.tc_con_publish_trip(text,text)
  from public,anon,authenticated,service_role;
grant execute on function public.tc_con_publish_trip(text,text)
  to authenticated;

comment on function public.tc_con_publish_trip(text,text) is
'Authenticated owner-subprofile transition DRAFT→PUBLISHED. Existing publishability triggers remain authoritative.';

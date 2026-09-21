
revoke select on table public.evidence from anon;

drop policy if exists evidence_read on public.evidence;

create policy evidence_read
on public.evidence
for select
to authenticated
using (
  uploader_profile_id in (
    select profile_id from public.current_user_profile_ids()
  )
  or (
    evidence_type not like 'LAST_MILE_%'
    and package_id in (
      select p.id from public.packages p
    )
  )
  or (
    evidence_type like 'LAST_MILE_%'
    and exists(
      select 1
      from public.packages p
      join public.sub_orders so on so.id=p.sub_order_id
      join public.orders o on o.id=so.order_id
      where p.id=evidence.package_id
        and o.client_profile_id in (
          select profile_id
          from public.current_user_profile_ids()
          where profile_type='CLI'
        )
    )
  )
);

create or replace function public.tc_rsg_register_delivery_evidence(
  p_rsg_public_id text,
  p_movement_public_id text,
  p_package_public_id text,
  p_evidence_type text,
  p_object_path text,
  p_mime_type text,
  p_size_bytes bigint,
  p_sha256 text,
  p_captured_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rsg uuid;
  v_movement uuid;
  v_package uuid;
  v_type text:=upper(btrim(coalesce(p_evidence_type,'')));
  v_existing public.evidence%rowtype;
  v_evidence public.evidence%rowtype;
begin
  v_rsg:=public.tc_require_my_rsg_profile(p_rsg_public_id);

  if v_type not in ('LAST_MILE_DELIVERY_PHOTO','LAST_MILE_SIGNATURE_IMAGE') then
    raise exception using errcode='P0001', message='TC_LAST_MILE_EVIDENCE_TYPE_INVALID';
  end if;

  if nullif(btrim(coalesce(p_object_path,'')),'') is null
     or split_part(btrim(p_object_path),'/',1)<>auth.uid()::text
     or nullif(btrim(coalesce(p_mime_type,'')),'') is null
     or p_size_bytes is null or p_size_bytes<0
     or nullif(btrim(coalesce(p_sha256,'')),'') is null
     or p_captured_at is null then
    raise exception using errcode='P0001', message='TC_LAST_MILE_EVIDENCE_INPUT_INVALID';
  end if;

  select mv.id into v_movement
  from public.movements mv
  join public.logistics_last_mile_assignments a
    on a.movement_id=mv.id
   and a.rsg_profile_id=v_rsg
   and a.state='ACTIVE'
  where mv.public_id=upper(btrim(coalesce(p_movement_public_id,'')));

  if v_movement is null then
    raise exception using errcode='P0001', message='TC_RSG_MOVEMENT_FORBIDDEN';
  end if;

  select p.id into v_package
  from public.packages p
  join public.movement_packages mp
    on mp.package_id=p.id
   and mp.movement_id=v_movement
  where p.public_id=upper(btrim(coalesce(p_package_public_id,'')));

  if v_package is null then
    raise exception using errcode='P0001', message='TC_PACKAGE_NOT_IN_MOVEMENT';
  end if;

  if not exists(
    select 1
    from storage.objects so
    where so.bucket_id='tc-evidence'
      and so.name=btrim(p_object_path)
      and (
        so.owner=auth.uid()
        or so.owner_id=auth.uid()::text
      )
      and not so.is_delete_marker
  ) then
    raise exception using errcode='P0001', message='TC_LAST_MILE_EVIDENCE_OBJECT_NOT_FOUND';
  end if;

  select * into v_existing
  from public.evidence e
  where e.object_path=btrim(p_object_path);

  if v_existing.id is not null then
    if v_existing.uploader_profile_id is distinct from v_rsg
       or v_existing.package_id is distinct from v_package
       or v_existing.movement_id is distinct from v_movement
       or v_existing.evidence_type is distinct from v_type then
      raise exception using errcode='P0001', message='TC_LAST_MILE_EVIDENCE_PATH_REUSED';
    end if;

    return jsonb_build_object(
      'evidence_public_id',v_existing.public_id,
      'status',v_existing.status,
      'idempotent',true
    );
  end if;

  insert into public.evidence(
    uploader_profile_id,package_id,movement_id,route_id,
    source_event_id,evidence_type,
    bucket_id,object_path,mime_type,size_bytes,sha256,
    captured_at,status
  ) values(
    v_rsg,v_package,v_movement,null,
    null,v_type,
    'tc-evidence',btrim(p_object_path),btrim(p_mime_type),p_size_bytes,btrim(p_sha256),
    p_captured_at,'UPLOADED'
  )
  returning * into v_evidence;

  return jsonb_build_object(
    'evidence_public_id',v_evidence.public_id,
    'status',v_evidence.status,
    'idempotent',false
  );
end;
$$;

revoke all on function public.tc_rsg_register_delivery_evidence(
  text,text,text,text,text,text,bigint,text,timestamptz
) from public,anon,authenticated,service_role;

grant execute on function public.tc_rsg_register_delivery_evidence(
  text,text,text,text,text,text,bigint,text,timestamptz
) to authenticated;

comment on function public.tc_rsg_register_delivery_evidence(
  text,text,text,text,text,text,bigint,text,timestamptz
) is
'Registers assigned-RSG last-mile file evidence only after confirming the private Storage object exists under the caller auth.uid prefix.';

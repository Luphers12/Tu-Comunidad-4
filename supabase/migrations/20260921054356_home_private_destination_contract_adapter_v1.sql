
alter table public.private_destination_snapshots
  add column recipient_name text,
  add column recipient_phone text;

alter table public.private_destination_snapshots
  add constraint private_destination_snapshots_recipient_name_check
  check (recipient_name is null or btrim(recipient_name) <> '');

create trigger private_destination_snapshots_append_only_v1
before update or delete on public.private_destination_snapshots
for each row execute function public.tc_guard_logistics_append_only();

create or replace function public.tc_capture_home_destination_contract()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_person uuid;
  v_name text;
  v_phone text;
  v_loc public.customer_locations%rowtype;
  v_snapshot uuid;
  v_destination uuid;
  v_version uuid;
begin
  if upper(btrim(coalesce(new.destination_type,''))) <> 'HOME' then
    return new;
  end if;

  if new.destination_contract_id is not null then
    return new;
  end if;

  if nullif(btrim(coalesce(new.destination_id,'')),'') is null then
    raise exception using errcode='P0001', message='TC_HOME_DESTINATION_REQUIRED';
  end if;

  select per.id,per.full_name,per.phone
    into v_person,v_name,v_phone
  from public.profiles pr
  join public.persons per on per.id=pr.person_id
  where pr.id=new.client_profile_id
    and pr.profile_type='CLI'
    and pr.status='active';

  if v_person is null then
    raise exception using errcode='P0001', message='TC_HOME_CLIENT_PROFILE_INVALID';
  end if;

  if nullif(btrim(coalesce(v_name,'')),'') is null then
    raise exception using errcode='P0001', message='TC_HOME_RECIPIENT_NAME_REQUIRED';
  end if;

  select * into v_loc
  from public.customer_locations cl
  where cl.person_id=v_person
    and cl.active
    and upper(cl.destination_type)='HOME'
    and (
      cl.id::text=btrim(new.destination_id)
      or cl.public_id=upper(btrim(new.destination_id))
    )
  limit 1;

  if v_loc.id is null then
    raise exception using errcode='P0001', message='TC_HOME_DESTINATION_NOT_OWNED_OR_INACTIVE';
  end if;

  insert into public.private_destination_snapshots(
    source_customer_location_id,
    country_id,department_id,municipality_id,community_id,
    label,point,visual_reference,access_instructions,
    authorized_contact,photo_refs,safe_location_ref,
    recipient_name,recipient_phone
  ) values(
    v_loc.id,
    v_loc.country_id,v_loc.department_id,v_loc.municipality_id,v_loc.community_id,
    v_loc.label,v_loc.point,v_loc.visual_reference,v_loc.access_instructions,
    v_loc.authorized_contact,v_loc.photo_refs,v_loc.safe_location_ref,
    btrim(v_name),nullif(btrim(coalesce(v_phone,'')),'')
  )
  returning id into v_snapshot;

  insert into public.logistics_destinations(
    created_by_person_id
  ) values(
    v_person
  )
  returning id into v_destination;

  insert into public.logistics_destination_versions(
    destination_id,version_no,target_kind,
    private_snapshot_id,operational_location_id,
    country_id,department_id,municipality_id,community_id
  ) values(
    v_destination,1,'PRIVATE_LOCATION',
    v_snapshot,null,
    v_loc.country_id,v_loc.department_id,v_loc.municipality_id,v_loc.community_id
  )
  returning id into v_version;

  new.destination_contract_id:=v_version;
  new.destination_id:=v_loc.public_id;

  return new;
end;
$$;

revoke all on function public.tc_capture_home_destination_contract()
  from public,anon,authenticated,service_role;

create trigger orders_capture_home_destination_contract_v1
before insert on public.orders
for each row execute function public.tc_capture_home_destination_contract();

comment on column public.private_destination_snapshots.recipient_name is
'Immutable recipient name snapshot for authorized final-mile use and physical final-delivery label.';
comment on column public.private_destination_snapshots.recipient_phone is
'Immutable recipient phone snapshot. Digital authorized last-mile use only; never include in physical label output.';

-- TU COMUNIDAD
-- Keep CON context consistent with the runtime authorization window.
-- Runtime trip validation already enforces valid_from/valid_until; this
-- function now stops advertising vehicle authorizations that are not
-- currently valid.

create or replace function public.tc_con_my_context()
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_active uuid;
  v_profiles jsonb;
begin
  v_active:=public.tc_active_profile_id();

  if v_active is null then
    raise exception using errcode='P0001', message='TC_ACTIVE_PROFILE_NOT_SELECTED';
  end if;

  if not exists(
    select 1 from public.profiles p
    where p.id=v_active
      and p.profile_type='CON'
      and p.status='active'
  ) then
    raise exception using errcode='P0001', message='TC_ACTIVE_PROFILE_TYPE_MISMATCH';
  end if;

  select jsonb_build_array(
    jsonb_build_object(
      'con_public_id',p.public_id,
      'territory_id',p.territory_id,
      'vehicles',coalesce((
        select jsonb_agg(jsonb_build_object(
          'vehicle_public_id',v.public_id,
          'transport_type',v.transport_type,
          'plate_number',v.plate_number,
          'max_weight_kg',v.max_weight_kg,
          'max_volume_m3',v.max_volume_m3,
          'max_packages',v.max_packages,
          'supports_cold_chain',v.supports_cold_chain,
          'supports_fragile',v.supports_fragile,
          'supports_bulky',v.supports_bulky,
          'supports_rural_cargo',v.supports_rural_cargo,
          'valid_from',a.valid_from,
          'valid_until',a.valid_until
        ) order by v.public_id)
        from public.driver_vehicle_authorizations a
        join public.vehicles v on v.id=a.vehicle_id
        where a.driver_profile_id=p.id
          and a.is_active
          and v.is_active
          and a.valid_from <= now()
          and (a.valid_until is null or a.valid_until >= now())
      ),'[]'::jsonb)
    )
  )
  into v_profiles
  from public.profiles p
  where p.id=v_active;

  return jsonb_build_object(
    'con_profiles',coalesce(v_profiles,'[]'::jsonb),
    'con_profile_count',case when v_profiles is null then 0 else 1 end
  );
end;
$function$;

comment on function public.tc_con_my_context()
is 'Authenticated active-CON context. Vehicle list includes only active vehicle authorizations valid at the current time; trip runtime separately revalidates against planned departure.';

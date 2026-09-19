create or replace function public.tc_get_my_session_bootstrap()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_person public.persons%rowtype;
  v_profiles jsonb;
begin
  select * into v_person
  from public.persons
  where auth_user_id = auth.uid();

  if not found then
    raise exception 'TC_SESSION_PERSON_NOT_FOUND' using errcode='no_data_found';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'profile_id', p.id,
    'public_id', p.public_id,
    'profile_type', p.profile_type,
    'status', p.status,
    'territory_id', p.territory_id
  ) order by p.created_at, p.id), '[]'::jsonb)
  into v_profiles
  from public.profiles p
  where p.person_id = v_person.id;

  return jsonb_build_object(
    'person_public_id', v_person.public_id,
    'preferred_language', v_person.preferred_language,
    'profiles', v_profiles,
    'profile_count', jsonb_array_length(v_profiles)
  );
end;
$$;

revoke all on function public.tc_get_my_session_bootstrap() from public;
revoke all on function public.tc_get_my_session_bootstrap() from anon;
grant execute on function public.tc_get_my_session_bootstrap() to authenticated;
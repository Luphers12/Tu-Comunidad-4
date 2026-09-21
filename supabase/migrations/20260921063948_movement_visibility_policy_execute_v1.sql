
revoke all on function public.tc_active_profile_can_read_movement(uuid)
  from public,anon,authenticated,service_role;

grant execute on function public.tc_active_profile_can_read_movement(uuid)
  to authenticated;

comment on function public.tc_active_profile_can_read_movement(uuid) is
'RLS boolean helper. Authenticated EXECUTE is required for policy evaluation; it returns only whether the current explicit active profile may read the supplied movement.';

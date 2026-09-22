
-- TU COMUNIDAD — CLIENT ORDER LOGISTICS BRIDGE EXECUTE SURFACE HARDENING V1
-- tc_complete_package_preparation is the single authenticated source->logistics boundary.
-- The lower-level READY-package publisher remains internal/service-only.

revoke execute on function public.tc_publish_ready_package_to_logistics(text)
  from authenticated;

comment on function public.tc_publish_ready_package_to_logistics(text) is
'Internal/service-only READY-package publisher. Authenticated clients must use tc_complete_package_preparation(), which also safely handles an already-READY package idempotently.';

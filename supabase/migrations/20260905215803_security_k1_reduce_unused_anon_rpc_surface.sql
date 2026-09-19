
-- K1: reduce anonymous Data API surface without changing the active public
-- catalog contract used by the Lovable application.
revoke execute on function public.get_marketplace_offers(uuid) from anon;
revoke execute on function public.tc_get_feature_gates() from anon;

-- Preserve signed-in/internal compatibility while public clients continue
-- using public.tc_public_catalog(...).
grant execute on function public.get_marketplace_offers(uuid) to authenticated;
grant execute on function public.tc_get_feature_gates() to authenticated;

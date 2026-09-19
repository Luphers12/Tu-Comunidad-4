-- SOURCE NOT RECOVERED.
-- Same gap as 20260823035707: the statement was applied from the base64 buffer table
-- public._tc_migration_chunks, which no migration ever populated. The real body of
-- resolve_sync_conflict() exists only in the staging database.
-- The signature below is the one referenced by
-- 20260826221534_secure_sensitive_rpc_activation_v1.sql.
-- See supabase/migrations/RECOVERY_GAPS.md.
CREATE OR REPLACE FUNCTION public.resolve_sync_conflict(
  p_conflict_public_id text,
  p_resolution text,
  p_actor_profile_public_id text,
  p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'FUNCTION_SOURCE_NOT_RECOVERED: public.resolve_sync_conflict';
END;
$$;
REVOKE ALL ON FUNCTION public.resolve_sync_conflict(text,text,text,text) FROM PUBLIC;

-- SOURCE NOT RECOVERED.
-- The original statement of this version was applied from a base64 buffer table
-- (public._tc_migration_chunks) that was never populated by any migration and was
-- dropped afterwards, so the real body of process_event() exists only in the
-- staging database. See supabase/migrations/RECOVERY_GAPS.md.
-- Fail-closed placeholder so a fresh database is reproducible and the gap stays visible.
CREATE OR REPLACE FUNCTION public.process_event(p_event_envelope jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'FUNCTION_SOURCE_NOT_RECOVERED: public.process_event';
END;
$$;
REVOKE ALL ON FUNCTION public.process_event(jsonb) FROM PUBLIC;

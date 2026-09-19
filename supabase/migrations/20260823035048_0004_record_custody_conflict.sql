CREATE OR REPLACE FUNCTION public.tc_record_custody_conflict(
  p_event_id text,
  p_movement_public_id text,
  p_current_version bigint,
  p_expected_version bigint,
  p_current_state text,
  p_requested_event text,
  p_error_code text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_reason public.tc_conflict_reason;
  v_conflict_public_id text;
BEGIN
  v_reason := CASE
    WHEN p_error_code IN ('TC_VERSION_MISMATCH','TC_VERSION_CONFLICT') THEN 'version_mismatch'::public.tc_conflict_reason
    WHEN p_error_code IN ('TC_CUSTODY_MISMATCH','TC_PACKAGE_ALREADY_TRANSFERRED','TC_PACKAGE_RELEASE_REQUIRED','TC_RECEIVE_BEFORE_RELEASE_TIME') THEN 'custody_mismatch'::public.tc_conflict_reason
    WHEN p_error_code IN ('TC_DUPLICATE_CUSTODY_RELEASE','TC_DUPLICATE_CUSTODY_RECEIVE') THEN 'duplicate_operation'::public.tc_conflict_reason
    WHEN p_error_code IN ('TC_STALE_EVENT') THEN 'stale_event'::public.tc_conflict_reason
    WHEN p_error_code IN ('TC_PACKAGE_NOT_IN_MOVEMENT','TC_ROUTE_ASSIGNMENT_DRIVER_MISMATCH','TC_MOVEMENT_ROUTE_MISMATCH') THEN 'route_mismatch'::public.tc_conflict_reason
    WHEN p_error_code IN ('TC_UNAUTHORIZED_CUSTODY_RELEASE','TC_UNAUTHORIZED_CUSTODY_RECEIVE','TC_EVENT_ACTOR_UNAUTHORIZED') THEN 'unauthorized_actor'::public.tc_conflict_reason
    WHEN p_error_code IN ('TC_EVIDENCE_INCOMPLETE') THEN 'evidence_incomplete'::public.tc_conflict_reason
    ELSE 'invalid_state_transition'::public.tc_conflict_reason
  END;
  INSERT INTO public.sync_conflicts(event_id,entity_type,entity_id,current_version,expected_version,current_state,requested_event,reason,metadata)
  VALUES(p_event_id,'MOVEMENT',p_movement_public_id,p_current_version,p_expected_version,p_current_state,p_requested_event,v_reason,jsonb_build_object('error_code',p_error_code))
  RETURNING public_id INTO v_conflict_public_id;
  RETURN v_conflict_public_id;
END;
$$;
REVOKE ALL ON FUNCTION public.tc_record_custody_conflict(text,text,bigint,bigint,text,text,text) FROM PUBLIC,anon,authenticated;
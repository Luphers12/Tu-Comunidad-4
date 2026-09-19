CREATE OR REPLACE FUNCTION public.tc_classify_custody_sync_event(
  p_event_type text,
  p_movement_public_id text,
  p_package_public_ids text[],
  p_actor_profile_id uuid,
  p_occurred_at timestamptz,
  p_expected_version bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_movement public.movements%ROWTYPE;
  v_actor_profile public.profiles%ROWTYPE;
  v_assignment public.route_assignments%ROWTYPE;
  v_requested_count integer := 0;
  v_manifest_count integer := 0;
  v_row_count integer := 0;
  v_stale_count integer := 0;
  v_applicable_count integer := 0;
  v_retry_count integer := 0;
  v_conflict_count integer := 0;
  v_version_mismatch boolean := false;
  v_error_code text;
  v_rec record;
BEGIN
  SELECT m.* INTO v_movement FROM public.movements m WHERE m.public_id=upper(btrim(p_movement_public_id)) FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('resolution','REJECTED_INVALID_TRANSITION','error_code','TC_MOVEMENT_NOT_FOUND'); END IF;
  SELECT p.* INTO v_actor_profile FROM public.profiles p WHERE p.id=p_actor_profile_id AND p.status='active';
  IF NOT FOUND THEN RETURN jsonb_build_object('resolution','REJECTED_UNAUTHORIZED','error_code','TC_EVENT_ACTOR_UNAUTHORIZED','current_state',v_movement.state,'current_version',v_movement.version); END IF;
  v_version_mismatch := p_expected_version IS NOT NULL AND p_expected_version<>v_movement.version;
  IF p_package_public_ids IS NULL OR cardinality(p_package_public_ids)<1 THEN RETURN jsonb_build_object('resolution','REJECTED_INVALID_TRANSITION','error_code','TC_EMPTY_EVENT_PACKAGE_SET','current_state',v_movement.state,'current_version',v_movement.version,'version_mismatch',v_version_mismatch); END IF;
  v_requested_count := (SELECT count(DISTINCT upper(btrim(x))) FROM unnest(p_package_public_ids) AS x WHERE nullif(btrim(x),'') IS NOT NULL);
  SELECT count(*) INTO v_manifest_count FROM public.movement_packages mp JOIN public.packages pkg ON pkg.id=mp.package_id WHERE mp.movement_id=v_movement.id AND pkg.public_id IN (SELECT DISTINCT upper(btrim(x)) FROM unnest(p_package_public_ids) AS x WHERE nullif(btrim(x),'') IS NOT NULL);
  IF v_manifest_count<>v_requested_count THEN RETURN jsonb_build_object('resolution','CONFLICT_NEEDS_REVIEW','error_code','TC_PACKAGE_NOT_IN_MOVEMENT','current_state',v_movement.state,'current_version',v_movement.version,'version_mismatch',v_version_mismatch); END IF;
  INSERT INTO public.movement_custody_handshakes(movement_id,package_id,from_profile_id,to_profile_id,status)
  SELECT v_movement.id,mp.package_id,v_movement.from_profile_id,v_movement.to_profile_id,'PLANNED'
  FROM public.movement_packages mp JOIN public.packages pkg ON pkg.id=mp.package_id
  WHERE mp.movement_id=v_movement.id AND pkg.public_id IN (SELECT DISTINCT upper(btrim(x)) FROM unnest(p_package_public_ids) AS x WHERE nullif(btrim(x),'') IS NOT NULL)
  ON CONFLICT (movement_id,package_id) DO NOTHING;
  IF p_event_type='CUSTODY_RELEASED' AND v_movement.from_profile_id IS DISTINCT FROM p_actor_profile_id THEN RETURN jsonb_build_object('resolution','REJECTED_UNAUTHORIZED','error_code','TC_UNAUTHORIZED_CUSTODY_RELEASE','current_state',v_movement.state,'current_version',v_movement.version,'version_mismatch',v_version_mismatch); END IF;
  IF p_event_type='CUSTODY_RECEIVED' AND v_movement.to_profile_id IS DISTINCT FROM p_actor_profile_id THEN RETURN jsonb_build_object('resolution','REJECTED_UNAUTHORIZED','error_code','TC_UNAUTHORIZED_CUSTODY_RECEIVE','current_state',v_movement.state,'current_version',v_movement.version,'version_mismatch',v_version_mismatch); END IF;
  IF p_event_type='CUSTODY_RECEIVED' AND v_actor_profile.profile_type='CON' AND v_movement.route_assignment_id IS NOT NULL THEN
    SELECT ra.* INTO v_assignment FROM public.route_assignments ra WHERE ra.id=v_movement.route_assignment_id FOR UPDATE;
    IF NOT FOUND OR v_assignment.driver_profile_id<>p_actor_profile_id THEN RETURN jsonb_build_object('resolution','CONFLICT_NEEDS_REVIEW','error_code','TC_ROUTE_ASSIGNMENT_DRIVER_MISMATCH','current_state',v_movement.state,'current_version',v_movement.version,'version_mismatch',v_version_mismatch); END IF;
  END IF;
  FOR v_rec IN
    SELECT pkg.id AS package_id,pkg.public_id AS package_public_id,pkg.current_custodian_id,pkg.state AS package_state,pkg.version AS package_version,h.id AS handshake_id,h.status AS handshake_status,h.release_event_id,h.receive_event_id,h.release_occurred_at,h.receive_occurred_at
    FROM public.movement_packages mp JOIN public.packages pkg ON pkg.id=mp.package_id JOIN public.movement_custody_handshakes h ON h.movement_id=mp.movement_id AND h.package_id=mp.package_id
    WHERE mp.movement_id=v_movement.id AND pkg.public_id IN (SELECT DISTINCT upper(btrim(x)) FROM unnest(p_package_public_ids) AS x WHERE nullif(btrim(x),'') IS NOT NULL)
    ORDER BY pkg.id FOR UPDATE OF pkg,h
  LOOP
    v_row_count := v_row_count + 1;
    IF p_event_type='CUSTODY_RELEASED' THEN
      IF v_rec.handshake_status='PLANNED' THEN
        IF v_rec.current_custodian_id=v_movement.from_profile_id THEN v_applicable_count:=v_applicable_count+1; ELSE v_conflict_count:=v_conflict_count+1; v_error_code:=coalesce(v_error_code,'TC_CUSTODY_MISMATCH'); END IF;
      ELSIF v_rec.handshake_status='RELEASED' THEN
        IF v_rec.release_occurred_at IS NULL OR p_occurred_at<=v_rec.release_occurred_at THEN v_stale_count:=v_stale_count+1; ELSE v_conflict_count:=v_conflict_count+1; v_error_code:=coalesce(v_error_code,'TC_DUPLICATE_CUSTODY_RELEASE'); END IF;
      ELSIF v_rec.handshake_status='RECEIVED' THEN
        IF v_rec.receive_occurred_at IS NULL OR p_occurred_at<=v_rec.receive_occurred_at THEN v_stale_count:=v_stale_count+1; ELSE v_conflict_count:=v_conflict_count+1; v_error_code:=coalesce(v_error_code,'TC_PACKAGE_ALREADY_TRANSFERRED'); END IF;
      ELSE v_conflict_count:=v_conflict_count+1; v_error_code:=coalesce(v_error_code,'TC_INVALID_CUSTODY_HANDSHAKE_STATE');
      END IF;
    ELSIF p_event_type='CUSTODY_RECEIVED' THEN
      IF v_rec.handshake_status='PLANNED' THEN
        IF v_rec.current_custodian_id=v_movement.from_profile_id THEN v_retry_count:=v_retry_count+1; v_error_code:=coalesce(v_error_code,'TC_RELEASE_EVENT_NOT_ARRIVED'); ELSE v_conflict_count:=v_conflict_count+1; v_error_code:=coalesce(v_error_code,'TC_CUSTODY_MISMATCH'); END IF;
      ELSIF v_rec.handshake_status='RELEASED' THEN
        IF v_rec.current_custodian_id<>v_movement.from_profile_id THEN v_conflict_count:=v_conflict_count+1; v_error_code:=coalesce(v_error_code,'TC_CUSTODY_MISMATCH');
        ELSIF v_rec.release_occurred_at IS NOT NULL AND p_occurred_at<v_rec.release_occurred_at THEN v_conflict_count:=v_conflict_count+1; v_error_code:=coalesce(v_error_code,'TC_RECEIVE_BEFORE_RELEASE_TIME');
        ELSE v_applicable_count:=v_applicable_count+1; END IF;
      ELSIF v_rec.handshake_status='RECEIVED' THEN
        IF v_rec.current_custodian_id=v_movement.to_profile_id THEN v_stale_count:=v_stale_count+1; ELSE v_conflict_count:=v_conflict_count+1; v_error_code:=coalesce(v_error_code,'TC_CUSTODY_MISMATCH'); END IF;
      ELSE v_conflict_count:=v_conflict_count+1; v_error_code:=coalesce(v_error_code,'TC_INVALID_CUSTODY_HANDSHAKE_STATE');
      END IF;
    ELSE
      RETURN jsonb_build_object('resolution','REJECTED_INVALID_TRANSITION','error_code','TC_EVENT_TYPE_NOT_SUPPORTED','current_state',v_movement.state,'current_version',v_movement.version,'version_mismatch',v_version_mismatch);
    END IF;
  END LOOP;
  IF v_row_count<>v_requested_count THEN RETURN jsonb_build_object('resolution','CONFLICT_NEEDS_REVIEW','error_code','TC_EVENT_PACKAGE_RESOLUTION_MISMATCH','current_state',v_movement.state,'current_version',v_movement.version,'version_mismatch',v_version_mismatch); END IF;
  IF v_conflict_count>0 THEN RETURN jsonb_build_object('resolution','CONFLICT_NEEDS_REVIEW','error_code',coalesce(v_error_code,'TC_CUSTODY_CONFLICT'),'current_state',v_movement.state,'current_version',v_movement.version,'version_mismatch',v_version_mismatch,'applicable_count',v_applicable_count,'stale_count',v_stale_count,'retry_count',v_retry_count,'conflict_count',v_conflict_count); END IF;
  IF v_stale_count>0 AND v_applicable_count>0 THEN RETURN jsonb_build_object('resolution','CONFLICT_NEEDS_REVIEW','error_code','TC_MIXED_STALE_AND_APPLICABLE_EVENT','current_state',v_movement.state,'current_version',v_movement.version,'version_mismatch',v_version_mismatch); END IF;
  IF v_retry_count>0 THEN RETURN jsonb_build_object('resolution','RETRY_LATER','error_code',coalesce(v_error_code,'TC_EVENT_PREREQUISITE_MISSING'),'current_state',v_movement.state,'current_version',v_movement.version,'version_mismatch',v_version_mismatch,'retry_count',v_retry_count); END IF;
  IF v_stale_count=v_requested_count THEN RETURN jsonb_build_object('resolution','IGNORED_STALE','error_code','TC_STALE_EVENT','current_state',v_movement.state,'current_version',v_movement.version,'version_mismatch',v_version_mismatch); END IF;
  IF v_applicable_count=v_requested_count THEN RETURN jsonb_build_object('resolution','APPLIED','error_code',NULL,'current_state',v_movement.state,'current_version',v_movement.version,'version_mismatch',v_version_mismatch,'version_mismatch_tolerated',v_version_mismatch); END IF;
  RETURN jsonb_build_object('resolution','REJECTED_INVALID_TRANSITION','error_code','TC_INVALID_SYNC_TRANSITION','current_state',v_movement.state,'current_version',v_movement.version,'version_mismatch',v_version_mismatch);
END;
$$;
REVOKE ALL ON FUNCTION public.tc_classify_custody_sync_event(text,text,text[],uuid,timestamptz,bigint) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.tc_apply_custody_receive(
  p_event_id text,
  p_movement_public_id text,
  p_package_public_ids text[],
  p_actor_profile_id uuid,
  p_occurred_at timestamptz
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
  v_requested_count integer;
  v_manifest_count integer;
  v_received_total integer;
  v_manifest_total integer;
  v_before_version bigint;
  v_after_version bigint;
  v_next_package_state text;
  v_next_movement_state text;
  v_rec record;
BEGIN
  SELECT m.* INTO v_movement FROM public.movements m WHERE m.public_id=upper(btrim(p_movement_public_id)) FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'disposition','REJECTED','error_code','TC_MOVEMENT_NOT_FOUND'); END IF;
  IF v_movement.to_profile_id IS DISTINCT FROM p_actor_profile_id THEN RETURN jsonb_build_object('success',false,'disposition','CONFLICT','error_code','TC_UNAUTHORIZED_CUSTODY_RECEIVE','movement_id',v_movement.public_id,'resulting_state',v_movement.state,'resulting_version',v_movement.version); END IF;
  IF v_movement.state <> 'TRANSFER_PENDING' THEN RETURN jsonb_build_object('success',false,'disposition','REJECTED','error_code','TC_RELEASE_REQUIRED_BEFORE_RECEIVE','movement_id',v_movement.public_id,'resulting_state',v_movement.state,'resulting_version',v_movement.version); END IF;
  SELECT p.* INTO v_actor_profile FROM public.profiles p WHERE p.id=p_actor_profile_id AND p.status='active';
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'disposition','REJECTED','error_code','TC_RECEIVER_PROFILE_INACTIVE'); END IF;
  IF v_movement.route_assignment_id IS NOT NULL THEN
    SELECT ra.* INTO v_assignment FROM public.route_assignments ra WHERE ra.id=v_movement.route_assignment_id FOR UPDATE;
    IF FOUND AND v_actor_profile.profile_type='CON' AND v_assignment.driver_profile_id<>p_actor_profile_id THEN RETURN jsonb_build_object('success',false,'disposition','CONFLICT','error_code','TC_ROUTE_ASSIGNMENT_DRIVER_MISMATCH','movement_id',v_movement.public_id,'resulting_state',v_movement.state,'resulting_version',v_movement.version); END IF;
  END IF;
  IF p_package_public_ids IS NULL OR cardinality(p_package_public_ids)<1 THEN RETURN jsonb_build_object('success',false,'disposition','REJECTED','error_code','TC_EMPTY_EVENT_PACKAGE_SET'); END IF;
  v_requested_count := (SELECT count(DISTINCT upper(btrim(x))) FROM unnest(p_package_public_ids) AS x WHERE nullif(btrim(x),'') IS NOT NULL);
  SELECT count(*) INTO v_manifest_count FROM public.movement_packages mp JOIN public.packages pkg ON pkg.id=mp.package_id WHERE mp.movement_id=v_movement.id AND pkg.public_id IN (SELECT DISTINCT upper(btrim(x)) FROM unnest(p_package_public_ids) AS x WHERE nullif(btrim(x),'') IS NOT NULL);
  IF v_manifest_count<>v_requested_count THEN RETURN jsonb_build_object('success',false,'disposition','CONFLICT','error_code','TC_PACKAGE_NOT_IN_MOVEMENT','movement_id',v_movement.public_id,'resulting_state',v_movement.state,'resulting_version',v_movement.version); END IF;
  v_next_package_state := CASE v_actor_profile.profile_type WHEN 'CON' THEN 'IN_TRANSIT' WHEN 'RSG' THEN 'OUT_FOR_DELIVERY' WHEN 'PTC' THEN 'AT_PTC' WHEN 'TIE' THEN 'READY' WHEN 'VEN' THEN 'READY' ELSE 'IN_TRANSIT' END;
  FOR v_rec IN
    SELECT pkg.id AS package_id,pkg.public_id AS package_public_id,pkg.current_custodian_id,pkg.version AS package_version,h.id AS handshake_id,h.status AS handshake_status,h.release_event_id,h.receive_event_id
    FROM public.movement_packages mp JOIN public.packages pkg ON pkg.id=mp.package_id JOIN public.movement_custody_handshakes h ON h.movement_id=mp.movement_id AND h.package_id=mp.package_id
    WHERE mp.movement_id=v_movement.id AND pkg.public_id IN (SELECT DISTINCT upper(btrim(x)) FROM unnest(p_package_public_ids) AS x WHERE nullif(btrim(x),'') IS NOT NULL)
    ORDER BY pkg.id FOR UPDATE OF pkg,h
  LOOP
    IF v_rec.handshake_status<>'RELEASED' OR v_rec.release_event_id IS NULL THEN RETURN jsonb_build_object('success',false,'disposition','CONFLICT','error_code','TC_PACKAGE_RELEASE_REQUIRED','package_id',v_rec.package_public_id,'movement_id',v_movement.public_id,'resulting_state',v_movement.state,'resulting_version',v_movement.version); END IF;
    IF v_rec.current_custodian_id IS DISTINCT FROM v_movement.from_profile_id THEN RETURN jsonb_build_object('success',false,'disposition','CONFLICT','error_code','TC_CUSTODY_MISMATCH','package_id',v_rec.package_public_id,'movement_id',v_movement.public_id,'resulting_state',v_movement.state,'resulting_version',v_movement.version); END IF;
    UPDATE public.packages SET current_custodian_id=p_actor_profile_id,state=v_next_package_state,version=version+1 WHERE id=v_rec.package_id;
    UPDATE public.movement_custody_handshakes SET status='RECEIVED',receive_event_id=p_event_id,receive_occurred_at=p_occurred_at,version=version+1 WHERE id=v_rec.handshake_id;
    INSERT INTO public.custody_events(package_id,movement_id,from_profile_id,to_profile_id,event_id,occurred_at) VALUES(v_rec.package_id,v_movement.id,v_movement.from_profile_id,p_actor_profile_id,p_event_id,p_occurred_at);
  END LOOP;
  SELECT count(*) INTO v_manifest_total FROM public.movement_packages mp WHERE mp.movement_id=v_movement.id;
  SELECT count(*) INTO v_received_total FROM public.movement_custody_handshakes h WHERE h.movement_id=v_movement.id AND h.status='RECEIVED';
  IF v_received_total=v_manifest_total AND v_manifest_total>0 THEN v_next_movement_state := CASE WHEN v_movement.movement_type IN ('STORE_TO_DRIVER','PTC_TO_DRIVER','PTC_TO_DELIVERY') THEN 'IN_TRANSIT' ELSE 'COMPLETED' END; ELSE v_next_movement_state := 'TRANSFER_PENDING'; END IF;
  v_before_version := v_movement.version;
  UPDATE public.movements SET state=v_next_movement_state,version=version+1,completed_at=CASE WHEN v_next_movement_state='COMPLETED' THEN coalesce(completed_at,now()) ELSE completed_at END WHERE id=v_movement.id RETURNING version INTO v_after_version;
  IF v_next_movement_state='IN_TRANSIT' AND v_movement.route_assignment_id IS NOT NULL THEN UPDATE public.route_assignments SET state='IN_PROGRESS',version=version+1 WHERE id=v_movement.route_assignment_id AND state='ASSIGNED'; END IF;
  RETURN jsonb_build_object('success',true,'disposition','APPLIED','movement_id',v_movement.public_id,'resulting_state',v_next_movement_state,'resulting_version',v_after_version,'before_version',v_before_version,'processed_package_count',v_requested_count,'received_manifest_count',v_received_total,'manifest_count',v_manifest_total);
END;
$$;
REVOKE ALL ON FUNCTION public.tc_apply_custody_receive(text,text,text[],uuid,timestamptz) FROM PUBLIC,anon,authenticated;
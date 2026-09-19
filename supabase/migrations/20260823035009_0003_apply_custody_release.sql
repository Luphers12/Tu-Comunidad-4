CREATE OR REPLACE FUNCTION public.tc_apply_custody_release(p_event_id text, p_movement_public_id text, p_package_public_ids text[], p_actor_profile_id uuid, p_occurred_at timestamp with time zone)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_movement public.movements%ROWTYPE;
  v_requested_count integer;
  v_manifest_count integer;
  v_before_version bigint;
  v_after_version bigint;
  v_rec record;
BEGIN
  SELECT m.* INTO v_movement FROM public.movements m WHERE m.public_id = upper(btrim(p_movement_public_id)) FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'disposition','REJECTED','error_code','TC_MOVEMENT_NOT_FOUND'); END IF;
  IF v_movement.from_profile_id IS DISTINCT FROM p_actor_profile_id THEN RETURN jsonb_build_object('success',false,'disposition','CONFLICT','error_code','TC_UNAUTHORIZED_CUSTODY_RELEASE','movement_id',v_movement.public_id,'resulting_state',v_movement.state,'resulting_version',v_movement.version); END IF;
  IF v_movement.state NOT IN ('PLANNED','ASSIGNED','READY','TRANSFER_PENDING') THEN RETURN jsonb_build_object('success',false,'disposition','REJECTED','error_code','TC_INVALID_MOVEMENT_STATE','movement_id',v_movement.public_id,'resulting_state',v_movement.state,'resulting_version',v_movement.version); END IF;
  IF p_package_public_ids IS NULL OR cardinality(p_package_public_ids)<1 THEN RETURN jsonb_build_object('success',false,'disposition','REJECTED','error_code','TC_EMPTY_EVENT_PACKAGE_SET'); END IF;
  v_requested_count := (SELECT count(DISTINCT upper(btrim(x))) FROM unnest(p_package_public_ids) AS x WHERE nullif(btrim(x),'') IS NOT NULL);
  SELECT count(*) INTO v_manifest_count FROM public.movement_packages mp JOIN public.packages pkg ON pkg.id=mp.package_id WHERE mp.movement_id=v_movement.id AND pkg.public_id IN (SELECT DISTINCT upper(btrim(x)) FROM unnest(p_package_public_ids) AS x WHERE nullif(btrim(x),'') IS NOT NULL);
  IF v_manifest_count <> v_requested_count THEN RETURN jsonb_build_object('success',false,'disposition','CONFLICT','error_code','TC_PACKAGE_NOT_IN_MOVEMENT','movement_id',v_movement.public_id,'resulting_state',v_movement.state,'resulting_version',v_movement.version); END IF;
  INSERT INTO public.movement_custody_handshakes(movement_id,package_id,from_profile_id,to_profile_id,status)
  SELECT v_movement.id,mp.package_id,v_movement.from_profile_id,v_movement.to_profile_id,'PLANNED'
  FROM public.movement_packages mp JOIN public.packages pkg ON pkg.id=mp.package_id
  WHERE mp.movement_id=v_movement.id AND pkg.public_id IN (SELECT DISTINCT upper(btrim(x)) FROM unnest(p_package_public_ids) AS x WHERE nullif(btrim(x),'') IS NOT NULL)
  ON CONFLICT (movement_id,package_id) DO NOTHING;
  FOR v_rec IN
    SELECT pkg.id AS package_id,pkg.public_id AS package_public_id,pkg.current_custodian_id,pkg.version AS package_version,h.id AS handshake_id,h.status AS handshake_status,h.release_event_id,h.receive_event_id
    FROM public.movement_packages mp JOIN public.packages pkg ON pkg.id=mp.package_id JOIN public.movement_custody_handshakes h ON h.movement_id=mp.movement_id AND h.package_id=mp.package_id
    WHERE mp.movement_id=v_movement.id AND pkg.public_id IN (SELECT DISTINCT upper(btrim(x)) FROM unnest(p_package_public_ids) AS x WHERE nullif(btrim(x),'') IS NOT NULL)
    ORDER BY pkg.id FOR UPDATE OF pkg,h
  LOOP
    IF v_rec.current_custodian_id IS DISTINCT FROM p_actor_profile_id THEN RETURN jsonb_build_object('success',false,'disposition','CONFLICT','error_code','TC_CUSTODY_MISMATCH','package_id',v_rec.package_public_id,'movement_id',v_movement.public_id,'resulting_state',v_movement.state,'resulting_version',v_movement.version); END IF;
    IF v_rec.handshake_status='RECEIVED' THEN RETURN jsonb_build_object('success',false,'disposition','CONFLICT','error_code','TC_PACKAGE_ALREADY_TRANSFERRED','package_id',v_rec.package_public_id,'movement_id',v_movement.public_id,'resulting_state',v_movement.state,'resulting_version',v_movement.version); END IF;
    IF v_rec.handshake_status='RELEASED' THEN
      IF v_rec.release_event_id IS DISTINCT FROM p_event_id THEN RETURN jsonb_build_object('success',false,'disposition','CONFLICT','error_code','TC_DUPLICATE_CUSTODY_RELEASE','package_id',v_rec.package_public_id,'movement_id',v_movement.public_id,'resulting_state',v_movement.state,'resulting_version',v_movement.version); END IF;
    ELSE
      UPDATE public.movement_custody_handshakes SET status='RELEASED',release_event_id=p_event_id,release_occurred_at=p_occurred_at,version=version+1 WHERE id=v_rec.handshake_id;
    END IF;
  END LOOP;
  v_before_version := v_movement.version;
  UPDATE public.movements SET state='TRANSFER_PENDING',version=version+1 WHERE id=v_movement.id RETURNING version INTO v_after_version;
  RETURN jsonb_build_object('success',true,'disposition','APPLIED','movement_id',v_movement.public_id,'resulting_state','TRANSFER_PENDING','resulting_version',v_after_version,'before_version',v_before_version,'processed_package_count',v_requested_count);
END;
$function$;
REVOKE ALL ON FUNCTION public.tc_apply_custody_release(text,text,text[],uuid,timestamptz) FROM PUBLIC,anon,authenticated;
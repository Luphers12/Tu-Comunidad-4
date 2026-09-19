CREATE OR REPLACE FUNCTION public.tc_create_planned_movement(
  p_route_assignment_public_id text,
  p_from_profile_public_id text,
  p_to_profile_public_id text,
  p_movement_type text,
  p_package_public_ids text[],
  p_sequence_number integer DEFAULT 1
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_assignment public.route_assignments%ROWTYPE;
  v_from_profile public.profiles%ROWTYPE;
  v_to_profile public.profiles%ROWTYPE;
  v_movement_id uuid;
  v_movement_public_id text;
  v_requested_count integer;
  v_resolved_count integer;
BEGIN
  IF p_sequence_number IS NULL OR p_sequence_number <= 0 THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_INVALID_MOVEMENT_SEQUENCE'; END IF;
  IF p_package_public_ids IS NULL OR cardinality(p_package_public_ids) < 1 THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_EMPTY_MOVEMENT_MANIFEST'; END IF;
  IF p_movement_type NOT IN ('STORE_TO_PTC','STORE_TO_DRIVER','PTC_TO_PTC','PTC_TO_DRIVER','DRIVER_TO_PTC','PTC_TO_DELIVERY','DELIVERY_TO_CUSTOMER','RETURN') THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_INVALID_MOVEMENT_TYPE'; END IF;
  SELECT ra.* INTO v_assignment FROM public.route_assignments ra WHERE ra.public_id=upper(btrim(p_route_assignment_public_id)) FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_ROUTE_ASSIGNMENT_NOT_FOUND'; END IF;
  IF v_assignment.state NOT IN ('ASSIGNED','IN_PROGRESS') THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_ROUTE_ASSIGNMENT_NOT_ACTIVE'; END IF;
  SELECT p.* INTO v_from_profile FROM public.profiles p WHERE p.public_id=upper(btrim(p_from_profile_public_id)) AND p.status='active';
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_MOVEMENT_ORIGIN_PROFILE_INVALID'; END IF;
  SELECT p.* INTO v_to_profile FROM public.profiles p WHERE p.public_id=upper(btrim(p_to_profile_public_id)) AND p.status='active';
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_MOVEMENT_DESTINATION_PROFILE_INVALID'; END IF;
  IF p_movement_type IN ('STORE_TO_DRIVER','PTC_TO_DRIVER') AND v_to_profile.id <> v_assignment.driver_profile_id THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_MOVEMENT_DRIVER_ASSIGNMENT_MISMATCH'; END IF;
  IF p_movement_type='STORE_TO_DRIVER' AND v_from_profile.profile_type NOT IN ('TIE','VEN') THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_MOVEMENT_ORIGIN_TYPE_INVALID'; END IF;
  v_requested_count := (SELECT count(DISTINCT upper(btrim(x))) FROM unnest(p_package_public_ids) AS x WHERE nullif(btrim(x),'') IS NOT NULL);
  SELECT count(*) INTO v_resolved_count FROM public.packages pkg WHERE pkg.public_id IN (SELECT DISTINCT upper(btrim(x)) FROM unnest(p_package_public_ids) AS x WHERE nullif(btrim(x),'') IS NOT NULL);
  IF v_requested_count < 1 OR v_resolved_count <> v_requested_count THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_MOVEMENT_MANIFEST_PACKAGE_INVALID'; END IF;
  IF EXISTS (SELECT 1 FROM public.packages pkg WHERE pkg.public_id IN (SELECT DISTINCT upper(btrim(x)) FROM unnest(p_package_public_ids) AS x WHERE nullif(btrim(x),'') IS NOT NULL) AND pkg.current_custodian_id <> v_from_profile.id) THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_MOVEMENT_ORIGIN_CUSTODY_MISMATCH'; END IF;
  INSERT INTO public.movements(route_id,route_assignment_id,from_profile_id,to_profile_id,movement_type,state,sequence_number,version)
  VALUES(v_assignment.route_id,v_assignment.id,v_from_profile.id,v_to_profile.id,p_movement_type,'PLANNED',p_sequence_number,0)
  RETURNING id,public_id INTO v_movement_id,v_movement_public_id;
  INSERT INTO public.movement_packages(movement_id,package_id)
  SELECT v_movement_id,pkg.id FROM public.packages pkg WHERE pkg.public_id IN (SELECT DISTINCT upper(btrim(x)) FROM unnest(p_package_public_ids) AS x WHERE nullif(btrim(x),'') IS NOT NULL) ORDER BY pkg.id;
  INSERT INTO public.movement_custody_handshakes(movement_id,package_id,from_profile_id,to_profile_id,status)
  SELECT v_movement_id,mp.package_id,v_from_profile.id,v_to_profile.id,'PLANNED' FROM public.movement_packages mp WHERE mp.movement_id=v_movement_id ORDER BY mp.package_id;
  RETURN v_movement_public_id;
END;
$$;
REVOKE ALL ON FUNCTION public.tc_create_planned_movement(text,text,text,text,text[],integer) FROM PUBLIC,anon,authenticated;
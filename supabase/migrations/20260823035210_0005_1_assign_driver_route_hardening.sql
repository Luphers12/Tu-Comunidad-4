CREATE OR REPLACE FUNCTION public.assign_driver_route(
  p_driver_profile_public_id text,
  p_vehicle_public_id text,
  p_route_public_id text,
  p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_user_id uuid;
  v_person_id uuid;
  v_driver public.profiles%ROWTYPE;
  v_vehicle public.vehicles%ROWTYPE;
  v_route public.route_opportunities%ROWTYPE;
  v_driver_public_id text;
  v_vehicle_public_id text;
  v_route_public_id text;
  v_idempotency_key text;
  v_request_hash text;
  v_canonical_request text;
  v_idem_inserted integer := 0;
  v_idem_person_id uuid;
  v_idem_hash text;
  v_idem_status text;
  v_idem_payload jsonb;
  v_authorization public.driver_vehicle_authorizations%ROWTYPE;
  v_manifest_count integer := 0;
  v_locked_count integer := 0;
  v_total_weight numeric(14,3) := 0;
  v_total_volume numeric(14,4) := 0;
  v_requires_cold boolean := false;
  v_requires_fragile boolean := false;
  v_pkg record;
  v_origin record;
  v_assignment_id uuid;
  v_assignment_public_id text;
  v_sequence integer := 0;
  v_movement_public_id text;
  v_movement_public_ids jsonb := '[]'::jsonb;
  v_response jsonb;
  v_updated integer := 0;
BEGIN
  v_auth_user_id := auth.uid();
  IF v_auth_user_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_UNAUTHENTICATED'; END IF;
  v_driver_public_id := upper(btrim(coalesce(p_driver_profile_public_id,'')));
  v_vehicle_public_id := upper(btrim(coalesce(p_vehicle_public_id,'')));
  v_route_public_id := upper(btrim(coalesce(p_route_public_id,'')));
  v_idempotency_key := btrim(coalesce(p_idempotency_key,''));
  IF v_driver_public_id='' OR v_driver_public_id NOT LIKE 'CON-%' THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_DRIVER_FORBIDDEN'; END IF;
  IF v_vehicle_public_id='' OR v_vehicle_public_id NOT LIKE 'VEH-%' THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_VEHICLE_NOT_FOUND'; END IF;
  IF v_route_public_id='' OR v_route_public_id NOT LIKE 'RTE-%' THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_ROUTE_NOT_FOUND'; END IF;
  IF length(v_idempotency_key)<8 OR length(v_idempotency_key)>200 THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_INVALID_IDEMPOTENCY_KEY'; END IF;
  SELECT per.id INTO v_person_id FROM public.persons per WHERE per.auth_user_id=v_auth_user_id LIMIT 1;
  IF v_person_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_DRIVER_FORBIDDEN'; END IF;
  SELECT pr.* INTO v_driver FROM public.profiles pr WHERE pr.person_id=v_person_id AND pr.public_id=v_driver_public_id AND pr.profile_type='CON' AND pr.status='active' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_DRIVER_FORBIDDEN'; END IF;
  v_canonical_request := v_driver_public_id || '|' || v_vehicle_public_id || '|' || v_route_public_id;
  v_request_hash := encode(digest(v_canonical_request,'sha256'),'hex');
  INSERT INTO public.idempotency_records(operation_type,idempotency_key,person_id,request_hash,status)
  VALUES('ASSIGN_DRIVER_ROUTE',v_idempotency_key,v_person_id,v_request_hash,'PROCESSING')
  ON CONFLICT(operation_type,idempotency_key) DO NOTHING;
  GET DIAGNOSTICS v_idem_inserted = ROW_COUNT;
  IF v_idem_inserted=0 THEN
    SELECT person_id,request_hash,status,response_payload INTO v_idem_person_id,v_idem_hash,v_idem_status,v_idem_payload
    FROM public.idempotency_records WHERE operation_type='ASSIGN_DRIVER_ROUTE' AND idempotency_key=v_idempotency_key FOR UPDATE;
    IF v_idem_person_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_IDEMPOTENCY_STATE_INVALID'; END IF;
    IF v_idem_person_id<>v_person_id OR v_idem_hash<>v_request_hash THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_IDEMPOTENCY_KEY_REUSED'; END IF;
    IF v_idem_status='COMPLETED' THEN
      IF v_idem_payload IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_IDEMPOTENCY_STATE_INVALID'; END IF;
      RETURN v_idem_payload || jsonb_build_object('already_processed',true);
    END IF;
    RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_IDEMPOTENCY_IN_PROGRESS';
  END IF;
  SELECT veh.* INTO v_vehicle FROM public.vehicles veh WHERE veh.public_id=v_vehicle_public_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_VEHICLE_NOT_FOUND'; END IF;
  IF NOT v_vehicle.is_active THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_VEHICLE_INACTIVE'; END IF;
  SELECT dva.* INTO v_authorization FROM public.driver_vehicle_authorizations dva
  WHERE dva.driver_profile_id=v_driver.id AND dva.vehicle_id=v_vehicle.id AND dva.is_active=true AND dva.valid_from<=now() AND (dva.valid_until IS NULL OR dva.valid_until>=now()) FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_VEHICLE_UNAUTHORIZED'; END IF;
  IF EXISTS(SELECT 1 FROM public.route_assignments ra WHERE ra.driver_profile_id=v_driver.id AND ra.state IN ('ASSIGNED','IN_PROGRESS')) THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_DRIVER_ALREADY_ASSIGNED'; END IF;
  IF EXISTS(SELECT 1 FROM public.route_assignments ra WHERE ra.vehicle_id=v_vehicle.id AND ra.state IN ('ASSIGNED','IN_PROGRESS')) THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_VEHICLE_ALREADY_ASSIGNED'; END IF;
  SELECT ro.* INTO v_route FROM public.route_opportunities ro WHERE ro.public_id=v_route_public_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_ROUTE_NOT_FOUND'; END IF;
  IF v_route.state<>'OPEN' THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_ROUTE_ALREADY_ASSIGNED'; END IF;
  IF EXISTS(SELECT 1 FROM public.route_assignments ra WHERE ra.route_id=v_route.id AND ra.state IN ('ASSIGNED','IN_PROGRESS')) THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_ROUTE_ALREADY_ASSIGNED'; END IF;
  IF upper(btrim(v_route.required_role))<>v_driver.profile_type THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_ROUTE_ROLE_MISMATCH'; END IF;
  IF v_driver.territory_id IS NULL OR v_driver.territory_id<>v_route.territory_id THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_ROUTE_TERRITORY_FORBIDDEN'; END IF;
  SELECT count(*) INTO v_manifest_count FROM public.route_packages rp WHERE rp.route_id=v_route.id;
  IF v_manifest_count<1 THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_ROUTE_EMPTY'; END IF;
  FOR v_pkg IN
    SELECT pkg.id,pkg.public_id,pkg.current_custodian_id,pkg.state,pkg.version,pkg.weight_kg,pkg.volume_m3,pkg.requires_cold_chain,pkg.requires_fragile_handling,
           origin.public_id AS origin_public_id,origin.profile_type AS origin_profile_type,origin.status AS origin_status
    FROM public.route_packages rp JOIN public.packages pkg ON pkg.id=rp.package_id JOIN public.profiles origin ON origin.id=pkg.current_custodian_id
    WHERE rp.route_id=v_route.id ORDER BY pkg.id FOR UPDATE OF pkg
  LOOP
    v_locked_count:=v_locked_count+1;
    IF v_pkg.origin_status<>'active' THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_PACKAGE_ORIGIN_INACTIVE'; END IF;
    IF v_pkg.origin_profile_type NOT IN ('TIE','VEN','PTC') THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_ROUTE_ORIGIN_TYPE_UNSUPPORTED'; END IF;
    IF (v_pkg.origin_profile_type IN ('TIE','VEN') AND v_pkg.state NOT IN ('CREATED','READY')) OR (v_pkg.origin_profile_type='PTC' AND v_pkg.state NOT IN ('AT_PTC','READY')) THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_PACKAGE_INVALID_STATE'; END IF;
    IF EXISTS(SELECT 1 FROM public.route_packages rp2 JOIN public.route_opportunities ro2 ON ro2.id=rp2.route_id WHERE rp2.package_id=v_pkg.id AND rp2.route_id<>v_route.id AND ro2.state IN ('ASSIGNED','IN_PROGRESS')) THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_PACKAGE_ALREADY_ROUTED'; END IF;
    IF EXISTS(SELECT 1 FROM public.movement_packages mp JOIN public.movements mov ON mov.id=mp.movement_id WHERE mp.package_id=v_pkg.id AND mov.route_id IS DISTINCT FROM v_route.id AND mov.state IN ('PLANNED','ASSIGNED','READY','TRANSFER_PENDING','IN_TRANSIT','ARRIVED')) THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_PACKAGE_ALREADY_ROUTED'; END IF;
    v_total_weight:=v_total_weight+coalesce(v_pkg.weight_kg,0);
    v_total_volume:=v_total_volume+coalesce(v_pkg.volume_m3,0);
    v_requires_cold:=v_requires_cold OR coalesce(v_pkg.requires_cold_chain,false);
    v_requires_fragile:=v_requires_fragile OR coalesce(v_pkg.requires_fragile_handling,false);
  END LOOP;
  IF v_locked_count<>v_manifest_count THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_ROUTE_MANIFEST_INVALID'; END IF;
  IF v_total_weight>v_vehicle.max_weight_kg THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_MAX_WEIGHT_EXCEEDED'; END IF;
  IF v_total_volume>v_vehicle.max_volume_m3 THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_MAX_VOLUME_EXCEEDED'; END IF;
  IF v_vehicle.max_packages IS NOT NULL AND v_manifest_count>v_vehicle.max_packages THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_MAX_PACKAGES_EXCEEDED'; END IF;
  IF v_requires_cold AND NOT v_vehicle.supports_cold_chain THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_COLD_CHAIN_REQUIRED'; END IF;
  IF v_requires_fragile AND NOT v_vehicle.supports_fragile THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_FRAGILE_HANDLING_REQUIRED'; END IF;
  INSERT INTO public.route_assignments(route_id,driver_profile_id,vehicle_id,state,version,idempotency_key)
  VALUES(v_route.id,v_driver.id,v_vehicle.id,'ASSIGNED',0,v_idempotency_key)
  RETURNING id,public_id INTO v_assignment_id,v_assignment_public_id;
  UPDATE public.route_opportunities SET state='ASSIGNED',version=version+1,total_weight_kg=v_total_weight,total_volume_m3=v_total_volume,package_count=v_manifest_count,requires_cold_chain=v_requires_cold,requires_fragile_handling=v_requires_fragile
  WHERE id=v_route.id AND state='OPEN';
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated<>1 THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_ROUTE_ALREADY_ASSIGNED'; END IF;
  FOR v_origin IN
    SELECT origin.id AS origin_profile_id,origin.public_id AS origin_public_id,origin.profile_type AS origin_profile_type,array_agg(pkg.public_id ORDER BY pkg.id) AS package_public_ids
    FROM public.route_packages rp JOIN public.packages pkg ON pkg.id=rp.package_id JOIN public.profiles origin ON origin.id=pkg.current_custodian_id
    WHERE rp.route_id=v_route.id GROUP BY origin.id,origin.public_id,origin.profile_type ORDER BY origin.id
  LOOP
    v_sequence:=v_sequence+1;
    v_movement_public_id:=public.tc_create_planned_movement(v_assignment_public_id,v_origin.origin_public_id,v_driver.public_id,CASE WHEN v_origin.origin_profile_type IN ('TIE','VEN') THEN 'STORE_TO_DRIVER' WHEN v_origin.origin_profile_type='PTC' THEN 'PTC_TO_DRIVER' ELSE NULL END,v_origin.package_public_ids,v_sequence);
    IF v_movement_public_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_MOVEMENT_CREATION_FAILED'; END IF;
    v_movement_public_ids:=v_movement_public_ids || jsonb_build_array(v_movement_public_id);
  END LOOP;
  IF v_sequence<1 THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_ROUTE_EMPTY'; END IF;
  v_response:=jsonb_build_object('success',true,'status','ASSIGNED','assignment_public_id',v_assignment_public_id,'route_public_id',v_route.public_id,'driver_profile_public_id',v_driver.public_id,'vehicle_public_id',v_vehicle.public_id,'movement_public_ids',v_movement_public_ids,'movement_count',v_sequence,'package_count',v_manifest_count,'total_weight_kg',v_total_weight,'total_volume_m3',v_total_volume,'requires_cold_chain',v_requires_cold,'requires_fragile_handling',v_requires_fragile,'already_processed',false);
  INSERT INTO public.audit_logs(actor_person_id,actor_profile_id,operation,entity_type,entity_public_id,before_version,after_version,result,metadata)
  VALUES(v_person_id,v_driver.id,'ASSIGN_DRIVER_ROUTE','ROUTE',v_route.public_id,v_route.version,v_route.version+1,'ASSIGNED',jsonb_build_object('assignment_public_id',v_assignment_public_id,'vehicle_public_id',v_vehicle.public_id,'movement_public_ids',v_movement_public_ids,'movement_count',v_sequence,'package_count',v_manifest_count,'total_weight_kg',v_total_weight,'total_volume_m3',v_total_volume,'requires_cold_chain',v_requires_cold,'requires_fragile_handling',v_requires_fragile,'idempotency_key',v_idempotency_key));
  UPDATE public.idempotency_records SET status='COMPLETED',response_payload=v_response,completed_at=now()
  WHERE operation_type='ASSIGN_DRIVER_ROUTE' AND idempotency_key=v_idempotency_key AND person_id=v_person_id AND request_hash=v_request_hash;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated<>1 THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_IDEMPOTENCY_STATE_INVALID'; END IF;
  RETURN v_response;
END;
$$;
REVOKE ALL ON FUNCTION public.assign_driver_route(text,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.assign_driver_route(text,text,text,text) TO authenticated;
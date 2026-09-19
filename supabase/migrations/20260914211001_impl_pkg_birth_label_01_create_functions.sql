CREATE OR REPLACE FUNCTION public.tc_start_preparation(
  p_allocation_public_id text,
  p_idempotency_key text,
  p_event_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_auth_user_id uuid;
  v_person_id uuid;
  v_actor_profile_id uuid;
  v_alloc public.order_sourcing_allocations%ROWTYPE;
  v_oi public.order_items%ROWTYPE;
  v_res public.inventory_reservations%ROWTYPE;
  v_pkg public.packages%ROWTYPE;
  v_alloc_public_id text;
  v_idem_key text;
  v_event text;
  v_request_hash text;
  v_idem_inserted integer := 0;
  v_idem_person_id uuid;
  v_idem_hash text;
  v_idem_status text;
  v_idem_payload jsonb;
  v_remaining bigint;
  v_legacy_empty_count integer;
  v_legacy_pkg_id uuid;
  v_reused boolean := false;
  v_content_id uuid;
  v_existing_content public.package_contents%ROWTYPE;
  v_result jsonb;
BEGIN
  v_auth_user_id := auth.uid();
  IF v_auth_user_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_UNAUTHENTICATED';
  END IF;

  v_alloc_public_id := upper(btrim(coalesce(p_allocation_public_id, '')));
  v_idem_key := btrim(coalesce(p_idempotency_key, ''));
  v_event := btrim(coalesce(p_event_id, ''));
  IF v_alloc_public_id = '' OR v_idem_key = '' OR v_event = '' THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_INVALID_ARGUMENT';
  END IF;

  SELECT per.id INTO v_person_id
  FROM public.persons per
  WHERE per.auth_user_id = v_auth_user_id
  LIMIT 1;
  IF v_person_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_UNAUTHENTICATED';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('START_PREP:' || v_idem_key));

  v_request_hash := encode(
    digest(
      convert_to('START_PREPARATION|' || v_alloc_public_id || '|' || v_idem_key, 'UTF8'),
      'sha256'
    ),
    'hex'
  );

  INSERT INTO public.idempotency_records (
    operation_type, idempotency_key, person_id, request_hash, status
  ) VALUES (
    'START_PREPARATION', v_idem_key, v_person_id, v_request_hash, 'PROCESSING'
  )
  ON CONFLICT (operation_type, idempotency_key) DO NOTHING;
  GET DIAGNOSTICS v_idem_inserted = ROW_COUNT;

  IF v_idem_inserted = 0 THEN
    SELECT person_id, request_hash, status, response_payload
    INTO v_idem_person_id, v_idem_hash, v_idem_status, v_idem_payload
    FROM public.idempotency_records
    WHERE operation_type = 'START_PREPARATION'
      AND idempotency_key = v_idem_key
    FOR UPDATE;

    IF v_idem_person_id IS NULL THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_IDEMPOTENCY_STATE_INVALID';
    END IF;
    IF v_idem_person_id <> v_person_id OR v_idem_hash <> v_request_hash THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_IDEMPOTENCY_KEY_REUSED';
    END IF;
    IF v_idem_status = 'COMPLETED' THEN
      IF v_idem_payload IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_IDEMPOTENCY_STATE_INVALID';
      END IF;
      RETURN v_idem_payload;
    END IF;
    IF v_idem_status = 'PROCESSING' THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_IDEMPOTENCY_IN_PROGRESS';
    END IF;
  END IF;

  SELECT * INTO v_alloc
  FROM public.order_sourcing_allocations
  WHERE public_id = v_alloc_public_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_NOT_FOUND';
  END IF;

  IF v_alloc.state IS DISTINCT FROM 'ACTIVE' THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_ALLOCATION_NOT_ACTIVE';
  END IF;

  v_remaining := v_alloc.qty_allocated - v_alloc.qty_fulfilled - v_alloc.qty_released;
  IF v_remaining <= 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_NO_REMAINING';
  END IF;

  IF v_alloc.order_item_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_INVALID_ARGUMENT';
  END IF;

  IF v_alloc.sub_order_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_INVALID_ARGUMENT';
  END IF;

  SELECT pr.id INTO v_actor_profile_id
  FROM public.profiles pr
  WHERE pr.person_id = v_person_id
    AND pr.id = v_alloc.store_profile_id
    AND pr.profile_type IN ('TIE', 'VEN')
    AND pr.status = 'active'
  LIMIT 1;

  IF v_actor_profile_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_FORBIDDEN';
  END IF;

  SELECT * INTO v_oi
  FROM public.order_items
  WHERE id = v_alloc.order_item_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_NOT_FOUND';
  END IF;

  IF v_oi.sub_order_id IS DISTINCT FROM v_alloc.sub_order_id THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_STORE_MISMATCH';
  END IF;

  IF v_oi.listing_id IS DISTINCT FROM v_alloc.listing_id THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_LISTING_MISMATCH';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.sub_orders so
    WHERE so.id = v_alloc.sub_order_id
      AND so.store_profile_id = v_alloc.store_profile_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_STORE_MISMATCH';
  END IF;

  SELECT * INTO v_res
  FROM public.inventory_reservations
  WHERE order_item_id = v_oi.id
  FOR UPDATE;

  IF NOT FOUND OR v_res.status IS DISTINCT FROM 'RESERVED' THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_RESERVATION_REQUIRED';
  END IF;

  IF v_res.quantity IS DISTINCT FROM v_oi.quantity THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_RESERVATION_REQUIRED';
  END IF;

  SELECT pc.* INTO v_existing_content
  FROM public.package_contents pc
  JOIN public.packages pkg ON pkg.id = pc.package_id
  WHERE pc.order_item_id = v_oi.id
    AND pkg.sub_order_id = v_alloc.sub_order_id
    AND pkg.state = 'CREATED'
    AND pc.quantity = v_oi.quantity
  ORDER BY pc.created_at
  LIMIT 1;

  IF FOUND THEN
    SELECT * INTO v_pkg FROM public.packages WHERE id = v_existing_content.package_id;
    v_reused := true;
    v_result := jsonb_build_object(
      'success', true,
      'disposition', 'IDEMPOTENT',
      'package_id', v_pkg.id,
      'package_public_id', v_pkg.public_id,
      'package_state', 'CREATED',
      'content_ids', jsonb_build_array(v_existing_content.id),
      'allocation_public_id', v_alloc.public_id,
      'order_item_id', v_oi.id,
      'sub_order_id', v_alloc.sub_order_id,
      'inventory_reservation_id', v_res.id,
      'reused', true
    );

    UPDATE public.idempotency_records
    SET status = 'COMPLETED',
        response_payload = v_result,
        completed_at = now()
    WHERE operation_type = 'START_PREPARATION'
      AND idempotency_key = v_idem_key
      AND person_id = v_person_id
      AND request_hash = v_request_hash;

    RETURN v_result;
  END IF;

  PERFORM 1 FROM public.packages
  WHERE sub_order_id = v_alloc.sub_order_id
  FOR UPDATE;

  SELECT count(*)::int INTO v_legacy_empty_count
  FROM public.packages pkg
  WHERE pkg.sub_order_id = v_alloc.sub_order_id
    AND pkg.state = 'CREATED'
    AND NOT EXISTS (
      SELECT 1 FROM public.package_contents pc WHERE pc.package_id = pkg.id
    );

  IF v_legacy_empty_count > 1 THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_LEGACY_PACKAGE_AMBIGUOUS';
  END IF;

  IF v_legacy_empty_count = 1 THEN
    SELECT pkg.id INTO v_legacy_pkg_id
    FROM public.packages pkg
    WHERE pkg.sub_order_id = v_alloc.sub_order_id
      AND pkg.state = 'CREATED'
      AND NOT EXISTS (
        SELECT 1 FROM public.package_contents pc WHERE pc.package_id = pkg.id
      )
    LIMIT 1;

    SELECT * INTO v_pkg FROM public.packages WHERE id = v_legacy_pkg_id;
    v_reused := true;
  ELSE
    INSERT INTO public.packages (
      sub_order_id,
      current_custodian_id,
      state
    ) VALUES (
      v_alloc.sub_order_id,
      v_alloc.store_profile_id,
      'CREATED'
    )
    RETURNING * INTO v_pkg;
    v_reused := false;
  END IF;

  IF v_pkg.state IS DISTINCT FROM 'CREATED' THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_INVALID_PACKAGE_STATE';
  END IF;

  INSERT INTO public.package_contents (
    package_id,
    order_item_id,
    quantity
  ) VALUES (
    v_pkg.id,
    v_oi.id,
    v_oi.quantity
  )
  RETURNING id INTO v_content_id;

  INSERT INTO public.audit_logs (
    actor_person_id,
    actor_profile_id,
    operation,
    entity_type,
    entity_public_id,
    event_id,
    result,
    metadata
  ) VALUES (
    v_person_id,
    v_actor_profile_id,
    'START_PREPARATION',
    'PACKAGE',
    v_pkg.public_id,
    NULL,
    'APPLIED',
    jsonb_build_object(
      'event_id', v_event,
      'allocation_id', v_alloc.id,
      'allocation_public_id', v_alloc.public_id,
      'package_id', v_pkg.id,
      'package_public_id', v_pkg.public_id,
      'order_item_id', v_oi.id,
      'content_ids', jsonb_build_array(v_content_id),
      'inventory_reservation_id', v_res.id,
      'reused', v_reused,
      'idempotency_key', v_idem_key
    )
  );

  v_result := jsonb_build_object(
    'success', true,
    'disposition', 'APPLIED',
    'package_id', v_pkg.id,
    'package_public_id', v_pkg.public_id,
    'package_state', 'CREATED',
    'content_ids', jsonb_build_array(v_content_id),
    'allocation_public_id', v_alloc.public_id,
    'order_item_id', v_oi.id,
    'sub_order_id', v_alloc.sub_order_id,
    'inventory_reservation_id', v_res.id,
    'reused', v_reused
  );

  UPDATE public.idempotency_records
  SET status = 'COMPLETED',
      response_payload = v_result,
      completed_at = now()
  WHERE operation_type = 'START_PREPARATION'
    AND idempotency_key = v_idem_key
    AND person_id = v_person_id
    AND request_hash = v_request_hash;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.tc_start_preparation(text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.tc_start_preparation(text, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.tc_start_preparation(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.tc_start_preparation(text, text, text) TO service_role;
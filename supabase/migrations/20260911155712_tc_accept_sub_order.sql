CREATE OR REPLACE FUNCTION public.tc_accept_sub_order(
  p_sub_order_public_id text,
  p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_auth_user_id uuid;
  v_person_id uuid;
  v_actor_profile_id uuid;
  v_sub public.sub_orders%ROWTYPE;
  v_sub_public_id text;
  v_idem_key text;
  v_request_hash text;
  v_idem_inserted integer := 0;
  v_idem_person_id uuid;
  v_idem_hash text;
  v_idem_status text;
  v_idem_payload jsonb;
  v_updated integer;
  v_bad_res integer;
  v_pkg_count integer;
  v_bad_pkg integer;
  v_bad_custodian integer;
  v_active_mov integer;
  v_order_state_before text;
  v_result jsonb;
  v_already_accepted boolean := false;
BEGIN
  v_auth_user_id := auth.uid();
  IF v_auth_user_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_UNAUTHENTICATED';
  END IF;

  v_sub_public_id := upper(btrim(coalesce(p_sub_order_public_id, '')));
  v_idem_key := btrim(coalesce(p_idempotency_key, ''));
  IF v_sub_public_id = '' OR v_idem_key = '' THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_INVALID_ARGUMENT';
  END IF;

  SELECT per.id INTO v_person_id
  FROM public.persons per
  WHERE per.auth_user_id = v_auth_user_id
  LIMIT 1;
  IF v_person_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_UNAUTHENTICATED';
  END IF;

  v_request_hash := encode(
    digest(
      'ACCEPT_SUB_ORDER|' || v_sub_public_id || '|' || v_idem_key,
      'sha256'
    ),
    'hex'
  );

  INSERT INTO public.idempotency_records (
    operation_type, idempotency_key, person_id, request_hash, status
  ) VALUES (
    'ACCEPT_SUB_ORDER', v_idem_key, v_person_id, v_request_hash, 'PROCESSING'
  )
  ON CONFLICT (operation_type, idempotency_key) DO NOTHING;
  GET DIAGNOSTICS v_idem_inserted = ROW_COUNT;

  IF v_idem_inserted = 0 THEN
    SELECT person_id, request_hash, status, response_payload
    INTO v_idem_person_id, v_idem_hash, v_idem_status, v_idem_payload
    FROM public.idempotency_records
    WHERE operation_type = 'ACCEPT_SUB_ORDER'
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

  SELECT * INTO v_sub
  FROM public.sub_orders
  WHERE public_id = v_sub_public_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_SUB_ORDER_NOT_FOUND';
  END IF;

  SELECT pr.id INTO v_actor_profile_id
  FROM public.profiles pr
  WHERE pr.person_id = v_person_id
    AND pr.id = v_sub.store_profile_id
    AND pr.profile_type IN ('TIE', 'VEN')
    AND pr.status = 'active'
  LIMIT 1;

  IF v_actor_profile_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_FORBIDDEN_SUB_ORDER';
  END IF;

  SELECT o.state INTO v_order_state_before
  FROM public.orders o
  WHERE o.id = v_sub.order_id;

  IF v_sub.state = 'ACCEPTED' THEN
    v_already_accepted := true;
  ELSIF v_sub.state <> 'CREATED' THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_INVALID_SUB_ORDER_STATE';
  ELSE
    SELECT count(*)::int INTO v_bad_res
    FROM public.order_items oi
    LEFT JOIN public.inventory_reservations ir ON ir.order_item_id = oi.id
    WHERE oi.sub_order_id = v_sub.id
      AND (ir.id IS NULL OR ir.status IS DISTINCT FROM 'RESERVED');

    IF v_bad_res > 0 THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_RESERVATION_NOT_RESERVED';
    END IF;

    SELECT count(*)::int INTO v_pkg_count
    FROM public.packages pkg
    WHERE pkg.sub_order_id = v_sub.id;

    IF v_pkg_count < 1 THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_PACKAGE_REQUIRED';
    END IF;

    SELECT count(*)::int INTO v_bad_pkg
    FROM public.packages pkg
    WHERE pkg.sub_order_id = v_sub.id
      AND pkg.state IS DISTINCT FROM 'CREATED';

    IF v_bad_pkg > 0 THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_PACKAGE_NOT_CREATED';
    END IF;

    SELECT count(*)::int INTO v_bad_custodian
    FROM public.packages pkg
    WHERE pkg.sub_order_id = v_sub.id
      AND pkg.current_custodian_id IS DISTINCT FROM v_sub.store_profile_id;

    IF v_bad_custodian > 0 THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_PACKAGE_CUSTODIAN_MISMATCH';
    END IF;

    SELECT count(*)::int INTO v_active_mov
    FROM public.packages pkg
    JOIN public.movement_packages mp ON mp.package_id = pkg.id
    JOIN public.movements m ON m.id = mp.movement_id
    WHERE pkg.sub_order_id = v_sub.id
      AND m.state IN (
        'PLANNED', 'ASSIGNED', 'READY', 'IN_TRANSIT', 'ARRIVED', 'TRANSFER_PENDING'
      );

    IF v_active_mov > 0 THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_ACTIVE_MOVEMENT_EXISTS';
    END IF;

    UPDATE public.sub_orders
    SET state = 'ACCEPTED',
        updated_at = now()
    WHERE id = v_sub.id
      AND state = 'CREATED';

    GET DIAGNOSTICS v_updated = ROW_COUNT;
    IF v_updated <> 1 THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_ACCEPT_RACE';
    END IF;

    INSERT INTO public.audit_logs (
      actor_person_id,
      actor_profile_id,
      operation,
      entity_type,
      entity_public_id,
      result,
      metadata
    ) VALUES (
      v_person_id,
      v_actor_profile_id,
      'ACCEPT_SUB_ORDER',
      'SUB_ORDER',
      v_sub.public_id,
      'COMPLETED',
      jsonb_build_object(
        'from_state', 'CREATED',
        'to_state', 'ACCEPTED',
        'idempotency_key', v_idem_key
      )
    );
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.orders o
    WHERE o.id = v_sub.order_id
      AND o.state IS DISTINCT FROM v_order_state_before
  ) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_ORDER_MUTATION_FORBIDDEN';
  END IF;

  v_result := jsonb_build_object(
    'success', true,
    'disposition', CASE WHEN v_already_accepted THEN 'IDEMPOTENT' ELSE 'APPLIED' END,
    'sub_order_public_id', v_sub.public_id,
    'state', 'ACCEPTED',
    'already_accepted', v_already_accepted
  );

  UPDATE public.idempotency_records
  SET status = 'COMPLETED',
      response_payload = v_result,
      completed_at = now()
  WHERE operation_type = 'ACCEPT_SUB_ORDER'
    AND idempotency_key = v_idem_key
    AND person_id = v_person_id
    AND request_hash = v_request_hash;

  RETURN v_result;
END;
$fn$;

REVOKE ALL ON FUNCTION public.tc_accept_sub_order(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.tc_accept_sub_order(text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.tc_accept_sub_order(text, text) TO authenticated;
CREATE OR REPLACE FUNCTION public.tc_inv_release(
  p_reservation_id uuid,
  p_reason_code text,
  p_event_id text,
  p_occurred_at timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $fn$
DECLARE
  v_res public.inventory_reservations%ROWTYPE;
  v_inv public.inventory%ROWTYPE;
  v_reason text;
  v_event text;
  v_occurred timestamptz;
  v_before_reserved bigint;
BEGIN
  v_reason := upper(btrim(coalesce(p_reason_code, '')));
  v_event := btrim(coalesce(p_event_id, ''));
  IF p_reservation_id IS NULL OR v_reason = '' OR v_event = '' THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_INVALID_ARGUMENT';
  END IF;
  IF v_reason NOT IN (
    'FALLBACK', 'CANCEL', 'REJECT_EXCEPTION', 'MANUAL_ADJUST', 'OTHER'
  ) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_INVALID_REASON_CODE';
  END IF;

  v_occurred := coalesce(p_occurred_at, now());

  SELECT * INTO v_res
  FROM public.inventory_reservations
  WHERE id = p_reservation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_RESERVATION_NOT_FOUND';
  END IF;

  IF v_res.status = 'RELEASED' THEN
    SELECT * INTO v_inv FROM public.inventory WHERE id = v_res.inventory_id;
    RETURN jsonb_build_object(
      'success', true,
      'disposition', 'IDEMPOTENT',
      'reservation_status', 'RELEASED',
      'quantity_released', v_res.quantity,
      'inventory_version', v_inv.version
    );
  END IF;

  IF v_res.status = 'CONSUMED' THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_RESERVATION_ALREADY_CONSUMED';
  END IF;
  IF v_res.status = 'EXPIRED' THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_RESERVATION_ALREADY_EXPIRED';
  END IF;
  IF v_res.status IS DISTINCT FROM 'RESERVED' THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_INVALID_RESERVATION_STATE';
  END IF;

  SELECT * INTO v_inv
  FROM public.inventory
  WHERE id = v_res.inventory_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_INVENTORY_NOT_FOUND';
  END IF;

  v_before_reserved := v_inv.quantity_reserved;
  IF v_before_reserved < v_res.quantity THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_DATA_INCONSISTENCY';
  END IF;

  UPDATE public.inventory
  SET quantity_reserved = quantity_reserved - v_res.quantity,
      version = version + 1,
      updated_at = now()
  WHERE id = v_inv.id;

  UPDATE public.inventory_reservations
  SET status = 'RELEASED',
      released_at = v_occurred
  WHERE id = v_res.id
    AND status = 'RESERVED';

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_RELEASE_RACE';
  END IF;

  SELECT * INTO v_inv FROM public.inventory WHERE id = v_inv.id;

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
    NULL,
    NULL,
    'INVENTORY_RESERVATION_RELEASE',
    'INVENTORY_RESERVATION',
    NULL,
    v_event,
    'APPLIED',
    jsonb_build_object(
      'reservation_id', v_res.id,
      'inventory_id', v_res.inventory_id,
      'quantity', v_res.quantity,
      'from_status', 'RESERVED',
      'to_status', 'RELEASED',
      'reason_code', v_reason,
      'event_id', v_event,
      'reserved_before', v_before_reserved,
      'reserved_after', v_inv.quantity_reserved,
      'inventory_version', v_inv.version
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'disposition', 'APPLIED',
    'reservation_status', 'RELEASED',
    'quantity_released', v_res.quantity,
    'inventory_version', v_inv.version
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.tc_inv_release(uuid, text, text, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.tc_inv_release(uuid, text, text, timestamptz) FROM anon;
REVOKE ALL ON FUNCTION public.tc_inv_release(uuid, text, text, timestamptz) FROM authenticated;
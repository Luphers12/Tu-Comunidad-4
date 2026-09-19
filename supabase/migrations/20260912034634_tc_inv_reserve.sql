CREATE OR REPLACE FUNCTION public.tc_inv_reserve(
  p_inventory_id uuid,
  p_order_item_id uuid,
  p_quantity bigint,
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
  v_inv public.inventory%ROWTYPE;
  v_item public.order_items%ROWTYPE;
  v_res public.inventory_reservations%ROWTYPE;
  v_reason text;
  v_event text;
  v_occurred timestamptz;
  v_available bigint;
  v_available_after bigint;
BEGIN
  v_reason := upper(btrim(coalesce(p_reason_code, '')));
  v_event := btrim(coalesce(p_event_id, ''));

  IF p_inventory_id IS NULL OR p_order_item_id IS NULL OR v_reason = '' OR v_event = '' THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_INVALID_ARGUMENT';
  END IF;
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_INVALID_QUANTITY';
  END IF;

  v_occurred := coalesce(p_occurred_at, now());

  -- Lock order of consistency: order_item then inventory (match listing check before inv write)
  SELECT * INTO v_item
  FROM public.order_items
  WHERE id = p_order_item_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_ORDER_ITEM_NOT_FOUND';
  END IF;

  -- Existing reservation for this order_item (UNIQUE)
  SELECT * INTO v_res
  FROM public.inventory_reservations
  WHERE order_item_id = p_order_item_id
  FOR UPDATE;

  IF FOUND THEN
    IF v_res.status IN ('RELEASED', 'EXPIRED', 'CONSUMED') THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_RESERVATION_TERMINAL';
    END IF;
    IF v_res.status = 'RESERVED'
       AND v_res.inventory_id = p_inventory_id
       AND v_res.quantity = p_quantity THEN
      SELECT * INTO v_inv FROM public.inventory WHERE id = v_res.inventory_id;
      v_available_after := v_inv.quantity_committed - v_inv.quantity_reserved - v_inv.quantity_consumed;
      RETURN jsonb_build_object(
        'success', true,
        'disposition', 'IDEMPOTENT',
        'reservation_id', v_res.id,
        'reservation_status', 'RESERVED',
        'quantity_reserved', v_res.quantity,
        'inventory_version', v_inv.version,
        'available_after', v_available_after
      );
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_RESERVATION_CONFLICT';
  END IF;

  SELECT * INTO v_inv
  FROM public.inventory
  WHERE id = p_inventory_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_INVENTORY_NOT_FOUND';
  END IF;

  IF v_inv.listing_id IS DISTINCT FROM v_item.listing_id THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_LISTING_MISMATCH';
  END IF;

  v_available := v_inv.quantity_committed - v_inv.quantity_reserved - v_inv.quantity_consumed;
  IF v_available < p_quantity THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_INSUFFICIENT_AVAILABLE';
  END IF;

  UPDATE public.inventory
  SET quantity_reserved = quantity_reserved + p_quantity,
      version = version + 1,
      updated_at = now()
  WHERE id = v_inv.id;

  INSERT INTO public.inventory_reservations (
    inventory_id,
    order_item_id,
    quantity,
    status,
    reserved_at
  ) VALUES (
    p_inventory_id,
    p_order_item_id,
    p_quantity,
    'RESERVED',
    v_occurred
  )
  RETURNING * INTO v_res;

  SELECT * INTO v_inv FROM public.inventory WHERE id = v_inv.id;
  v_available_after := v_inv.quantity_committed - v_inv.quantity_reserved - v_inv.quantity_consumed;

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
    'INVENTORY_RESERVATION_CREATE',
    'INVENTORY_RESERVATION',
    NULL,
    NULL,
    'APPLIED',
    jsonb_build_object(
      'reservation_id', v_res.id,
      'inventory_id', v_inv.id,
      'order_item_id', p_order_item_id,
      'quantity', p_quantity,
      'reason_code', v_reason,
      'event_id', v_event,
      'status', 'RESERVED',
      'available_after', v_available_after,
      'inventory_version', v_inv.version
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'disposition', 'APPLIED',
    'reservation_id', v_res.id,
    'reservation_status', 'RESERVED',
    'quantity_reserved', v_res.quantity,
    'inventory_version', v_inv.version,
    'available_after', v_available_after
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.tc_inv_reserve(uuid, uuid, bigint, text, text, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.tc_inv_reserve(uuid, uuid, bigint, text, text, timestamptz) FROM anon;
REVOKE ALL ON FUNCTION public.tc_inv_reserve(uuid, uuid, bigint, text, text, timestamptz) FROM authenticated;
CREATE OR REPLACE FUNCTION public.tc_source_allocate_reserve(
  p_demand_public_id text,
  p_plan jsonb,
  p_event_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $fn$
DECLARE
  v_demand public.order_demand_items%ROWTYPE;
  v_event text;
  v_plan_hash text;
  v_canonical_plan jsonb;
  v_prior jsonb;
  v_prior_hash text;
  v_remaining bigint;
  v_outstanding bigint;
  v_plan_total bigint;
  v_line jsonb;
  v_listing_rec public.store_listings%ROWTYPE;
  v_inv public.inventory%ROWTYPE;
  v_inv_ids uuid[];
  v_inv_id uuid;
  v_available bigint;
  v_sub_id uuid;
  v_order_item_id uuid;
  v_alloc public.order_sourcing_allocations%ROWTYPE;
  v_res jsonb;
  v_alloc_ids uuid[] := ARRAY[]::uuid[];
  v_item_ids uuid[] := ARRAY[]::uuid[];
  v_res_ids uuid[] := ARRAY[]::uuid[];
  v_sub_ids uuid[] := ARRAY[]::uuid[];
  v_i int;
  v_n int;
  v_line_store uuid;
  v_line_listing uuid;
  v_line_qty bigint;
  v_unit_price bigint;
BEGIN
  v_event := btrim(coalesce(p_event_id, ''));
  IF btrim(coalesce(p_demand_public_id, '')) = '' OR v_event = '' OR p_plan IS NULL OR jsonb_typeof(p_plan) <> 'array' OR jsonb_array_length(p_plan) < 1 THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_INVALID_ARGUMENT';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('SOURCE_ALLOCATE:' || v_event, 0));

  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.store_profile_id::text, x.listing_id::text), '[]'::jsonb)
  INTO v_canonical_plan
  FROM (
    SELECT
      (coalesce(e->>'store_profile_id', e->>'store'))::uuid AS store_profile_id,
      (coalesce(e->>'listing_id', e->>'listing'))::uuid AS listing_id,
      (e->>'quantity')::bigint AS quantity
    FROM jsonb_array_elements(p_plan) e
  ) x;

  IF v_canonical_plan IS NULL OR jsonb_array_length(v_canonical_plan) < 1 THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_INVALID_PLAN';
  END IF;

  v_plan_hash := encode(digest(v_canonical_plan::text, 'sha256'), 'hex');

  SELECT metadata INTO v_prior
  FROM public.audit_logs
  WHERE operation = 'SOURCE_ALLOCATE_RESERVE'
    AND result = 'APPLIED'
    AND metadata->>'event_id' = v_event
  ORDER BY created_at DESC
  LIMIT 1;

  IF FOUND THEN
    v_prior_hash := v_prior->>'plan_hash';
    IF v_prior_hash IS NOT DISTINCT FROM v_plan_hash THEN
      RETURN jsonb_build_object(
        'success', true,
        'disposition', 'IDEMPOTENT',
        'event_id', v_event,
        'demand_public_id', p_demand_public_id,
        'plan_hash', v_plan_hash,
        'allocation_ids', coalesce(v_prior->'allocation_ids', '[]'::jsonb),
        'order_item_ids', coalesce(v_prior->'order_item_ids', '[]'::jsonb),
        'reservation_ids', coalesce(v_prior->'reservation_ids', '[]'::jsonb),
        'sub_order_ids', coalesce(v_prior->'sub_order_ids', '[]'::jsonb)
      );
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_IDEMPOTENCY_CONFLICT';
  END IF;

  SELECT * INTO v_demand
  FROM public.order_demand_items
  WHERE public_id = btrim(p_demand_public_id)
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_DEMAND_NOT_FOUND';
  END IF;

  IF v_demand.state NOT IN ('OPEN', 'PARTIALLY_FULFILLED') THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_INVALID_DEMAND_STATE';
  END IF;

  SELECT coalesce(sum(a.qty_allocated - a.qty_fulfilled - a.qty_released), 0)::bigint
  INTO v_outstanding
  FROM public.order_sourcing_allocations a
  WHERE a.demand_item_id = v_demand.id
    AND a.state = 'ACTIVE';

  v_remaining := v_demand.quantity_requested - v_demand.quantity_fulfilled - v_outstanding;
  IF v_remaining <= 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_DEMAND_NO_REMAINING';
  END IF;

  v_plan_total := 0;
  v_n := jsonb_array_length(v_canonical_plan);
  v_inv_ids := ARRAY[]::uuid[];

  FOR v_i IN 0 .. v_n - 1 LOOP
    v_line := v_canonical_plan->v_i;
    v_line_store := (v_line->>'store_profile_id')::uuid;
    v_line_listing := (v_line->>'listing_id')::uuid;
    v_line_qty := (v_line->>'quantity')::bigint;

    IF v_line_store IS NULL OR v_line_listing IS NULL OR v_line_qty IS NULL OR v_line_qty <= 0 THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_INVALID_PLAN_LINE';
    END IF;

    SELECT * INTO v_listing_rec FROM public.store_listings WHERE id = v_line_listing;
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_LISTING_NOT_FOUND';
    END IF;
    IF v_listing_rec.store_profile_id IS DISTINCT FROM v_line_store THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_STORE_LISTING_MISMATCH';
    END IF;
    IF v_listing_rec.variant_id IS DISTINCT FROM v_demand.variant_id THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_VARIANT_MISMATCH';
    END IF;
    IF v_listing_rec.is_active IS NOT TRUE THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_LISTING_INACTIVE';
    END IF;

    SELECT id INTO v_inv_id FROM public.inventory WHERE listing_id = v_line_listing;
    IF v_inv_id IS NULL THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_INVENTORY_NOT_FOUND';
    END IF;

    v_inv_ids := array_append(v_inv_ids, v_inv_id);
    v_plan_total := v_plan_total + v_line_qty;
  END LOOP;

  IF v_plan_total > v_remaining THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_PLAN_EXCEEDS_REMAINING';
  END IF;

  FOR v_inv_id IN
    SELECT DISTINCT x FROM unnest(v_inv_ids) AS x ORDER BY 1
  LOOP
    PERFORM 1 FROM public.inventory WHERE id = v_inv_id FOR UPDATE;
  END LOOP;

  FOR v_i IN 0 .. v_n - 1 LOOP
    v_line := v_canonical_plan->v_i;
    v_line_listing := (v_line->>'listing_id')::uuid;
    v_line_qty := (v_line->>'quantity')::bigint;
    SELECT * INTO v_inv FROM public.inventory WHERE listing_id = v_line_listing;
    v_available := v_inv.quantity_committed - v_inv.quantity_reserved - v_inv.quantity_consumed;
    IF v_available < v_line_qty THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_INSUFFICIENT_AVAILABLE';
    END IF;
  END LOOP;

  v_unit_price := v_demand.unit_price_committed_minor;

  FOR v_i IN 0 .. v_n - 1 LOOP
    v_line := v_canonical_plan->v_i;
    v_line_store := (v_line->>'store_profile_id')::uuid;
    v_line_listing := (v_line->>'listing_id')::uuid;
    v_line_qty := (v_line->>'quantity')::bigint;

    INSERT INTO public.sub_orders (order_id, store_profile_id, subtotal_minor, state)
    VALUES (v_demand.order_id, v_line_store, 0, 'CREATED')
    ON CONFLICT (order_id, store_profile_id) DO NOTHING;

    SELECT id INTO v_sub_id FROM public.sub_orders
    WHERE order_id = v_demand.order_id AND store_profile_id = v_line_store;

    v_sub_ids := array_append(v_sub_ids, v_sub_id);

    INSERT INTO public.order_items (
      sub_order_id, listing_id, variant_id, quantity,
      unit_price_minor, line_total_minor, currency
    ) VALUES (
      v_sub_id, v_line_listing, v_demand.variant_id, v_line_qty,
      v_unit_price, v_unit_price * v_line_qty, v_demand.currency
    )
    RETURNING id INTO v_order_item_id;

    v_item_ids := array_append(v_item_ids, v_order_item_id);

    INSERT INTO public.order_sourcing_allocations (
      demand_item_id, store_profile_id, listing_id,
      qty_allocated, qty_fulfilled, qty_released, state,
      sub_order_id, order_item_id, version
    ) VALUES (
      v_demand.id, v_line_store, v_line_listing,
      v_line_qty, 0, 0, 'ACTIVE',
      v_sub_id, v_order_item_id, 0
    )
    RETURNING * INTO v_alloc;

    v_alloc_ids := array_append(v_alloc_ids, v_alloc.id);

    SELECT id INTO v_inv_id FROM public.inventory WHERE listing_id = v_line_listing;

    v_res := public.tc_inv_reserve(
      v_inv_id,
      v_order_item_id,
      v_line_qty,
      'SOURCING_ALLOCATE',
      v_event || ':' || v_i::text
    );

    IF coalesce(v_res->>'disposition', '') <> 'APPLIED' THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_RESERVE_FAILED';
    END IF;

    v_res_ids := array_append(v_res_ids, (v_res->>'reservation_id')::uuid);
  END LOOP;

  INSERT INTO public.audit_logs (
    actor_person_id, actor_profile_id, operation, entity_type,
    entity_public_id, event_id, result, metadata
  ) VALUES (
    NULL, NULL, 'SOURCE_ALLOCATE_RESERVE', 'ORDER_DEMAND_ITEM',
    v_demand.public_id, NULL, 'APPLIED',
    jsonb_build_object(
      'event_id', v_event,
      'demand_public_id', v_demand.public_id,
      'demand_id', v_demand.id,
      'plan_hash', v_plan_hash,
      'plan', v_canonical_plan,
      'allocation_ids', to_jsonb(v_alloc_ids),
      'order_item_ids', to_jsonb(v_item_ids),
      'reservation_ids', to_jsonb(v_res_ids),
      'sub_order_ids', to_jsonb(v_sub_ids)
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'disposition', 'APPLIED',
    'event_id', v_event,
    'demand_public_id', v_demand.public_id,
    'plan_hash', v_plan_hash,
    'allocation_ids', to_jsonb(v_alloc_ids),
    'order_item_ids', to_jsonb(v_item_ids),
    'reservation_ids', to_jsonb(v_res_ids),
    'sub_order_ids', to_jsonb(v_sub_ids)
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.tc_source_allocate_reserve(text, jsonb, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.tc_source_allocate_reserve(text, jsonb, text) FROM anon;
REVOKE ALL ON FUNCTION public.tc_source_allocate_reserve(text, jsonb, text) FROM authenticated;
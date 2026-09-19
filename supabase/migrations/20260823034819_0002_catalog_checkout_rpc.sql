CREATE OR REPLACE FUNCTION public.execute_checkout(
  p_client_profile_public_id text,
  p_destination_type text,
  p_destination_id text,
  p_items jsonb,
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
  v_client_profile_id uuid;
  v_client_profile_public_id text;
  v_destination_type text;
  v_destination_id text;
  v_canonical_items jsonb;
  v_canonical_item_string text;
  v_canonical_request text;
  v_request_hash text;
  v_idem_inserted integer := 0;
  v_idem_person_id uuid;
  v_idem_hash text;
  v_idem_status text;
  v_idem_payload jsonb;
  v_requested_count integer := 0;
  v_resolved_count integer := 0;
  v_resolved_items jsonb := '[]'::jsonb;
  v_first_currency varchar(3);
  v_order_id uuid;
  v_order_public_id text;
  v_sub_order_id uuid;
  v_order_item_id uuid;
  v_sub_order_count integer := 0;
  v_package_count integer := 0;
  v_grand_total_minor bigint := 0;
  v_line_total_minor bigint;
  v_rec record;
  v_store_rec record;
  v_item_rec record;
  v_updated integer;
BEGIN
  v_auth_user_id := auth.uid();
  IF v_auth_user_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_UNAUTHENTICATED';
  END IF;
  v_client_profile_public_id := upper(btrim(coalesce(p_client_profile_public_id, '')));
  v_destination_type := upper(btrim(coalesce(p_destination_type, '')));
  v_destination_id := nullif(btrim(coalesce(p_destination_id, '')), '');
  IF v_client_profile_public_id = '' THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_INVALID_CLIENT_PROFILE'; END IF;
  IF v_destination_type = '' THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_DESTINATION_INVALID'; END IF;
  IF p_idempotency_key IS NULL OR length(btrim(p_idempotency_key)) < 8 OR length(btrim(p_idempotency_key)) > 200 THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_INVALID_IDEMPOTENCY_KEY'; END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_INVALID_ITEMS_PAYLOAD'; END IF;
  IF jsonb_array_length(p_items) < 1 OR jsonb_array_length(p_items) > 200 THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_INVALID_ITEMS_PAYLOAD'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) AS e(value) WHERE jsonb_typeof(value) <> 'object' OR btrim(coalesce(value ->> 'listing_public_id', '')) = '' OR jsonb_typeof(value -> 'quantity') <> 'number' OR coalesce(value ->> 'quantity', '') !~ '^[1-9][0-9]*$' OR length(value ->> 'quantity') > 9) THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_INVALID_ITEMS_PAYLOAD'; END IF;
  SELECT per.id, pr.id INTO v_person_id, v_client_profile_id FROM public.persons per JOIN public.profiles pr ON pr.person_id = per.id WHERE per.auth_user_id = v_auth_user_id AND pr.public_id = v_client_profile_public_id AND pr.profile_type = 'CLI' AND pr.status = 'active' LIMIT 1;
  IF v_person_id IS NULL OR v_client_profile_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_FORBIDDEN_CLIENT_PROFILE'; END IF;
  IF v_destination_type = 'PTC' THEN
    IF v_destination_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.profiles ptc WHERE ptc.public_id = upper(v_destination_id) AND ptc.profile_type = 'PTC' AND ptc.status = 'active') THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_DESTINATION_INVALID'; END IF;
    v_destination_id := upper(v_destination_id);
  END IF;
  SELECT jsonb_agg(jsonb_build_object('listing_public_id', x.listing_public_id, 'quantity', x.quantity) ORDER BY x.listing_public_id) INTO v_canonical_items FROM (SELECT upper(btrim(e.value ->> 'listing_public_id')) AS listing_public_id, sum((e.value ->> 'quantity')::bigint) AS quantity FROM jsonb_array_elements(p_items) AS e(value) GROUP BY upper(btrim(e.value ->> 'listing_public_id'))) AS x;
  IF v_canonical_items IS NULL OR jsonb_array_length(v_canonical_items) = 0 THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_INVALID_ITEMS_PAYLOAD'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_to_recordset(v_canonical_items) AS x(listing_public_id text, quantity bigint) WHERE x.quantity <= 0 OR x.quantity > 100000) THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_INVALID_QUANTITY'; END IF;
  SELECT string_agg(format('%s:%s', x.listing_public_id, x.quantity), '|' ORDER BY x.listing_public_id) INTO v_canonical_item_string FROM jsonb_to_recordset(v_canonical_items) AS x(listing_public_id text, quantity bigint);
  v_canonical_request := v_client_profile_public_id || '|' || v_destination_type || '|' || coalesce(v_destination_id, '') || '|' || coalesce(v_canonical_item_string, '');
  v_request_hash := encode(digest(v_canonical_request, 'sha256'), 'hex');
  INSERT INTO public.idempotency_records (operation_type,idempotency_key,person_id,request_hash,status) VALUES ('CHECKOUT',btrim(p_idempotency_key),v_person_id,v_request_hash,'PROCESSING') ON CONFLICT (operation_type,idempotency_key) DO NOTHING;
  GET DIAGNOSTICS v_idem_inserted = ROW_COUNT;
  IF v_idem_inserted = 0 THEN
    SELECT person_id, request_hash, status, response_payload INTO v_idem_person_id, v_idem_hash, v_idem_status, v_idem_payload FROM public.idempotency_records WHERE operation_type='CHECKOUT' AND idempotency_key=btrim(p_idempotency_key) FOR UPDATE;
    IF v_idem_person_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_IDEMPOTENCY_STATE_INVALID'; END IF;
    IF v_idem_person_id <> v_person_id OR v_idem_hash <> v_request_hash THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_IDEMPOTENCY_KEY_REUSED'; END IF;
    IF v_idem_status = 'COMPLETED' THEN IF v_idem_payload IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_IDEMPOTENCY_STATE_INVALID'; END IF; RETURN v_idem_payload || jsonb_build_object('already_processed', true); END IF;
    RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_IDEMPOTENCY_IN_PROGRESS';
  END IF;
  v_requested_count := jsonb_array_length(v_canonical_items);
  FOR v_rec IN
    SELECT x.listing_public_id,x.quantity,i.id AS inventory_id,i.quantity_on_hand,i.quantity_reserved,i.version AS inventory_version,sl.id AS listing_id,sl.store_profile_id,sl.variant_id,sl.price_minor,sl.currency,coalesce(pv.weight_kg,0)::numeric(10,3) AS weight_kg,coalesce(pv.volume_m3,0)::numeric(10,4) AS volume_m3,pv.requires_cold_chain,pv.requires_fragile_handling
    FROM jsonb_to_recordset(v_canonical_items) AS x(listing_public_id text, quantity bigint)
    JOIN public.store_listings sl ON sl.public_id=x.listing_public_id
    JOIN public.inventory i ON i.listing_id=sl.id
    JOIN public.product_variants pv ON pv.id=sl.variant_id
    JOIN public.products p ON p.id=pv.product_id
    JOIN public.profiles sp ON sp.id=sl.store_profile_id
    WHERE sl.is_active=true AND pv.is_active=true AND p.is_active=true AND sp.status='active' AND sp.profile_type IN ('VEN','TIE')
    ORDER BY i.id FOR UPDATE OF i, sl
  LOOP
    v_resolved_count := v_resolved_count + 1;
    IF v_first_currency IS NULL THEN v_first_currency := v_rec.currency; ELSIF v_first_currency <> v_rec.currency THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_CURRENCY_MISMATCH'; END IF;
    IF (v_rec.quantity_on_hand - v_rec.quantity_reserved) < v_rec.quantity THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_OUT_OF_STOCK'; END IF;
    v_resolved_items := v_resolved_items || jsonb_build_array(jsonb_build_object('inventory_id',v_rec.inventory_id,'listing_id',v_rec.listing_id,'listing_public_id',v_rec.listing_public_id,'store_profile_id',v_rec.store_profile_id,'variant_id',v_rec.variant_id,'quantity',v_rec.quantity,'price_minor',v_rec.price_minor,'currency',v_rec.currency,'weight_kg',v_rec.weight_kg,'volume_m3',v_rec.volume_m3,'requires_cold_chain',v_rec.requires_cold_chain,'requires_fragile_handling',v_rec.requires_fragile_handling));
  END LOOP;
  IF v_resolved_count <> v_requested_count THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_INVALID_LISTING'; END IF;
  IF v_first_currency IS NULL THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_INVALID_LISTING'; END IF;
  INSERT INTO public.orders(client_profile_id,total_minor,currency,destination_type,destination_id,idempotency_key,state) VALUES(v_client_profile_id,0,v_first_currency,v_destination_type,v_destination_id,btrim(p_idempotency_key),'CREATED') RETURNING id, public_id INTO v_order_id, v_order_public_id;
  FOR v_store_rec IN
    SELECT r.store_profile_id,sum(r.quantity*r.price_minor)::bigint AS subtotal_minor,sum(coalesce(r.weight_kg,0)*r.quantity)::numeric(10,3) AS package_weight_kg,sum(coalesce(r.volume_m3,0)*r.quantity)::numeric(10,4) AS package_volume_m3,bool_or(r.requires_cold_chain) AS requires_cold_chain,bool_or(r.requires_fragile_handling) AS requires_fragile_handling
    FROM jsonb_to_recordset(v_resolved_items) AS r(inventory_id uuid,listing_id uuid,listing_public_id text,store_profile_id uuid,variant_id uuid,quantity bigint,price_minor bigint,currency text,weight_kg numeric,volume_m3 numeric,requires_cold_chain boolean,requires_fragile_handling boolean)
    GROUP BY r.store_profile_id ORDER BY r.store_profile_id
  LOOP
    INSERT INTO public.sub_orders(order_id,store_profile_id,subtotal_minor,state) VALUES(v_order_id,v_store_rec.store_profile_id,v_store_rec.subtotal_minor,'CREATED') RETURNING id INTO v_sub_order_id;
    v_sub_order_count := v_sub_order_count + 1;
    INSERT INTO public.packages(sub_order_id,current_custodian_id,state,version,weight_kg,volume_m3,requires_cold_chain,requires_fragile_handling) VALUES(v_sub_order_id,v_store_rec.store_profile_id,'CREATED',0,v_store_rec.package_weight_kg,v_store_rec.package_volume_m3,v_store_rec.requires_cold_chain,v_store_rec.requires_fragile_handling);
    v_package_count := v_package_count + 1;
    FOR v_item_rec IN
      SELECT * FROM jsonb_to_recordset(v_resolved_items) AS r(inventory_id uuid,listing_id uuid,listing_public_id text,store_profile_id uuid,variant_id uuid,quantity bigint,price_minor bigint,currency text,weight_kg numeric,volume_m3 numeric,requires_cold_chain boolean,requires_fragile_handling boolean) WHERE r.store_profile_id=v_store_rec.store_profile_id ORDER BY r.listing_id
    LOOP
      v_line_total_minor := v_item_rec.quantity * v_item_rec.price_minor;
      INSERT INTO public.order_items(sub_order_id,listing_id,variant_id,quantity,unit_price_minor,line_total_minor,currency) VALUES(v_sub_order_id,v_item_rec.listing_id,v_item_rec.variant_id,v_item_rec.quantity,v_item_rec.price_minor,v_line_total_minor,v_item_rec.currency) RETURNING id INTO v_order_item_id;
      UPDATE public.inventory SET quantity_reserved=quantity_reserved+v_item_rec.quantity, version=version+1 WHERE id=v_item_rec.inventory_id AND (quantity_on_hand-quantity_reserved)>=v_item_rec.quantity;
      GET DIAGNOSTICS v_updated = ROW_COUNT;
      IF v_updated <> 1 THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_OUT_OF_STOCK'; END IF;
      INSERT INTO public.inventory_reservations(inventory_id,order_item_id,quantity,status) VALUES(v_item_rec.inventory_id,v_order_item_id,v_item_rec.quantity,'RESERVED');
      v_grand_total_minor := v_grand_total_minor + v_line_total_minor;
    END LOOP;
  END LOOP;
  UPDATE public.orders SET total_minor=v_grand_total_minor,currency=v_first_currency WHERE id=v_order_id;
  v_idem_payload := jsonb_build_object('success',true,'status','COMPLETED','order_public_id',v_order_public_id,'sub_order_count',v_sub_order_count,'package_count',v_package_count,'total_minor',v_grand_total_minor,'currency',v_first_currency,'already_processed',false);
  INSERT INTO public.audit_logs(actor_person_id,actor_profile_id,operation,entity_type,entity_public_id,result,metadata) VALUES(v_person_id,v_client_profile_id,'EXECUTE_CHECKOUT','ORDER',v_order_public_id,'COMPLETED',jsonb_build_object('sub_order_count',v_sub_order_count,'package_count',v_package_count,'total_minor',v_grand_total_minor,'currency',v_first_currency,'idempotency_key',btrim(p_idempotency_key)));
  UPDATE public.idempotency_records SET status='COMPLETED',response_payload=v_idem_payload,completed_at=now() WHERE operation_type='CHECKOUT' AND idempotency_key=btrim(p_idempotency_key) AND person_id=v_person_id AND request_hash=v_request_hash;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated <> 1 THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_IDEMPOTENCY_STATE_INVALID'; END IF;
  RETURN v_idem_payload;
END;
$$;
REVOKE ALL ON FUNCTION public.execute_checkout(text,text,text,jsonb,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.execute_checkout(text,text,text,jsonb,text) TO authenticated;
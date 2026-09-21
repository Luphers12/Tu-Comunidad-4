-- VERIFIED REPLAY OVERLAY — 2026-09-20
-- Apply after 20260823035239_staging_migration_chunk_buffer.sql.
-- Substitute for the two historical dynamic chunk loaders.
-- Source: exact LIVE STAGING pg_get_functiondef.
-- The 104 forensic migration files remain untouched.

CREATE OR REPLACE FUNCTION public.process_event(p_event_envelope jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_auth_user_id uuid;
  v_person_id uuid;
  v_actor_profile_id uuid;
  v_actor_profile_public_id text;
  v_event_id text;
  v_idempotency_key text;
  v_event_type text;
  v_movement_public_id text;
  v_package_public_ids text[];
  v_occurred_at timestamptz;
  v_expected_version bigint;
  v_movement_id uuid;
  v_route_id uuid;
  v_current_state text;
  v_current_version bigint;
  v_canonical_package_string text;
  v_canonical_request text;
  v_request_hash text;
  v_inbox_inserted integer := 0;
  v_existing public.event_inbox%ROWTYPE;
  v_classification jsonb;
  v_domain_result jsonb;
  v_resolution public.tc_sync_resolution_type;
  v_error_code text;
  v_resulting_state text;
  v_resulting_version bigint;
  v_before_version bigint;
  v_conflict_id text;
  v_version_mismatch boolean := false;
  v_version_mismatch_tolerated boolean := false;
BEGIN
  v_auth_user_id := auth.uid();
  IF v_auth_user_id IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'TC_UNAUTHENTICATED';
  END IF;
  IF p_event_envelope IS NULL
     OR jsonb_typeof(p_event_envelope) <> 'object' THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'TC_INVALID_EVENT_ENVELOPE';
  END IF;
  v_event_id :=
    upper(btrim(coalesce(p_event_envelope ->> 'event_id', '')));
  v_idempotency_key :=
    btrim(coalesce(p_event_envelope ->> 'idempotency_key', ''));
  v_event_type :=
    upper(btrim(coalesce(p_event_envelope ->> 'event_type', '')));
  v_actor_profile_public_id :=
    upper(btrim(coalesce(
      p_event_envelope ->> 'profile_public_id',
      ''
    )));
  v_movement_public_id :=
    upper(btrim(coalesce(
      p_event_envelope ->> 'movement_public_id',
      ''
    )));
  IF v_event_id = ''
     OR v_event_id NOT LIKE 'EVT-%'
     OR v_idempotency_key = ''
     OR length(v_idempotency_key) > 200
     OR v_actor_profile_public_id = ''
     OR v_movement_public_id = ''
     OR v_movement_public_id NOT LIKE 'MOV-%' THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'TC_INVALID_EVENT_ENVELOPE';
  END IF;
  IF v_event_type NOT IN (
    'CUSTODY_RELEASED',
    'CUSTODY_RECEIVED'
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'TC_EVENT_TYPE_NOT_SUPPORTED';
  END IF;
  IF jsonb_typeof(p_event_envelope -> 'package_public_ids') <> 'array'
     OR jsonb_array_length(
          p_event_envelope -> 'package_public_ids'
        ) < 1
     OR jsonb_array_length(
          p_event_envelope -> 'package_public_ids'
        ) > 500 THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'TC_INVALID_EVENT_PACKAGE_SET';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(
      p_event_envelope -> 'package_public_ids'
    ) e(value)
    WHERE jsonb_typeof(e.value) <> 'string'
       OR btrim(e.value #>> '{}') = ''
       OR upper(btrim(e.value #>> '{}')) NOT LIKE 'PKG-%'
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'TC_INVALID_EVENT_PACKAGE_SET';
  END IF;
  SELECT array_agg(x.package_public_id ORDER BY x.package_public_id)
  INTO v_package_public_ids
  FROM (
    SELECT DISTINCT
      upper(btrim(e.value #>> '{}')) AS package_public_id
    FROM jsonb_array_elements(
      p_event_envelope -> 'package_public_ids'
    ) e(value)
  ) x;
  BEGIN
    v_occurred_at :=
      (p_event_envelope ->> 'occurred_at')::timestamptz;
  EXCEPTION
    WHEN invalid_datetime_format OR datetime_field_overflow THEN
      RAISE EXCEPTION USING
        ERRCODE = 'P0001',
        MESSAGE = 'TC_INVALID_EVENT_OCCURRED_AT';
  END;
  IF v_occurred_at IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'TC_INVALID_EVENT_OCCURRED_AT';
  END IF;
  IF p_event_envelope ? 'expected_movement_version'
     AND p_event_envelope ->> 'expected_movement_version' IS NOT NULL THEN
    BEGIN
      v_expected_version :=
        (p_event_envelope ->> 'expected_movement_version')::bigint;
    EXCEPTION
      WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        RAISE EXCEPTION USING
          ERRCODE = 'P0001',
          MESSAGE = 'TC_INVALID_EXPECTED_VERSION';
    END;
    IF v_expected_version < 0 THEN
      RAISE EXCEPTION USING
        ERRCODE = 'P0001',
        MESSAGE = 'TC_INVALID_EXPECTED_VERSION';
    END IF;
  END IF;
  SELECT
    per.id,
    pr.id
  INTO
    v_person_id,
    v_actor_profile_id
  FROM public.persons per
  JOIN public.profiles pr
    ON pr.person_id = per.id
  WHERE per.auth_user_id = v_auth_user_id
    AND pr.public_id = v_actor_profile_public_id
    AND pr.status = 'active'
  LIMIT 1;
  IF v_person_id IS NULL OR v_actor_profile_id IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'TC_EVENT_ACTOR_FORBIDDEN';
  END IF;
  SELECT
    m.id,
    m.route_id,
    m.state,
    m.version
  INTO
    v_movement_id,
    v_route_id,
    v_current_state,
    v_current_version
  FROM public.movements m
  WHERE m.public_id = v_movement_public_id;
  SELECT string_agg(x, '|' ORDER BY x)
  INTO v_canonical_package_string
  FROM unnest(v_package_public_ids) x;
  v_canonical_request :=
    v_event_id || '|' ||
    v_event_type || '|' ||
    v_actor_profile_public_id || '|' ||
    v_movement_public_id || '|' ||
    to_char(
      v_occurred_at AT TIME ZONE 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.US'
    ) || 'Z|' ||
    coalesce(v_expected_version::text, '') || '|' ||
    coalesce(v_canonical_package_string, '');
  v_request_hash := encode(
    digest(v_canonical_request, 'sha256'),
    'hex'
  );
  INSERT INTO public.event_inbox (
    event_id,
    idempotency_key,
    request_hash,
    event_type,
    auth_user_id,
    person_id,
    profile_id,
    movement_id,
    route_id,
    expected_version,
    occurred_at,
    payload,
    processing_status,
    last_attempt_at
  )
  VALUES (
    v_event_id,
    v_idempotency_key,
    v_request_hash,
    v_event_type,
    v_auth_user_id,
    v_person_id,
    v_actor_profile_id,
    v_movement_id,
    v_route_id,
    v_expected_version,
    v_occurred_at,
    jsonb_build_object(
      'movement_public_id', v_movement_public_id,
      'package_public_ids', to_jsonb(v_package_public_ids),
      'profile_public_id', v_actor_profile_public_id
    ),
    'PROCESSING',
    now()
  )
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_inbox_inserted = ROW_COUNT;
  IF v_inbox_inserted = 0 THEN
    SELECT ei.*
    INTO v_existing
    FROM public.event_inbox ei
    WHERE ei.event_id = v_event_id
       OR ei.idempotency_key = v_idempotency_key
    ORDER BY
      CASE WHEN ei.event_id = v_event_id THEN 0 ELSE 1 END
    LIMIT 1
    FOR UPDATE;
    IF v_existing.id IS NULL THEN
      RAISE EXCEPTION USING
        ERRCODE = 'P0001',
        MESSAGE = 'TC_EVENT_IDEMPOTENCY_STATE_INVALID';
    END IF;
    IF v_existing.event_id <> v_event_id
       OR v_existing.idempotency_key <> v_idempotency_key
       OR v_existing.request_hash <> v_request_hash THEN
      RAISE EXCEPTION USING
        ERRCODE = 'P0001',
        MESSAGE = 'TC_EVENT_IDEMPOTENCY_REUSED';
    END IF;
    IF v_existing.processing_status = 'PROCESSED'
       AND v_existing.sync_resolution IS DISTINCT FROM
         'RETRY_LATER'::public.tc_sync_resolution_type THEN
      INSERT INTO public.audit_logs (
        actor_person_id,
        actor_profile_id,
        operation,
        entity_type,
        entity_public_id,
        event_id,
        before_version,
        after_version,
        result,
        metadata
      )
      VALUES (
        v_person_id,
        v_actor_profile_id,
        'SYNC_DUPLICATE',
        'MOVEMENT',
        v_movement_public_id,
        v_event_id,
        v_existing.observed_entity_version,
        v_existing.resulting_version,
        'DUPLICATE',
        jsonb_build_object(
          'original_resolution', v_existing.sync_resolution,
          'original_error_code', v_existing.error_code,
          'retry_count', v_existing.retry_count
        )
      );
      RETURN jsonb_build_object(
        'success',
          v_existing.sync_resolution =
            'APPLIED'::public.tc_sync_resolution_type,
        'status', 'DUPLICATE',
        'event_id', v_event_id,
        'movement_id', v_movement_public_id,
        'original_resolution', v_existing.sync_resolution,
        'resulting_state', v_existing.resulting_state,
        'resulting_version', v_existing.resulting_version,
        'error_code', v_existing.error_code,
        'conflict_id', v_existing.conflict_id,
        'already_processed', true
      );
    END IF;
    IF v_existing.processing_status = 'RETRY'
       OR v_existing.sync_resolution =
         'RETRY_LATER'::public.tc_sync_resolution_type THEN
      UPDATE public.event_inbox
      SET
        processing_status = 'PROCESSING',
        retry_count = retry_count + 1,
        last_attempt_at = now()
      WHERE id = v_existing.id;
    ELSE
      INSERT INTO public.audit_logs (
        actor_person_id,
        actor_profile_id,
        operation,
        entity_type,
        entity_public_id,
        event_id,
        result,
        metadata
      )
      VALUES (
        v_person_id,
        v_actor_profile_id,
        'SYNC_RETRY_DEFERRED',
        'MOVEMENT',
        v_movement_public_id,
        v_event_id,
        'RETRY_LATER',
        jsonb_build_object(
          'processing_status', v_existing.processing_status,
          'sync_resolution', v_existing.sync_resolution
        )
      );
      RETURN jsonb_build_object(
        'success', false,
        'status', 'RETRY_LATER',
        'event_id', v_event_id,
        'movement_id', v_movement_public_id,
        'error_code', 'TC_EVENT_STILL_PROCESSING',
        'already_processed', false
      );
    END IF;
  END IF;
  IF v_movement_id IS NULL THEN
    v_resolution :=
      'REJECTED_INVALID_TRANSITION'::public.tc_sync_resolution_type;
    v_error_code := 'TC_MOVEMENT_NOT_FOUND';
    UPDATE public.event_inbox
    SET
      processing_status = 'PROCESSED',
      sync_resolution = v_resolution,
      disposition = v_resolution::text,
      error_code = v_error_code,
      processed_at = now(),
      last_attempt_at = now(),
      decision_metadata = jsonb_build_object(
        'movement_public_id', v_movement_public_id
      )
    WHERE event_id = v_event_id;
    INSERT INTO public.audit_logs (
      actor_person_id,
      actor_profile_id,
      operation,
      entity_type,
      entity_public_id,
      event_id,
      result,
      metadata
    )
    VALUES (
      v_person_id,
      v_actor_profile_id,
      v_event_type,
      'MOVEMENT',
      v_movement_public_id,
      v_event_id,
      v_resolution::text,
      jsonb_build_object(
        'error_code', v_error_code
      )
    );
    RETURN jsonb_build_object(
      'success', false,
      'status', v_resolution,
      'event_id', v_event_id,
      'movement_id', v_movement_public_id,
      'error_code', v_error_code,
      'already_processed', false
    );
  END IF;
  v_classification := public.tc_classify_custody_sync_event(
    v_event_type,
    v_movement_public_id,
    v_package_public_ids,
    v_actor_profile_id,
    v_occurred_at,
    v_expected_version
  );
  v_resolution :=
    (v_classification ->> 'resolution')::public.tc_sync_resolution_type;
  v_error_code :=
    nullif(v_classification ->> 'error_code', '');
  v_current_state :=
    coalesce(
      nullif(v_classification ->> 'current_state', ''),
      v_current_state
    );
  IF v_classification ? 'current_version'
     AND v_classification ->> 'current_version' IS NOT NULL THEN
    v_current_version :=
      (v_classification ->> 'current_version')::bigint;
  END IF;
  v_version_mismatch :=
    coalesce(
      (v_classification ->> 'version_mismatch')::boolean,
      false
    );
  v_version_mismatch_tolerated :=
    coalesce(
      (v_classification ->> 'version_mismatch_tolerated')::boolean,
      false
    );
  IF v_resolution =
     'RETRY_LATER'::public.tc_sync_resolution_type THEN
    UPDATE public.event_inbox
    SET
      processing_status = 'RETRY',
      sync_resolution = v_resolution,
      disposition = v_resolution::text,
      observed_entity_version = v_current_version,
      error_code = v_error_code,
      last_attempt_at = now(),
      decision_metadata = v_classification
    WHERE event_id = v_event_id;
    INSERT INTO public.audit_logs (
      actor_person_id,
      actor_profile_id,
      operation,
      entity_type,
      entity_public_id,
      event_id,
      before_version,
      after_version,
      result,
      metadata
    )
    VALUES (
      v_person_id,
      v_actor_profile_id,
      v_event_type,
      'MOVEMENT',
      v_movement_public_id,
      v_event_id,
      v_current_version,
      v_current_version,
      v_resolution::text,
      jsonb_build_object(
        'error_code', v_error_code,
        'expected_movement_version', v_expected_version,
        'version_mismatch', v_version_mismatch,
        'classification', v_classification
      )
    );
    RETURN jsonb_build_object(
      'success', false,
      'status', v_resolution,
      'event_id', v_event_id,
      'movement_id', v_movement_public_id,
      'resulting_state', v_current_state,
      'resulting_version', v_current_version,
      'error_code', v_error_code,
      'already_processed', false
    );
  END IF;
  IF v_resolution =
     'IGNORED_STALE'::public.tc_sync_resolution_type THEN
    UPDATE public.event_inbox
    SET
      processing_status = 'PROCESSED',
      sync_resolution = v_resolution,
      disposition = v_resolution::text,
      resulting_state = v_current_state,
      resulting_version = v_current_version,
      observed_entity_version = v_current_version,
      error_code = v_error_code,
      processed_at = now(),
      last_attempt_at = now(),
      decision_metadata = v_classification
    WHERE event_id = v_event_id;
    INSERT INTO public.audit_logs (
      actor_person_id,
      actor_profile_id,
      operation,
      entity_type,
      entity_public_id,
      event_id,
      before_version,
      after_version,
      result,
      metadata
    )
    VALUES (
      v_person_id,
      v_actor_profile_id,
      v_event_type,
      'MOVEMENT',
      v_movement_public_id,
      v_event_id,
      v_current_version,
      v_current_version,
      v_resolution::text,
      jsonb_build_object(
        'expected_movement_version', v_expected_version,
        'version_mismatch', v_version_mismatch,
        'classification', v_classification
      )
    );
    RETURN jsonb_build_object(
      'success', true,
      'status', v_resolution,
      'event_id', v_event_id,
      'movement_id', v_movement_public_id,
      'resulting_state', v_current_state,
      'resulting_version', v_current_version,
      'error_code', v_error_code,
      'already_processed', false
    );
  END IF;
  IF v_resolution =
     'REJECTED_UNAUTHORIZED'::public.tc_sync_resolution_type THEN
    UPDATE public.event_inbox
    SET
      processing_status = 'PROCESSED',
      sync_resolution = v_resolution,
      disposition = v_resolution::text,
      resulting_state = v_current_state,
      resulting_version = v_current_version,
      observed_entity_version = v_current_version,
      error_code = v_error_code,
      processed_at = now(),
      last_attempt_at = now(),
      decision_metadata = v_classification
    WHERE event_id = v_event_id;
    INSERT INTO public.audit_logs (
      actor_person_id,
      actor_profile_id,
      operation,
      entity_type,
      entity_public_id,
      event_id,
      before_version,
      after_version,
      result,
      metadata
    )
    VALUES (
      v_person_id,
      v_actor_profile_id,
      v_event_type,
      'MOVEMENT',
      v_movement_public_id,
      v_event_id,
      v_current_version,
      v_current_version,
      v_resolution::text,
      jsonb_build_object(
        'error_code', v_error_code,
        'expected_movement_version', v_expected_version,
        'version_mismatch', v_version_mismatch
      )
    );
    RETURN jsonb_build_object(
      'success', false,
      'status', v_resolution,
      'event_id', v_event_id,
      'movement_id', v_movement_public_id,
      'resulting_state', v_current_state,
      'resulting_version', v_current_version,
      'error_code', v_error_code,
      'already_processed', false
    );
  END IF;
  IF v_resolution =
     'REJECTED_INVALID_TRANSITION'::public.tc_sync_resolution_type THEN
    UPDATE public.event_inbox
    SET
      processing_status = 'PROCESSED',
      sync_resolution = v_resolution,
      disposition = v_resolution::text,
      resulting_state = v_current_state,
      resulting_version = v_current_version,
      observed_entity_version = v_current_version,
      error_code = v_error_code,
      processed_at = now(),
      last_attempt_at = now(),
      decision_metadata = v_classification
    WHERE event_id = v_event_id;
    INSERT INTO public.audit_logs (
      actor_person_id,
      actor_profile_id,
      operation,
      entity_type,
      entity_public_id,
      event_id,
      before_version,
      after_version,
      result,
      metadata
    )
    VALUES (
      v_person_id,
      v_actor_profile_id,
      v_event_type,
      'MOVEMENT',
      v_movement_public_id,
      v_event_id,
      v_current_version,
      v_current_version,
      v_resolution::text,
      jsonb_build_object(
        'error_code', v_error_code,
        'expected_movement_version', v_expected_version,
        'version_mismatch', v_version_mismatch
      )
    );
    RETURN jsonb_build_object(
      'success', false,
      'status', v_resolution,
      'event_id', v_event_id,
      'movement_id', v_movement_public_id,
      'resulting_state', v_current_state,
      'resulting_version', v_current_version,
      'error_code', v_error_code,
      'already_processed', false
    );
  END IF;
  IF v_resolution =
     'CONFLICT_NEEDS_REVIEW'::public.tc_sync_resolution_type THEN
    v_conflict_id := public.tc_record_custody_conflict(
      v_event_id,
      v_movement_public_id,
      v_current_version,
      v_expected_version,
      v_current_state,
      v_event_type,
      coalesce(v_error_code, 'TC_SYNC_CONFLICT')
    );
    UPDATE public.sync_conflicts
    SET metadata =
      coalesce(metadata, '{}'::jsonb) ||
      jsonb_build_object(
        'classification', v_classification,
        'package_public_ids', to_jsonb(v_package_public_ids),
        'actor_profile_public_id', v_actor_profile_public_id
      )
    WHERE public_id = v_conflict_id;
    UPDATE public.event_inbox
    SET
      processing_status = 'PROCESSED',
      sync_resolution = v_resolution,
      disposition = v_resolution::text,
      resulting_state = v_current_state,
      resulting_version = v_current_version,
      observed_entity_version = v_current_version,
      conflict_id = v_conflict_id,
      error_code = v_error_code,
      processed_at = now(),
      last_attempt_at = now(),
      decision_metadata = v_classification
    WHERE event_id = v_event_id;
    INSERT INTO public.audit_logs (
      actor_person_id,
      actor_profile_id,
      operation,
      entity_type,
      entity_public_id,
      event_id,
      before_version,
      after_version,
      result,
      metadata
    )
    VALUES (
      v_person_id,
      v_actor_profile_id,
      v_event_type,
      'MOVEMENT',
      v_movement_public_id,
      v_event_id,
      v_current_version,
      v_current_version,
      v_resolution::text,
      jsonb_build_object(
        'conflict_id', v_conflict_id,
        'error_code', v_error_code,
        'expected_movement_version', v_expected_version,
        'version_mismatch', v_version_mismatch,
        'classification', v_classification
      )
    );
    RETURN jsonb_build_object(
      'success', false,
      'status', v_resolution,
      'event_id', v_event_id,
      'movement_id', v_movement_public_id,
      'resulting_state', v_current_state,
      'resulting_version', v_current_version,
      'error_code', v_error_code,
      'conflict_id', v_conflict_id,
      'already_processed', false
    );
  END IF;
  IF v_resolution =
     'APPLIED'::public.tc_sync_resolution_type THEN
    IF v_event_type = 'CUSTODY_RELEASED' THEN
      v_domain_result := public.tc_apply_custody_release(
        v_event_id,
        v_movement_public_id,
        v_package_public_ids,
        v_actor_profile_id,
        v_occurred_at
      );
    ELSIF v_event_type = 'CUSTODY_RECEIVED' THEN
      v_domain_result := public.tc_apply_custody_receive(
        v_event_id,
        v_movement_public_id,
        v_package_public_ids,
        v_actor_profile_id,
        v_occurred_at
      );
    END IF;
    IF coalesce(v_domain_result ->> 'disposition', 'REJECTED') <> 'APPLIED' THEN
      v_error_code := coalesce(
        nullif(v_domain_result ->> 'error_code', ''),
        'TC_DOMAIN_CLASSIFICATION_DIVERGED'
      );
      v_resulting_state := coalesce(
        nullif(v_domain_result ->> 'resulting_state', ''),
        v_current_state
      );
      IF v_domain_result ? 'resulting_version'
         AND v_domain_result ->> 'resulting_version' IS NOT NULL THEN
        v_resulting_version :=
          (v_domain_result ->> 'resulting_version')::bigint;
      ELSE
        v_resulting_version := v_current_version;
      END IF;
      v_conflict_id := public.tc_record_custody_conflict(
        v_event_id,
        v_movement_public_id,
        v_resulting_version,
        v_expected_version,
        v_resulting_state,
        v_event_type,
        v_error_code
      );
      UPDATE public.event_inbox
      SET
        processing_status = 'PROCESSED',
        sync_resolution =
          'CONFLICT_NEEDS_REVIEW'::public.tc_sync_resolution_type,
        disposition = 'CONFLICT_NEEDS_REVIEW',
        resulting_state = v_resulting_state,
        resulting_version = v_resulting_version,
        observed_entity_version = v_current_version,
        conflict_id = v_conflict_id,
        error_code = v_error_code,
        processed_at = now(),
        last_attempt_at = now(),
        decision_metadata = jsonb_build_object(
          'classification', v_classification,
          'domain_result', v_domain_result,
          'classification_diverged', true
        )
      WHERE event_id = v_event_id;
      INSERT INTO public.audit_logs (
        actor_person_id,
        actor_profile_id,
        operation,
        entity_type,
        entity_public_id,
        event_id,
        before_version,
        after_version,
        result,
        metadata
      )
      VALUES (
        v_person_id,
        v_actor_profile_id,
        v_event_type,
        'MOVEMENT',
        v_movement_public_id,
        v_event_id,
        v_current_version,
        v_resulting_version,
        'CONFLICT_NEEDS_REVIEW',
        jsonb_build_object(
          'conflict_id', v_conflict_id,
          'error_code', v_error_code,
          'classification', v_classification,
          'domain_result', v_domain_result
        )
      );
      RETURN jsonb_build_object(
        'success', false,
        'status', 'CONFLICT_NEEDS_REVIEW',
        'event_id', v_event_id,
        'movement_id', v_movement_public_id,
        'resulting_state', v_resulting_state,
        'resulting_version', v_resulting_version,
        'error_code', v_error_code,
        'conflict_id', v_conflict_id,
        'already_processed', false
      );
    END IF;
    v_resulting_state :=
      nullif(v_domain_result ->> 'resulting_state', '');
    v_resulting_version :=
      (v_domain_result ->> 'resulting_version')::bigint;
    IF v_domain_result ? 'before_version'
       AND v_domain_result ->> 'before_version' IS NOT NULL THEN
      v_before_version :=
        (v_domain_result ->> 'before_version')::bigint;
    ELSE
      v_before_version := v_current_version;
    END IF;
    UPDATE public.event_inbox
    SET
      processing_status = 'PROCESSED',
      sync_resolution =
        'APPLIED'::public.tc_sync_resolution_type,
      disposition = 'APPLIED',
      resulting_state = v_resulting_state,
      resulting_version = v_resulting_version,
      observed_entity_version = v_current_version,
      error_code = NULL,
      processed_at = now(),
      last_attempt_at = now(),
      decision_metadata = jsonb_build_object(
        'classification', v_classification,
        'domain_result', v_domain_result,
        'version_mismatch', v_version_mismatch,
        'version_mismatch_tolerated',
          v_version_mismatch_tolerated
      )
    WHERE event_id = v_event_id;
    INSERT INTO public.audit_logs (
      actor_person_id,
      actor_profile_id,
      operation,
      entity_type,
      entity_public_id,
      event_id,
      before_version,
      after_version,
      result,
      metadata
    )
    VALUES (
      v_person_id,
      v_actor_profile_id,
      v_event_type,
      'MOVEMENT',
      v_movement_public_id,
      v_event_id,
      v_before_version,
      v_resulting_version,
      'APPLIED',
      jsonb_build_object(
        'package_public_ids', to_jsonb(v_package_public_ids),
        'expected_movement_version', v_expected_version,
        'observed_movement_version', v_current_version,
        'version_mismatch', v_version_mismatch,
        'version_mismatch_tolerated',
          v_version_mismatch_tolerated
      )
    );
    RETURN jsonb_build_object(
      'success', true,
      'status', 'APPLIED',
      'event_id', v_event_id,
      'movement_id', v_movement_public_id,
      'resulting_state', v_resulting_state,
      'resulting_version', v_resulting_version,
      'version_mismatch_tolerated',
        v_version_mismatch_tolerated,
      'error_code', NULL,
      'conflict_id', NULL,
      'already_processed', false
    );
  END IF;
  RAISE EXCEPTION USING
    ERRCODE = 'P0001',
    MESSAGE = 'TC_SYNC_RESOLUTION_UNHANDLED';
END;
$function$
;

REVOKE ALL ON FUNCTION public.process_event(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.process_event(jsonb) FROM anon;
REVOKE ALL ON FUNCTION public.process_event(jsonb) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.process_event(jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public.resolve_sync_conflict(p_conflict_public_id text, p_admin_profile_public_id text, p_resolution_status text, p_resolution_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_auth_user_id uuid;
  v_person_id uuid;
  v_admin_profile_id uuid;
  v_conflict public.sync_conflicts%ROWTYPE;
  v_resolution_status text;
BEGIN
  v_auth_user_id := auth.uid();
  IF v_auth_user_id IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'TC_UNAUTHENTICATED';
  END IF;
  v_resolution_status :=
    upper(btrim(coalesce(p_resolution_status, '')));
  IF v_resolution_status NOT IN ('RESOLVED', 'DISCARDED') THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'TC_INVALID_CONFLICT_RESOLUTION_STATUS';
  END IF;
  SELECT
    per.id,
    pr.id
  INTO
    v_person_id,
    v_admin_profile_id
  FROM public.persons per
  JOIN public.profiles pr
    ON pr.person_id = per.id
  WHERE per.auth_user_id = v_auth_user_id
    AND pr.public_id =
      upper(btrim(p_admin_profile_public_id))
    AND pr.profile_type = 'ADM'
    AND pr.status = 'active'
  LIMIT 1;
  IF v_person_id IS NULL OR v_admin_profile_id IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'TC_ADMIN_FORBIDDEN';
  END IF;
  SELECT sc.*
  INTO v_conflict
  FROM public.sync_conflicts sc
  WHERE sc.public_id =
    upper(btrim(p_conflict_public_id))
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'TC_CONFLICT_NOT_FOUND';
  END IF;
  IF v_conflict.resolution_status <> 'PENDING' THEN
    RETURN jsonb_build_object(
      'success', true,
      'status', 'ALREADY_RESOLVED',
      'conflict_id', v_conflict.public_id,
      'resolution_status', v_conflict.resolution_status
    );
  END IF;
  UPDATE public.sync_conflicts
  SET
    resolution_status = v_resolution_status,
    resolved_by = v_person_id,
    resolved_at = now(),
    resolution_note = nullif(btrim(coalesce(p_resolution_note, '')), '')
  WHERE id = v_conflict.id;
  INSERT INTO public.audit_logs (
    actor_person_id,
    actor_profile_id,
    operation,
    entity_type,
    entity_public_id,
    event_id,
    result,
    metadata
  )
  VALUES (
    v_person_id,
    v_admin_profile_id,
    'RESOLVE_SYNC_CONFLICT',
    'SYNC_CONFLICT',
    v_conflict.public_id,
    v_conflict.event_id,
    v_resolution_status,
    jsonb_build_object(
      'source_entity_type', v_conflict.entity_type,
      'source_entity_id', v_conflict.entity_id,
      'reason', v_conflict.reason,
      'resolution_note',
        nullif(btrim(coalesce(p_resolution_note, '')), '')
    )
  );
  RETURN jsonb_build_object(
    'success', true,
    'status', v_resolution_status,
    'conflict_id', v_conflict.public_id,
    'event_id', v_conflict.event_id
  );
END;
$function$
;

REVOKE ALL ON FUNCTION public.resolve_sync_conflict(text,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.resolve_sync_conflict(text,text,text,text) FROM anon;
REVOKE ALL ON FUNCTION public.resolve_sync_conflict(text,text,text,text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_sync_conflict(text,text,text,text) TO service_role;


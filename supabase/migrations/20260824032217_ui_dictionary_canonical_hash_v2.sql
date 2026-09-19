CREATE OR REPLACE FUNCTION public.compile_ui_dictionary_release(p_version_code integer, p_description text, p_target_language_id uuid, p_target_variant_id uuid DEFAULT NULL::uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_version uuid;
  v_hash text;
  v_holes int;
BEGIN
  INSERT INTO public.ui_dictionary_versions(version_code,target_language_id,target_variant_id,content_hash,description)
  VALUES(p_version_code,p_target_language_id,p_target_variant_id,'PENDING',p_description)
  RETURNING id INTO v_version;

  WITH ranked AS (
    SELECT k.id key_id,tp.id trp_id,tp.language_id,tp.variant_id,
      CASE
        WHEN p_target_variant_id IS NOT NULL AND tp.language_id=p_target_language_id AND tp.variant_id=p_target_variant_id THEN 1
        WHEN tp.language_id=p_target_language_id AND tp.variant_id IS NULL THEN 2
        WHEN tp.language_id=cp.fallback_language_id AND tp.variant_id IS NULL THEN 3
      END rk,
      CASE
        WHEN p_target_variant_id IS NOT NULL AND tp.language_id=p_target_language_id AND tp.variant_id=p_target_variant_id THEN 'EXACT_VARIANT'
        WHEN tp.language_id=p_target_language_id AND tp.variant_id IS NULL THEN 'LANGUAGE_GENERAL'
        WHEN tp.language_id=cp.fallback_language_id AND tp.variant_id IS NULL THEN 'SYSTEM_FALLBACK'
      END rt,
      row_number() OVER (
        PARTITION BY k.id
        ORDER BY
          CASE
            WHEN p_target_variant_id IS NOT NULL AND tp.language_id=p_target_language_id AND tp.variant_id=p_target_variant_id THEN 1
            WHEN tp.language_id=p_target_language_id AND tp.variant_id IS NULL THEN 2
            WHEN tp.language_id=cp.fallback_language_id AND tp.variant_id IS NULL THEN 3
            ELSE 9
          END,
          (tp.consensus_status='VERIFICADA') DESC,
          tp.created_at,
          tp.id
      ) rn
    FROM public.ui_interface_keys k
    JOIN public.linguistic_context_policies cp ON cp.context_name=k.context_name
    JOIN public.linguistic_context_policy_statuses cps ON cps.policy_id=cp.id
    JOIN public.translation_proposals tp ON tp.concept_id=k.concept_id AND tp.consensus_status=cps.allowed_status
  ), winners AS (
    SELECT * FROM ranked WHERE rn=1 AND rk IS NOT NULL
  )
  INSERT INTO public.ui_dictionary_release_entries(dictionary_version_id,ui_key_id,translation_proposal_id,resolved_language_id,resolved_variant_id,resolution_type)
  SELECT v_version,key_id,trp_id,language_id,variant_id,rt FROM winners;

  SELECT count(*) INTO v_holes
  FROM public.ui_interface_keys k
  LEFT JOIN public.ui_dictionary_release_entries e ON e.dictionary_version_id=v_version AND e.ui_key_id=k.id
  LEFT JOIN public.translation_proposals tp ON tp.id=e.translation_proposal_id
  WHERE k.context_name IN('PAYMENT','LEGAL','SAFETY','IDENTITY','COMPLIANCE')
    AND(e.id IS NULL OR tp.consensus_status<>'VERIFICADA');

  IF v_holes>0 THEN
    RAISE EXCEPTION 'RELEASE_BLOCKED_CRITICAL_GAPS:%',v_holes;
  END IF;

  SELECT encode(
           extensions.digest(
             convert_to(
               COALESCE(string_agg(k.ui_key || chr(31) || tp.texto_original || chr(30), '' ORDER BY k.ui_key), ''),
               'UTF8'
             ),
             'sha256'
           ),
           'hex'
         )
  INTO v_hash
  FROM public.ui_dictionary_release_entries e
  JOIN public.ui_interface_keys k ON k.id=e.ui_key_id
  JOIN public.translation_proposals tp ON tp.id=e.translation_proposal_id
  WHERE e.dictionary_version_id=v_version;

  UPDATE public.ui_dictionary_versions
  SET content_hash=v_hash,is_released=true,released_at=now()
  WHERE id=v_version;

  RETURN v_version;
END
$function$;

CREATE OR REPLACE FUNCTION public.get_ui_dictionary_bundle(p_client_lang_id uuid, p_client_var_id uuid DEFAULT NULL::uuid, p_target_version integer DEFAULT NULL::integer)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_version uuid;
  v_code int;
  v_hash text;
  v_payload jsonb;
  v_key_count int;
BEGIN
  SELECT v.id,v.version_code,v.content_hash
  INTO v_version,v_code,v_hash
  FROM public.ui_dictionary_versions v
  WHERE v.is_released
    AND v.target_language_id=p_client_lang_id
    AND v.target_variant_id IS NOT DISTINCT FROM p_client_var_id
  ORDER BY v.version_code DESC
  LIMIT 1;

  IF v_version IS NULL THEN
    RETURN jsonb_build_object('dictionary_version',NULL,'dictionary_hash',NULL,'key_count',0,'requires_sync',false,'translations','{}'::jsonb);
  END IF;

  SELECT count(*)
  INTO v_key_count
  FROM public.ui_dictionary_release_entries e
  WHERE e.dictionary_version_id=v_version;

  IF p_target_version IS NOT NULL AND p_target_version=v_code THEN
    RETURN jsonb_build_object('dictionary_version',v_code,'dictionary_hash',v_hash,'key_count',v_key_count,'requires_sync',false,'translations','{}'::jsonb);
  END IF;

  SELECT jsonb_object_agg(k.ui_key,tp.texto_original ORDER BY k.ui_key)
  INTO v_payload
  FROM public.ui_dictionary_release_entries e
  JOIN public.ui_interface_keys k ON k.id=e.ui_key_id
  JOIN public.translation_proposals tp ON tp.id=e.translation_proposal_id
  WHERE e.dictionary_version_id=v_version;

  RETURN jsonb_build_object(
    'dictionary_version',v_code,
    'dictionary_hash',v_hash,
    'key_count',v_key_count,
    'requires_sync',true,
    'translations',COALESCE(v_payload,'{}'::jsonb)
  );
END
$function$;
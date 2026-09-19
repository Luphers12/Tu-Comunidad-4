CREATE OR REPLACE FUNCTION public.gai_attach_incident_evidence(
  p_active_profile_id uuid,
  p_incident_id uuid,
  p_evidence_id uuid,
  p_idempotency_key text,
  p_metadata jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v_person_id uuid;
  v_inc public.gai_incidents%ROWTYPE;
  v_evidence_uploader uuid;
  v_evidence_public_id text;
  v_event_id uuid;
  v_existing_event_id uuid;
  v_hash text;
  v_operation text;
  v_existing public.idempotency_records%ROWTYPE;
  v_outcome text;
  v_can_override boolean;
BEGIN
  SELECT pe.id INTO v_person_id
  FROM public.persons pe JOIN public.profiles pr ON pr.person_id=pe.id
  WHERE pe.auth_user_id=auth.uid() AND pr.id=p_active_profile_id;
  IF v_person_id IS NULL THEN RAISE EXCEPTION 'GAI_SECURITY_VIOLATION' USING ERRCODE='invalid_authorization_specification'; END IF;
  IF p_idempotency_key IS NULL OR btrim(p_idempotency_key)='' THEN RAISE EXCEPTION 'GAI_INVALID_IDEMPOTENCY_KEY' USING ERRCODE='check_violation'; END IF;

  SELECT * INTO v_inc FROM public.gai_incidents WHERE id=p_incident_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GAI_INCIDENT_NOT_FOUND' USING ERRCODE='no_data_found'; END IF;
  IF v_inc.state='CLOSED' THEN RAISE EXCEPTION 'GAI_INCIDENT_CLOSED' USING ERRCODE='object_not_in_prerequisite_state'; END IF;

  v_can_override := public.internal_has_capability(p_active_profile_id,'incident.override',v_inc.scope_type,v_inc.scope_target_id);
  IF p_active_profile_id<>v_inc.created_by_profile_id
     AND p_active_profile_id IS DISTINCT FROM v_inc.assigned_profile_id
     AND NOT public.internal_has_capability(p_active_profile_id,'incident.resolve',v_inc.scope_type,v_inc.scope_target_id)
     AND NOT v_can_override THEN
    RAISE EXCEPTION 'GAI_FORBIDDEN' USING ERRCODE='insufficient_privilege';
  END IF;

  SELECT uploader_profile_id,public_id INTO v_evidence_uploader,v_evidence_public_id
  FROM public.evidence WHERE id=p_evidence_id;
  IF v_evidence_uploader IS NULL THEN RAISE EXCEPTION 'GAI_EVIDENCE_NOT_FOUND' USING ERRCODE='no_data_found'; END IF;
  IF v_evidence_uploader<>p_active_profile_id AND NOT v_can_override THEN
    RAISE EXCEPTION 'GAI_EVIDENCE_OWNERSHIP_VIOLATION' USING ERRCODE='insufficient_privilege';
  END IF;

  v_hash := pg_catalog.encode(extensions.digest(pg_catalog.convert_to(jsonb_build_object(
    'profile',p_active_profile_id,'incident',p_incident_id,'evidence',p_evidence_id,'metadata',COALESCE(p_metadata,'{}'::jsonb)
  )::text,'UTF8'),'sha256'),'hex');
  v_operation := 'GAI_EVIDENCE::'||p_active_profile_id::text;
  INSERT INTO public.idempotency_records(operation_type,idempotency_key,person_id,request_hash,status)
  VALUES(v_operation,p_idempotency_key,v_person_id,v_hash,'IN_PROGRESS') ON CONFLICT DO NOTHING;
  SELECT * INTO v_existing FROM public.idempotency_records WHERE operation_type=v_operation AND idempotency_key=p_idempotency_key FOR UPDATE;
  IF v_existing.request_hash<>v_hash THEN RAISE EXCEPTION 'GAI_IDEMPOTENCY_PAYLOAD_MISMATCH' USING ERRCODE='unique_violation'; END IF;
  IF v_existing.status='COMPLETED' THEN RETURN v_existing.response_payload; END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_incident_id::text||':'||p_evidence_id::text,0));
  SELECT incident_event_id INTO v_existing_event_id
  FROM public.gai_incident_evidence_links
  WHERE incident_id=p_incident_id AND evidence_id=p_evidence_id;

  IF FOUND THEN
    v_outcome := 'ALREADY_LINKED';
    v_event_id := v_existing_event_id;
  ELSE
    v_event_id := gen_random_uuid();
    INSERT INTO public.gai_incident_events(id,incident_id,event_type,from_state,to_state,actor_person_id,actor_profile_id,actor_namespace,metadata)
    VALUES(v_event_id,p_incident_id,'EVIDENCE_ADDED',v_inc.state,v_inc.state,v_person_id,p_active_profile_id,'AUTH::'||auth.uid()::text,
           COALESCE(p_metadata,'{}'::jsonb)||jsonb_build_object('evidence_id',p_evidence_id,'evidence_public_id',v_evidence_public_id));
    INSERT INTO public.gai_incident_evidence_links(incident_id,evidence_id,incident_event_id)
    VALUES(p_incident_id,p_evidence_id,v_event_id);
    v_outcome := 'LINKED';
    INSERT INTO public.audit_logs(actor_person_id,actor_profile_id,operation,entity_type,entity_public_id,event_id,result,metadata)
    VALUES(v_person_id,p_active_profile_id,'GAI_EVIDENCE_LINK','GAI_INCIDENT',v_inc.public_id,NULL,'SUCCESS',
           jsonb_build_object('gai_event_id',v_event_id,'evidence_id',p_evidence_id,'evidence_public_id',v_evidence_public_id));
  END IF;

  UPDATE public.idempotency_records
  SET response_payload=jsonb_build_object('success',true,'outcome',v_outcome,'incident_id',p_incident_id,'evidence_id',p_evidence_id,'event_id',v_event_id),
      status='COMPLETED',completed_at=now()
  WHERE operation_type=v_operation AND idempotency_key=p_idempotency_key;
  RETURN jsonb_build_object('success',true,'outcome',v_outcome,'incident_id',p_incident_id,'evidence_id',p_evidence_id,'event_id',v_event_id);
END; $$;
REVOKE ALL ON FUNCTION public.gai_attach_incident_evidence(uuid,uuid,uuid,text,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gai_attach_incident_evidence(uuid,uuid,uuid,text,jsonb) TO authenticated;
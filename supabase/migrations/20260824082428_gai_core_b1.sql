-- GAI CORE B1
CREATE TYPE public.gai_severity AS ENUM ('INFO','LOW','MEDIUM','HIGH','CRITICAL');
CREATE TYPE public.gai_incident_state AS ENUM ('TRIGGERED','ACKNOWLEDGED','INVESTIGATING','RESOLVED','CLOSED');
CREATE TYPE public.gai_incident_event_type AS ENUM ('TRIGGERED','ACKNOWLEDGED','INVESTIGATING','ASSIGNED','ESCALATED','POLICY_ENFORCED','RESOLVED','REOPENED','CLOSED','EVIDENCE_ADDED');

CREATE TABLE public.gai_incident_type_policies (
  incident_type text PRIMARY KEY,
  default_severity public.gai_severity NOT NULL,
  operational boolean NOT NULL DEFAULT true,
  dedup_window_seconds integer NOT NULL DEFAULT 300 CHECK (dedup_window_seconds BETWEEN 1 AND 86400),
  default_ttl_seconds integer CHECK (default_ttl_seconds IS NULL OR default_ttl_seconds > 0),
  notify_repeat_dedup boolean NOT NULL DEFAULT false,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.gai_incidents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id text NOT NULL UNIQUE DEFAULT public.tc_generate_public_id('INC'),
  incident_type text NOT NULL REFERENCES public.gai_incident_type_policies(incident_type) ON DELETE RESTRICT,
  severity public.gai_severity NOT NULL,
  state public.gai_incident_state NOT NULL DEFAULT 'TRIGGERED',
  operational boolean NOT NULL,
  source_namespace text NOT NULL,
  source_key text,
  scope_type public.tc_scope_type NOT NULL,
  scope_target_id uuid,
  created_by_person_id uuid NOT NULL REFERENCES public.persons(id) ON DELETE RESTRICT,
  created_by_profile_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  assigned_profile_id uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  title text NOT NULL,
  summary text,
  dedup_key text,
  dedup_fingerprint text UNIQUE,
  occurred_at timestamptz NOT NULL,
  expires_at timestamptz,
  resolved_at timestamptz,
  closed_at timestamptz,
  resolution_reason text,
  closure_reason text,
  version bigint NOT NULL DEFAULT 0 CHECK (version >= 0),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_gai_scope_target_integrity CHECK (
    (scope_type='GLOBAL' AND scope_target_id IS NULL)
    OR (scope_type<>'GLOBAL' AND scope_target_id IS NOT NULL)
  ),
  CONSTRAINT chk_gai_expiry_after_occurrence CHECK (expires_at IS NULL OR expires_at > occurred_at)
);

CREATE INDEX idx_gai_incidents_scope ON public.gai_incidents(scope_type, scope_target_id, state);
CREATE INDEX idx_gai_incidents_state_severity ON public.gai_incidents(state, severity, created_at DESC);
CREATE INDEX idx_gai_incidents_assigned ON public.gai_incidents(assigned_profile_id) WHERE assigned_profile_id IS NOT NULL;

CREATE TABLE public.gai_incident_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  incident_id uuid NOT NULL REFERENCES public.gai_incidents(id) ON DELETE RESTRICT,
  event_type public.gai_incident_event_type NOT NULL,
  from_state public.gai_incident_state,
  to_state public.gai_incident_state NOT NULL,
  actor_person_id uuid NOT NULL REFERENCES public.persons(id) ON DELETE RESTRICT,
  actor_profile_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  actor_namespace text NOT NULL,
  reason text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_gai_events_incident_created ON public.gai_incident_events(incident_id, created_at, id);

CREATE TABLE public.gai_incident_entity_links (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  incident_id uuid NOT NULL REFERENCES public.gai_incidents(id) ON DELETE RESTRICT,
  entity_type text NOT NULL CHECK (entity_type IN ('MOVEMENT','ORDER','PTC','STORE','DRIVER','ROUTE','PAYMENT','DISPUTE','ADMIN')),
  entity_id uuid,
  entity_ref text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_gai_entity_locator CHECK ((entity_id IS NOT NULL) <> (entity_ref IS NOT NULL)),
  CONSTRAINT uq_gai_entity_link UNIQUE NULLS NOT DISTINCT (incident_id, entity_type, entity_id, entity_ref)
);

CREATE TABLE public.gai_incident_evidence_links (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  incident_id uuid NOT NULL REFERENCES public.gai_incidents(id) ON DELETE RESTRICT,
  evidence_id uuid NOT NULL REFERENCES public.evidence(id) ON DELETE RESTRICT,
  incident_event_id uuid REFERENCES public.gai_incident_events(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (incident_id, evidence_id)
);

CREATE TABLE public.gai_incident_recipients (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  incident_id uuid NOT NULL REFERENCES public.gai_incidents(id) ON DELETE RESTRICT,
  profile_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  channel text NOT NULL DEFAULT 'IN_APP' CHECK (channel IN ('IN_APP','PUSH','EMAIL','SMS')),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (incident_id, profile_id, channel)
);

CREATE TABLE public.gai_notification_outbox (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  incident_id uuid NOT NULL REFERENCES public.gai_incidents(id) ON DELETE RESTRICT,
  incident_event_id uuid NOT NULL REFERENCES public.gai_incident_events(id) ON DELETE RESTRICT,
  recipient_profile_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  channel text NOT NULL CHECK (channel IN ('IN_APP','PUSH','EMAIL','SMS')),
  category text NOT NULL CHECK (category IN ('OPERATIONAL','INFORMATIVE')),
  dedup_key text NOT NULL UNIQUE,
  status text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','PROCESSING','SENT','FAILED','CANCELLED')),
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  next_attempt_at timestamptz,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  sent_at timestamptz
);
CREATE INDEX idx_gai_outbox_pending ON public.gai_notification_outbox(status, next_attempt_at, created_at) WHERE status IN ('PENDING','FAILED');

CREATE OR REPLACE FUNCTION public.internal_gai_validate_incident_scope()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF NOT public.internal_validate_scope_target(NEW.scope_type, NEW.scope_target_id) THEN
    RAISE EXCEPTION 'GAI_INVALID_SCOPE_TARGET' USING ERRCODE='foreign_key_violation';
  END IF;
  RETURN NEW;
END; $$;
REVOKE ALL ON FUNCTION public.internal_gai_validate_incident_scope() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER trg_gai_validate_incident_scope BEFORE INSERT OR UPDATE OF scope_type, scope_target_id ON public.gai_incidents FOR EACH ROW EXECUTE FUNCTION public.internal_gai_validate_incident_scope();

CREATE OR REPLACE FUNCTION public.internal_gai_prevent_mutation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  RAISE EXCEPTION 'GAI_IMMUTABLE_LEDGER' USING ERRCODE='object_not_in_prerequisite_state';
END; $$;
REVOKE ALL ON FUNCTION public.internal_gai_prevent_mutation() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER trg_gai_events_immutable BEFORE UPDATE OR DELETE ON public.gai_incident_events FOR EACH ROW EXECUTE FUNCTION public.internal_gai_prevent_mutation();
CREATE TRIGGER trg_gai_entity_links_immutable BEFORE UPDATE OR DELETE ON public.gai_incident_entity_links FOR EACH ROW EXECUTE FUNCTION public.internal_gai_prevent_mutation();
CREATE TRIGGER trg_gai_evidence_links_immutable BEFORE UPDATE OR DELETE ON public.gai_incident_evidence_links FOR EACH ROW EXECUTE FUNCTION public.internal_gai_prevent_mutation();

CREATE OR REPLACE FUNCTION public.internal_gai_validate_entity_link(p_entity_type text, p_entity_id uuid, p_entity_ref text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_exists boolean := false;
BEGIN
  IF p_entity_type IN ('PAYMENT','DISPUTE') THEN
    RAISE EXCEPTION 'GAI_DEPENDENCY_UNAVAILABLE: %', p_entity_type USING ERRCODE='object_not_in_prerequisite_state';
  END IF;
  IF (p_entity_id IS NULL) = (p_entity_ref IS NULL) THEN RETURN false; END IF;
  IF p_entity_id IS NULL THEN RETURN false; END IF;
  CASE p_entity_type
    WHEN 'MOVEMENT' THEN SELECT EXISTS(SELECT 1 FROM public.movements WHERE id=p_entity_id) INTO v_exists;
    WHEN 'ORDER' THEN SELECT EXISTS(SELECT 1 FROM public.orders WHERE id=p_entity_id) INTO v_exists;
    WHEN 'PTC' THEN SELECT EXISTS(SELECT 1 FROM public.ptc_points WHERE id=p_entity_id) INTO v_exists;
    WHEN 'STORE' THEN SELECT EXISTS(SELECT 1 FROM public.profiles WHERE id=p_entity_id AND profile_type IN ('TIE','VEN')) INTO v_exists;
    WHEN 'DRIVER' THEN SELECT EXISTS(SELECT 1 FROM public.profiles WHERE id=p_entity_id AND profile_type='CON') INTO v_exists;
    WHEN 'ROUTE' THEN SELECT EXISTS(SELECT 1 FROM public.route_opportunities WHERE id=p_entity_id) INTO v_exists;
    WHEN 'ADMIN' THEN SELECT EXISTS(SELECT 1 FROM public.profiles WHERE id=p_entity_id AND profile_type='ADM') INTO v_exists;
    ELSE v_exists := false;
  END CASE;
  RETURN v_exists;
END; $$;
REVOKE ALL ON FUNCTION public.internal_gai_validate_entity_link(text,uuid,text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.internal_gai_enqueue_event_notifications(p_event_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_event_type public.gai_incident_event_type; v_incident_id uuid; v_category text;
BEGIN
  SELECT event_type, incident_id INTO v_event_type, v_incident_id FROM public.gai_incident_events WHERE id=p_event_id;
  IF v_event_type IN ('TRIGGERED','ESCALATED','POLICY_ENFORCED','REOPENED') THEN v_category := 'OPERATIONAL';
  ELSIF v_event_type IN ('ACKNOWLEDGED','CLOSED') THEN v_category := 'INFORMATIVE';
  ELSE RETURN;
  END IF;
  INSERT INTO public.gai_notification_outbox(incident_id,incident_event_id,recipient_profile_id,channel,category,dedup_key,payload)
  SELECT v_incident_id,p_event_id,r.profile_id,r.channel,v_category,
         'OUTBOX_V2::evt='||p_event_id::text||'::rec='||r.profile_id::text||'::ch='||r.channel||'::cat='||v_category,
         jsonb_build_object('incident_id',v_incident_id,'event_id',p_event_id,'category',v_category)
  FROM public.gai_incident_recipients r
  WHERE r.incident_id=v_incident_id AND r.is_active
  ON CONFLICT (dedup_key) DO NOTHING;
END; $$;
REVOKE ALL ON FUNCTION public.internal_gai_enqueue_event_notifications(uuid) FROM PUBLIC, anon, authenticated;

ALTER TABLE public.gai_incident_type_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gai_incidents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gai_incident_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gai_incident_entity_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gai_incident_evidence_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gai_incident_recipients ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gai_notification_outbox ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.gai_incident_type_policies, public.gai_incidents, public.gai_incident_events, public.gai_incident_entity_links, public.gai_incident_evidence_links, public.gai_incident_recipients, public.gai_notification_outbox FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.gai_incident_type_policies, public.gai_incidents, public.gai_incident_events, public.gai_incident_entity_links, public.gai_incident_evidence_links, public.gai_incident_recipients TO authenticated;

CREATE POLICY gai_policy_catalog_read ON public.gai_incident_type_policies FOR SELECT TO authenticated USING (is_active);
CREATE POLICY gai_incidents_read ON public.gai_incidents FOR SELECT TO authenticated USING (
  EXISTS (
    SELECT 1 FROM public.persons pe JOIN public.profiles pr ON pr.person_id=pe.id
    WHERE pe.auth_user_id=(SELECT auth.uid()) AND (
      pr.id=gai_incidents.created_by_profile_id OR pr.id=gai_incidents.assigned_profile_id OR
      public.internal_has_capability(pr.id,'incident.read',gai_incidents.scope_type,gai_incidents.scope_target_id)
    )
  )
);
CREATE POLICY gai_events_read ON public.gai_incident_events FOR SELECT TO authenticated USING (
  EXISTS (SELECT 1 FROM public.gai_incidents i WHERE i.id=gai_incident_events.incident_id)
);
CREATE POLICY gai_entity_links_read ON public.gai_incident_entity_links FOR SELECT TO authenticated USING (
  EXISTS (SELECT 1 FROM public.gai_incidents i WHERE i.id=gai_incident_entity_links.incident_id)
);
CREATE POLICY gai_evidence_links_read ON public.gai_incident_evidence_links FOR SELECT TO authenticated USING (
  EXISTS (SELECT 1 FROM public.gai_incidents i WHERE i.id=gai_incident_evidence_links.incident_id)
);
CREATE POLICY gai_recipients_read ON public.gai_incident_recipients FOR SELECT TO authenticated USING (
  EXISTS (SELECT 1 FROM public.persons pe JOIN public.profiles pr ON pr.person_id=pe.id WHERE pe.auth_user_id=(SELECT auth.uid()) AND pr.id=gai_incident_recipients.profile_id)
  OR EXISTS (SELECT 1 FROM public.gai_incidents i WHERE i.id=gai_incident_recipients.incident_id)
);

CREATE OR REPLACE FUNCTION public.gai_ingest_incident(
  p_active_profile_id uuid,
  p_incident_type text,
  p_scope_type public.tc_scope_type,
  p_scope_target_id uuid,
  p_source_namespace text,
  p_source_key text,
  p_title text,
  p_summary text,
  p_occurred_at timestamptz,
  p_idempotency_key text,
  p_dedup_key text DEFAULT NULL,
  p_expires_at timestamptz DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb,
  p_entity_type text DEFAULT NULL,
  p_entity_id uuid DEFAULT NULL,
  p_recipient_profile_ids uuid[] DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v_person_id uuid; v_profile_public_id text; v_policy public.gai_incident_type_policies%ROWTYPE;
  v_hash text; v_operation text; v_existing public.idempotency_records%ROWTYPE;
  v_bucket bigint; v_fingerprint text; v_incident_id uuid; v_incident_public_id text; v_event_id uuid;
  v_outcome text; v_state public.gai_incident_state; v_rec uuid; v_expiry timestamptz;
BEGIN
  SELECT pe.id,pr.public_id INTO v_person_id,v_profile_public_id
  FROM public.persons pe JOIN public.profiles pr ON pr.person_id=pe.id
  WHERE pe.auth_user_id=auth.uid() AND pr.id=p_active_profile_id;
  IF v_person_id IS NULL THEN RAISE EXCEPTION 'GAI_SECURITY_VIOLATION' USING ERRCODE='invalid_authorization_specification'; END IF;
  IF NOT public.internal_validate_scope_target(p_scope_type,p_scope_target_id) THEN RAISE EXCEPTION 'GAI_INVALID_SCOPE_TARGET' USING ERRCODE='foreign_key_violation'; END IF;
  IF NOT public.internal_has_capability(p_active_profile_id,'incident.ingest',p_scope_type,p_scope_target_id) THEN RAISE EXCEPTION 'GAI_FORBIDDEN' USING ERRCODE='insufficient_privilege'; END IF;
  SELECT * INTO v_policy FROM public.gai_incident_type_policies WHERE incident_type=p_incident_type AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'GAI_INCIDENT_TYPE_NOT_FOUND' USING ERRCODE='no_data_found'; END IF;
  IF p_occurred_at IS NULL OR p_title IS NULL OR btrim(p_title)='' OR p_source_namespace IS NULL OR btrim(p_source_namespace)='' OR p_idempotency_key IS NULL OR btrim(p_idempotency_key)='' THEN
    RAISE EXCEPTION 'GAI_INVALID_ARGUMENT' USING ERRCODE='check_violation';
  END IF;
  IF p_entity_type IS NOT NULL OR p_entity_id IS NOT NULL THEN
    IF p_entity_type IS NULL OR NOT public.internal_gai_validate_entity_link(upper(p_entity_type),p_entity_id,NULL) THEN RAISE EXCEPTION 'GAI_INVALID_ENTITY_LINK' USING ERRCODE='foreign_key_violation'; END IF;
  END IF;
  v_expiry := COALESCE(p_expires_at, CASE WHEN v_policy.default_ttl_seconds IS NULL THEN NULL ELSE p_occurred_at + make_interval(secs=>v_policy.default_ttl_seconds) END);
  IF v_expiry IS NOT NULL AND v_expiry<=p_occurred_at THEN RAISE EXCEPTION 'GAI_INVALID_EXPIRY' USING ERRCODE='check_violation'; END IF;
  IF p_dedup_key IS NOT NULL THEN
    v_bucket := floor(extract(epoch from p_occurred_at)/v_policy.dedup_window_seconds)::bigint;
    v_fingerprint := pg_catalog.encode(extensions.digest(pg_catalog.convert_to(p_incident_type||chr(31)||p_source_namespace||chr(31)||coalesce(p_source_key,'')||chr(31)||p_dedup_key||chr(31)||v_bucket::text,'UTF8'),'sha256'),'hex');
  END IF;
  v_hash := pg_catalog.encode(extensions.digest(pg_catalog.convert_to(jsonb_build_object(
    'active_profile_id',p_active_profile_id,'incident_type',p_incident_type,'scope_type',p_scope_type,'scope_target_id',p_scope_target_id,
    'source_namespace',p_source_namespace,'source_key',p_source_key,'title',p_title,'summary',p_summary,'occurred_at',p_occurred_at,
    'dedup_key',p_dedup_key,'expires_at',v_expiry,'metadata',COALESCE(p_metadata,'{}'::jsonb),'entity_type',p_entity_type,'entity_id',p_entity_id,
    'recipients',to_jsonb(p_recipient_profile_ids)
  )::text,'UTF8'),'sha256'),'hex');
  v_operation := 'GAI_INGEST::'||p_active_profile_id::text;
  INSERT INTO public.idempotency_records(operation_type,idempotency_key,person_id,request_hash,status)
  VALUES(v_operation,p_idempotency_key,v_person_id,v_hash,'IN_PROGRESS') ON CONFLICT DO NOTHING;
  SELECT * INTO v_existing FROM public.idempotency_records WHERE operation_type=v_operation AND idempotency_key=p_idempotency_key FOR UPDATE;
  IF v_existing.request_hash<>v_hash THEN RAISE EXCEPTION 'GAI_IDEMPOTENCY_PAYLOAD_MISMATCH' USING ERRCODE='unique_violation'; END IF;
  IF v_existing.status='COMPLETED' THEN RETURN v_existing.response_payload; END IF;
  IF v_fingerprint IS NOT NULL THEN
    INSERT INTO public.gai_incidents(incident_type,severity,operational,source_namespace,source_key,scope_type,scope_target_id,created_by_person_id,created_by_profile_id,title,summary,dedup_key,dedup_fingerprint,occurred_at,expires_at,metadata)
    VALUES(p_incident_type,v_policy.default_severity,v_policy.operational,p_source_namespace,p_source_key,p_scope_type,p_scope_target_id,v_person_id,p_active_profile_id,p_title,p_summary,p_dedup_key,v_fingerprint,p_occurred_at,v_expiry,COALESCE(p_metadata,'{}'::jsonb))
    ON CONFLICT (dedup_fingerprint) DO NOTHING RETURNING id,public_id INTO v_incident_id,v_incident_public_id;
  ELSE
    INSERT INTO public.gai_incidents(incident_type,severity,operational,source_namespace,source_key,scope_type,scope_target_id,created_by_person_id,created_by_profile_id,title,summary,occurred_at,expires_at,metadata)
    VALUES(p_incident_type,v_policy.default_severity,v_policy.operational,p_source_namespace,p_source_key,p_scope_type,p_scope_target_id,v_person_id,p_active_profile_id,p_title,p_summary,p_occurred_at,v_expiry,COALESCE(p_metadata,'{}'::jsonb))
    RETURNING id,public_id INTO v_incident_id,v_incident_public_id;
  END IF;
  IF v_incident_id IS NULL THEN
    SELECT id,public_id,state INTO v_incident_id,v_incident_public_id,v_state FROM public.gai_incidents WHERE dedup_fingerprint=v_fingerprint FOR UPDATE;
    v_outcome := 'DEDUPLICATED';
    INSERT INTO public.gai_incident_events(incident_id,event_type,from_state,to_state,actor_person_id,actor_profile_id,actor_namespace,metadata)
    VALUES(v_incident_id,'TRIGGERED',v_state,v_state,v_person_id,p_active_profile_id,'AUTH::'||auth.uid()::text,jsonb_build_object('deduplicated',true,'source_key',p_source_key)) RETURNING id INTO v_event_id;
    IF v_policy.notify_repeat_dedup THEN PERFORM public.internal_gai_enqueue_event_notifications(v_event_id); END IF;
  ELSE
    v_outcome := 'CREATED';
    INSERT INTO public.gai_incident_recipients(incident_id,profile_id,channel) VALUES(v_incident_id,p_active_profile_id,'IN_APP') ON CONFLICT DO NOTHING;
    IF p_recipient_profile_ids IS NOT NULL THEN
      FOREACH v_rec IN ARRAY p_recipient_profile_ids LOOP
        IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=v_rec) THEN RAISE EXCEPTION 'GAI_RECIPIENT_NOT_FOUND' USING ERRCODE='foreign_key_violation'; END IF;
        INSERT INTO public.gai_incident_recipients(incident_id,profile_id,channel) VALUES(v_incident_id,v_rec,'IN_APP') ON CONFLICT DO NOTHING;
      END LOOP;
    END IF;
    IF p_entity_type IS NOT NULL THEN
      INSERT INTO public.gai_incident_entity_links(incident_id,entity_type,entity_id) VALUES(v_incident_id,upper(p_entity_type),p_entity_id);
    END IF;
    INSERT INTO public.gai_incident_events(incident_id,event_type,from_state,to_state,actor_person_id,actor_profile_id,actor_namespace,metadata)
    VALUES(v_incident_id,'TRIGGERED',NULL,'TRIGGERED',v_person_id,p_active_profile_id,'AUTH::'||auth.uid()::text,jsonb_build_object('deduplicated',false,'source_key',p_source_key)) RETURNING id INTO v_event_id;
    PERFORM public.internal_gai_enqueue_event_notifications(v_event_id);
  END IF;
  INSERT INTO public.audit_logs(actor_person_id,actor_profile_id,operation,entity_type,entity_public_id,event_id,result,metadata)
  VALUES(v_person_id,p_active_profile_id,'GAI_INCIDENT_INGEST','GAI_INCIDENT',v_incident_public_id,v_event_id::text,'SUCCESS',jsonb_build_object('outcome',v_outcome,'incident_type',p_incident_type,'scope_type',p_scope_type,'scope_target_id',p_scope_target_id));
  UPDATE public.idempotency_records SET response_payload=jsonb_build_object('success',true,'outcome',v_outcome,'incident_id',v_incident_id,'incident_public_id',v_incident_public_id,'event_id',v_event_id),status='COMPLETED',completed_at=now()
  WHERE operation_type=v_operation AND idempotency_key=p_idempotency_key;
  RETURN jsonb_build_object('success',true,'outcome',v_outcome,'incident_id',v_incident_id,'incident_public_id',v_incident_public_id,'event_id',v_event_id);
END; $$;
REVOKE ALL ON FUNCTION public.gai_ingest_incident(uuid,text,public.tc_scope_type,uuid,text,text,text,text,timestamptz,text,text,timestamptz,jsonb,text,uuid,uuid[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gai_ingest_incident(uuid,text,public.tc_scope_type,uuid,text,text,text,text,timestamptz,text,text,timestamptz,jsonb,text,uuid,uuid[]) TO authenticated;

CREATE OR REPLACE FUNCTION public.gai_transition_incident(
  p_active_profile_id uuid,
  p_incident_id uuid,
  p_action text,
  p_idempotency_key text,
  p_reason text DEFAULT NULL,
  p_assigned_profile_id uuid DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v_person_id uuid; v_inc public.gai_incidents%ROWTYPE; v_action text:=upper(p_action); v_required_cap text;
  v_new_state public.gai_incident_state; v_event_type public.gai_incident_event_type; v_event_id uuid;
  v_hash text; v_operation text; v_existing public.idempotency_records%ROWTYPE; v_new_severity public.gai_severity;
BEGIN
  SELECT pe.id INTO v_person_id FROM public.persons pe JOIN public.profiles pr ON pr.person_id=pe.id WHERE pe.auth_user_id=auth.uid() AND pr.id=p_active_profile_id;
  IF v_person_id IS NULL THEN RAISE EXCEPTION 'GAI_SECURITY_VIOLATION' USING ERRCODE='invalid_authorization_specification'; END IF;
  SELECT * INTO v_inc FROM public.gai_incidents WHERE id=p_incident_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GAI_INCIDENT_NOT_FOUND' USING ERRCODE='no_data_found'; END IF;
  CASE v_action
    WHEN 'ACKNOWLEDGE' THEN v_required_cap:='incident.acknowledge';
    WHEN 'START_INVESTIGATION' THEN v_required_cap:='incident.assign';
    WHEN 'ASSIGN' THEN v_required_cap:='incident.assign';
    WHEN 'RESOLVE' THEN v_required_cap:='incident.resolve';
    WHEN 'CLOSE' THEN v_required_cap:='incident.close';
    WHEN 'REOPEN' THEN v_required_cap:='incident.override';
    WHEN 'ESCALATE' THEN v_required_cap:='incident.override';
    WHEN 'POLICY_ENFORCE' THEN v_required_cap:='incident.override';
    ELSE RAISE EXCEPTION 'GAI_UNSUPPORTED_ACTION' USING ERRCODE='check_violation';
  END CASE;
  IF NOT public.internal_has_capability(p_active_profile_id,v_required_cap,v_inc.scope_type,v_inc.scope_target_id) THEN RAISE EXCEPTION 'GAI_FORBIDDEN' USING ERRCODE='insufficient_privilege'; END IF;
  v_hash := pg_catalog.encode(extensions.digest(pg_catalog.convert_to(jsonb_build_object('profile',p_active_profile_id,'incident',p_incident_id,'action',v_action,'reason',p_reason,'assigned',p_assigned_profile_id,'metadata',COALESCE(p_metadata,'{}'::jsonb))::text,'UTF8'),'sha256'),'hex');
  v_operation := 'GAI_TRANSITION::'||p_active_profile_id::text;
  INSERT INTO public.idempotency_records(operation_type,idempotency_key,person_id,request_hash,status) VALUES(v_operation,p_idempotency_key,v_person_id,v_hash,'IN_PROGRESS') ON CONFLICT DO NOTHING;
  SELECT * INTO v_existing FROM public.idempotency_records WHERE operation_type=v_operation AND idempotency_key=p_idempotency_key FOR UPDATE;
  IF v_existing.request_hash<>v_hash THEN RAISE EXCEPTION 'GAI_IDEMPOTENCY_PAYLOAD_MISMATCH' USING ERRCODE='unique_violation'; END IF;
  IF v_existing.status='COMPLETED' THEN RETURN v_existing.response_payload; END IF;
  v_new_state := v_inc.state;
  v_new_severity := v_inc.severity;
  CASE v_action
    WHEN 'ACKNOWLEDGE' THEN
      IF v_inc.state<>'TRIGGERED' THEN RAISE EXCEPTION 'GAI_INVALID_TRANSITION' USING ERRCODE='object_not_in_prerequisite_state'; END IF;
      v_new_state:='ACKNOWLEDGED'; v_event_type:='ACKNOWLEDGED';
    WHEN 'START_INVESTIGATION' THEN
      IF v_inc.state NOT IN ('TRIGGERED','ACKNOWLEDGED') THEN RAISE EXCEPTION 'GAI_INVALID_TRANSITION' USING ERRCODE='object_not_in_prerequisite_state'; END IF;
      v_new_state:='INVESTIGATING'; v_event_type:='INVESTIGATING';
    WHEN 'ASSIGN' THEN
      IF v_inc.state='CLOSED' OR p_assigned_profile_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=p_assigned_profile_id) THEN RAISE EXCEPTION 'GAI_INVALID_ASSIGNMENT' USING ERRCODE='foreign_key_violation'; END IF;
      v_event_type:='ASSIGNED';
    WHEN 'ESCALATE' THEN
      IF v_inc.state IN ('RESOLVED','CLOSED') THEN RAISE EXCEPTION 'GAI_INVALID_TRANSITION' USING ERRCODE='object_not_in_prerequisite_state'; END IF;
      v_new_severity := CASE v_inc.severity WHEN 'INFO' THEN 'LOW' WHEN 'LOW' THEN 'MEDIUM' WHEN 'MEDIUM' THEN 'HIGH' ELSE 'CRITICAL' END;
      v_event_type:='ESCALATED';
    WHEN 'POLICY_ENFORCE' THEN
      IF v_inc.state='CLOSED' OR p_reason IS NULL OR btrim(p_reason)='' THEN RAISE EXCEPTION 'GAI_REASON_REQUIRED' USING ERRCODE='check_violation'; END IF;
      v_event_type:='POLICY_ENFORCED';
    WHEN 'RESOLVE' THEN
      IF v_inc.state NOT IN ('TRIGGERED','ACKNOWLEDGED','INVESTIGATING') OR p_reason IS NULL OR btrim(p_reason)='' THEN RAISE EXCEPTION 'GAI_INVALID_TRANSITION' USING ERRCODE='object_not_in_prerequisite_state'; END IF;
      v_new_state:='RESOLVED'; v_event_type:='RESOLVED';
    WHEN 'REOPEN' THEN
      IF v_inc.state<>'RESOLVED' OR p_reason IS NULL OR btrim(p_reason)='' THEN RAISE EXCEPTION 'GAI_INVALID_TRANSITION' USING ERRCODE='object_not_in_prerequisite_state'; END IF;
      v_new_state:='INVESTIGATING'; v_event_type:='REOPENED';
    WHEN 'CLOSE' THEN
      IF v_inc.state<>'RESOLVED' OR p_reason IS NULL OR btrim(p_reason)='' THEN RAISE EXCEPTION 'GAI_INVALID_TRANSITION' USING ERRCODE='object_not_in_prerequisite_state'; END IF;
      v_new_state:='CLOSED'; v_event_type:='CLOSED';
  END CASE;
  UPDATE public.gai_incidents SET
    state=v_new_state,
    severity=v_new_severity,
    assigned_profile_id=CASE WHEN v_action='ASSIGN' THEN p_assigned_profile_id ELSE assigned_profile_id END,
    resolved_at=CASE WHEN v_action='RESOLVE' THEN now() WHEN v_action='REOPEN' THEN NULL ELSE resolved_at END,
    resolution_reason=CASE WHEN v_action='RESOLVE' THEN p_reason WHEN v_action='REOPEN' THEN NULL ELSE resolution_reason END,
    closed_at=CASE WHEN v_action='CLOSE' THEN now() ELSE closed_at END,
    closure_reason=CASE WHEN v_action='CLOSE' THEN p_reason ELSE closure_reason END,
    version=version+1, updated_at=now()
  WHERE id=p_incident_id;
  IF v_action='ASSIGN' THEN INSERT INTO public.gai_incident_recipients(incident_id,profile_id,channel) VALUES(p_incident_id,p_assigned_profile_id,'IN_APP') ON CONFLICT DO NOTHING; END IF;
  INSERT INTO public.gai_incident_events(incident_id,event_type,from_state,to_state,actor_person_id,actor_profile_id,actor_namespace,reason,metadata)
  VALUES(p_incident_id,v_event_type,v_inc.state,v_new_state,v_person_id,p_active_profile_id,'AUTH::'||auth.uid()::text,p_reason,
         COALESCE(p_metadata,'{}'::jsonb)||jsonb_build_object('previous_severity',v_inc.severity,'new_severity',v_new_severity,'assigned_profile_id',p_assigned_profile_id)) RETURNING id INTO v_event_id;
  PERFORM public.internal_gai_enqueue_event_notifications(v_event_id);
  INSERT INTO public.audit_logs(actor_person_id,actor_profile_id,operation,entity_type,entity_public_id,event_id,result,metadata)
  VALUES(v_person_id,p_active_profile_id,'GAI_INCIDENT_TRANSITION','GAI_INCIDENT',v_inc.public_id,v_event_id::text,'SUCCESS',jsonb_build_object('action',v_action,'from_state',v_inc.state,'to_state',v_new_state));
  UPDATE public.idempotency_records SET response_payload=jsonb_build_object('success',true,'outcome','APPLIED','incident_id',p_incident_id,'event_id',v_event_id,'state',v_new_state,'severity',v_new_severity),status='COMPLETED',completed_at=now()
  WHERE operation_type=v_operation AND idempotency_key=p_idempotency_key;
  RETURN jsonb_build_object('success',true,'outcome','APPLIED','incident_id',p_incident_id,'event_id',v_event_id,'state',v_new_state,'severity',v_new_severity);
END; $$;
REVOKE ALL ON FUNCTION public.gai_transition_incident(uuid,uuid,text,text,text,uuid,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gai_transition_incident(uuid,uuid,text,text,text,uuid,jsonb) TO authenticated;

INSERT INTO public.gai_incident_type_policies(incident_type,default_severity,operational,dedup_window_seconds,default_ttl_seconds,notify_repeat_dedup) VALUES
('ROUTE_DEVIATION','HIGH',true,300,21600,false),
('ROUTE_BLOCKED','HIGH',true,300,21600,false),
('CUSTODY_MISMATCH','CRITICAL',true,300,43200,false),
('PACKAGE_DAMAGED','HIGH',true,600,86400,false),
('PACKAGE_MISSING','CRITICAL',true,300,86400,false),
('DELIVERY_EXCEPTION','MEDIUM',true,600,43200,false),
('COLD_CHAIN_RISK','CRITICAL',true,300,21600,false),
('PTC_EXCEPTION','HIGH',true,600,43200,false),
('STORE_EXCEPTION','MEDIUM',true,600,43200,false),
('DRIVER_SAFETY','CRITICAL',true,300,21600,false),
('SECURITY_ALERT','CRITICAL',true,300,21600,false),
('SYSTEM_ALERT','HIGH',true,300,21600,false),
('GENERAL_INFORMATION','INFO',false,1800,86400,false)
ON CONFLICT (incident_type) DO NOTHING;
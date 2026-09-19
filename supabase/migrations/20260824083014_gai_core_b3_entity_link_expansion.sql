ALTER TABLE public.gai_incident_entity_links DROP CONSTRAINT gai_incident_entity_links_entity_type_check;
ALTER TABLE public.gai_incident_entity_links ADD CONSTRAINT gai_incident_entity_links_entity_type_check
CHECK (entity_type IN ('MOVEMENT','ORDER','PACKAGE','CUSTODY','PTC','STORE','DRIVER','ROUTE','PAYMENT','DISPUTE','ADMIN'));

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
    WHEN 'PACKAGE' THEN SELECT EXISTS(SELECT 1 FROM public.packages WHERE id=p_entity_id) INTO v_exists;
    WHEN 'CUSTODY' THEN SELECT EXISTS(SELECT 1 FROM public.custody_events WHERE id=p_entity_id) INTO v_exists;
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
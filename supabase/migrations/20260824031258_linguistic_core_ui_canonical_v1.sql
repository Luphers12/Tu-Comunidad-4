CREATE EXTENSION IF NOT EXISTS pg_trgm SCHEMA extensions;

CREATE SEQUENCE public.lan_seq START 1;
CREATE SEQUENCE public.lvar_seq START 1;
CREATE SEQUENCE public.src_seq START 1;
CREATE SEQUENCE public.orth_seq START 1;
CREATE SEQUENCE public.ret_seq START 1;
CREATE SEQUENCE public.consent_seq START 1;
CREATE SEQUENCE public.cpt_seq START 1;
CREATE SEQUENCE public.trp_seq START 1;
CREATE SEQUENCE public.audl_seq START 1;
CREATE SEQUENCE public.lng_seq START 1;
CREATE SEQUENCE public.rev_seq START 1;
CREATE SEQUENCE public.uiky_seq START 1;
CREATE SEQUENCE public.uiver_seq START 1;

CREATE TABLE public.languages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id text UNIQUE NOT NULL DEFAULT ('LAN-'||lpad(nextval('public.lan_seq')::text,4,'0')),
  name text NOT NULL UNIQUE,
  native_name text,
  iso_code text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.language_variants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id text UNIQUE NOT NULL DEFAULT ('LVAR-'||lpad(nextval('public.lvar_seq')::text,4,'0')),
  language_id uuid NOT NULL REFERENCES public.languages(id) ON DELETE RESTRICT,
  name text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(language_id,id), UNIQUE(language_id,name)
);
CREATE TABLE public.linguistic_sources (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id text UNIQUE NOT NULL DEFAULT ('SRC-'||lpad(nextval('public.src_seq')::text,4,'0')),
  title text NOT NULL,
  authority text NOT NULL,
  source_type text NOT NULL CHECK (source_type IN ('ACADEMIC_PUBLICATION','COMMUNITY_CONSENSUS','ORAL_TRADITION','LEGAL_DECREE','OTHER')),
  publication_year int,
  rights_status text NOT NULL,
  license_type text,
  reproduction_permission boolean NOT NULL DEFAULT false,
  citation_reference text NOT NULL,
  evidence_bucket text,
  evidence_object_path text,
  verified_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((evidence_bucket IS NULL)=(evidence_object_path IS NULL))
);
CREATE TABLE public.language_variant_territories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  variant_id uuid NOT NULL REFERENCES public.language_variants(id) ON DELETE RESTRICT,
  department_id uuid REFERENCES public.departments(id) ON DELETE RESTRICT,
  municipality_id uuid REFERENCES public.municipalities(id) ON DELETE RESTRICT,
  community_id uuid REFERENCES public.communities(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'DOCUMENTED',
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK(num_nonnulls(department_id,municipality_id,community_id)=1)
);
CREATE UNIQUE INDEX uq_lvt_department ON public.language_variant_territories(variant_id,department_id) WHERE department_id IS NOT NULL;
CREATE UNIQUE INDEX uq_lvt_municipality ON public.language_variant_territories(variant_id,municipality_id) WHERE municipality_id IS NOT NULL;
CREATE UNIQUE INDEX uq_lvt_community ON public.language_variant_territories(variant_id,community_id) WHERE community_id IS NOT NULL;
CREATE TABLE public.language_variant_territory_sources (
  territory_id uuid NOT NULL REFERENCES public.language_variant_territories(id) ON DELETE CASCADE,
  source_id uuid NOT NULL REFERENCES public.linguistic_sources(id) ON DELETE RESTRICT,
  PRIMARY KEY(territory_id,source_id)
);
CREATE TABLE public.orthography_versions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id text UNIQUE NOT NULL DEFAULT ('ORTH-'||lpad(nextval('public.orth_seq')::text,4,'0')),
  language_id uuid NOT NULL REFERENCES public.languages(id) ON DELETE RESTRICT,
  variant_id uuid,
  name text NOT NULL,
  authority text,
  effective_from date,
  effective_to date,
  status text NOT NULL CHECK(status IN ('DRAFT','ACTIVE','RETIRED')),
  created_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY(language_id,variant_id) REFERENCES public.language_variants(language_id,id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX uq_active_orth_general ON public.orthography_versions(language_id) WHERE variant_id IS NULL AND status='ACTIVE';
CREATE UNIQUE INDEX uq_active_orth_variant ON public.orthography_versions(language_id,variant_id) WHERE variant_id IS NOT NULL AND status='ACTIVE';
CREATE TABLE public.orthography_normalization_rules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  orthography_version_id uuid NOT NULL UNIQUE REFERENCES public.orthography_versions(id) ON DELETE RESTRICT,
  punctuation_remove_regex text,
  character_mappings jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.orthography_version_sources (
  orthography_version_id uuid NOT NULL REFERENCES public.orthography_versions(id) ON DELETE CASCADE,
  source_id uuid NOT NULL REFERENCES public.linguistic_sources(id) ON DELETE RESTRICT,
  PRIMARY KEY(orthography_version_id,source_id)
);
CREATE TABLE public.legal_retention_policies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id text UNIQUE NOT NULL DEFAULT ('RET-'||lpad(nextval('public.ret_seq')::text,4,'0')),
  policy_code text UNIQUE NOT NULL,
  description text NOT NULL,
  retention_days int,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.linguistic_consents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id text UNIQUE NOT NULL DEFAULT ('CONS-'||lpad(nextval('public.consent_seq')::text,4,'0')),
  person_id uuid NOT NULL REFERENCES public.persons(id) ON DELETE RESTRICT,
  terms_version text NOT NULL,
  usage_scope text NOT NULL,
  license_type text NOT NULL,
  retention_policy_id uuid NOT NULL REFERENCES public.legal_retention_policies(id) ON DELETE RESTRICT,
  evidence_bucket text,
  evidence_object_path text,
  granted_at timestamptz NOT NULL,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK((evidence_bucket IS NULL)=(evidence_object_path IS NULL)),
  CHECK(revoked_at IS NULL OR revoked_at>=granted_at)
);
CREATE TABLE public.user_language_preferences (
  person_id uuid PRIMARY KEY REFERENCES public.persons(id) ON DELETE RESTRICT,
  primary_language_id uuid NOT NULL REFERENCES public.languages(id) ON DELETE RESTRICT,
  primary_variant_id uuid,
  secondary_language_id uuid REFERENCES public.languages(id) ON DELETE RESTRICT,
  updated_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY(primary_language_id,primary_variant_id) REFERENCES public.language_variants(language_id,id) ON DELETE RESTRICT
);
CREATE TABLE public.linguistic_context_policies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  context_name text UNIQUE NOT NULL,
  fallback_language_id uuid NOT NULL REFERENCES public.languages(id) ON DELETE RESTRICT,
  allow_fuzzy boolean NOT NULL DEFAULT false,
  is_active boolean NOT NULL DEFAULT true
);
CREATE TABLE public.linguistic_context_policy_statuses (
  policy_id uuid NOT NULL REFERENCES public.linguistic_context_policies(id) ON DELETE CASCADE,
  allowed_status text NOT NULL CHECK(allowed_status IN ('SUGERIDA','EN_REVISION','APROBADA_COMUNITARIA','VERIFICADA')),
  PRIMARY KEY(policy_id,allowed_status)
);
CREATE TABLE public.master_concepts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id text UNIQUE NOT NULL DEFAULT ('CPT-'||lpad(nextval('public.cpt_seq')::text,4,'0')),
  semantic_code text UNIQUE NOT NULL,
  conceptual_name text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.translation_proposals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id text UNIQUE NOT NULL DEFAULT ('TRP-'||lpad(nextval('public.trp_seq')::text,4,'0')),
  concept_id uuid NOT NULL REFERENCES public.master_concepts(id) ON DELETE RESTRICT,
  language_id uuid NOT NULL REFERENCES public.languages(id) ON DELETE RESTRICT,
  variant_id uuid,
  orthography_version_id uuid REFERENCES public.orthography_versions(id) ON DELETE RESTRICT,
  texto_original text NOT NULL,
  texto_clean_input text NOT NULL,
  texto_normalized_unicode text NOT NULL,
  texto_search_folded text NOT NULL,
  normalization_transformations text[] NOT NULL DEFAULT '{}'::text[],
  consensus_status text NOT NULL DEFAULT 'SUGERIDA' CHECK(consensus_status IN ('SUGERIDA','EN_REVISION','APROBADA_COMUNITARIA','VERIFICADA','CONFLICTO','MAL_ESCRITA','VARIANTE_DIFERENTE','NECESITA_CONTEXTO','RECHAZADA')),
  created_by_person_id uuid REFERENCES public.persons(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY(language_id,variant_id) REFERENCES public.language_variants(language_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_trp_concept_lang_var_status ON public.translation_proposals(concept_id,language_id,variant_id,consensus_status);
CREATE INDEX idx_trp_folded_trgm ON public.translation_proposals USING gin(texto_search_folded extensions.gin_trgm_ops);
CREATE TABLE public.translation_proposal_sources (
  proposal_id uuid NOT NULL REFERENCES public.translation_proposals(id) ON DELETE CASCADE,
  source_id uuid NOT NULL REFERENCES public.linguistic_sources(id) ON DELETE RESTRICT,
  PRIMARY KEY(proposal_id,source_id)
);
CREATE TABLE public.linguistic_audios (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id text UNIQUE NOT NULL DEFAULT ('AUDL-'||lpad(nextval('public.audl_seq')::text,4,'0')),
  translation_id uuid NOT NULL REFERENCES public.translation_proposals(id) ON DELETE RESTRICT,
  speaker_person_id uuid NOT NULL REFERENCES public.persons(id) ON DELETE RESTRICT,
  consent_id uuid NOT NULL REFERENCES public.linguistic_consents(id) ON DELETE RESTRICT,
  storage_bucket_id text NOT NULL,
  storage_object_path text NOT NULL,
  status text NOT NULL DEFAULT 'SUGERIDO' CHECK(status IN ('SUGERIDO','EN_REVISION','APROBADO','VERIFICADO','RECHAZADO','RETIRADO')),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(storage_bucket_id,storage_object_path)
);
CREATE TABLE public.linguistic_contributors (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id text UNIQUE NOT NULL DEFAULT ('LNG-'||lpad(nextval('public.lng_seq')::text,4,'0')),
  person_id uuid NOT NULL UNIQUE REFERENCES public.persons(id) ON DELETE RESTRICT,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.linguistic_reputation_matrix (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contributor_id uuid NOT NULL REFERENCES public.linguistic_contributors(id) ON DELETE RESTRICT,
  language_id uuid NOT NULL REFERENCES public.languages(id) ON DELETE RESTRICT,
  variant_id uuid,
  competency_domain text NOT NULL,
  weight numeric(5,4) NOT NULL DEFAULT 1.0 CHECK(weight BETWEEN 0.75 AND 1.30),
  evidence_count int NOT NULL DEFAULT 0 CHECK(evidence_count>=0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY(language_id,variant_id) REFERENCES public.language_variants(language_id,id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX uq_rep_general ON public.linguistic_reputation_matrix(contributor_id,language_id,competency_domain) WHERE variant_id IS NULL;
CREATE UNIQUE INDEX uq_rep_variant ON public.linguistic_reputation_matrix(contributor_id,language_id,variant_id,competency_domain) WHERE variant_id IS NOT NULL;
CREATE TABLE public.linguistic_reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id text UNIQUE NOT NULL DEFAULT ('REV-'||lpad(nextval('public.rev_seq')::text,4,'0')),
  translation_id uuid REFERENCES public.translation_proposals(id) ON DELETE RESTRICT,
  audio_id uuid REFERENCES public.linguistic_audios(id) ON DELETE RESTRICT,
  reviewer_person_id uuid NOT NULL REFERENCES public.persons(id) ON DELETE RESTRICT,
  verdict text NOT NULL CHECK(verdict IN ('CORRECTA','CORRECTA_VARIANTE','VARIANTE_DIFERENTE','MAL_ESCRITA','SIGNIFICADO_INCORRECTO','PRONUNCIACION_INCORRECTA','NECESITA_CONTEXTO','DUPLICADA','RECHAZADA')),
  observation text,
  is_withdrawn boolean NOT NULL DEFAULT false,
  version int NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK(num_nonnulls(translation_id,audio_id)=1)
);
CREATE UNIQUE INDEX uq_review_trp ON public.linguistic_reviews(reviewer_person_id,translation_id) WHERE translation_id IS NOT NULL;
CREATE UNIQUE INDEX uq_review_audio ON public.linguistic_reviews(reviewer_person_id,audio_id) WHERE audio_id IS NOT NULL;
CREATE TABLE public.linguistic_reviews_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  review_id uuid NOT NULL REFERENCES public.linguistic_reviews(id) ON DELETE RESTRICT,
  version int NOT NULL,
  verdict text NOT NULL,
  observation text,
  is_withdrawn boolean NOT NULL,
  changed_at timestamptz NOT NULL DEFAULT now(),
  changed_by uuid
);
CREATE TABLE public.concept_product_links (
  concept_id uuid NOT NULL REFERENCES public.master_concepts(id) ON DELETE RESTRICT,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  is_active boolean NOT NULL DEFAULT true,
  PRIMARY KEY(concept_id,product_id)
);
CREATE TABLE public.ui_dictionary_versions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id text UNIQUE NOT NULL DEFAULT ('UIVER-'||lpad(nextval('public.uiver_seq')::text,4,'0')),
  version_code int NOT NULL,
  target_language_id uuid NOT NULL REFERENCES public.languages(id) ON DELETE RESTRICT,
  target_variant_id uuid,
  content_hash varchar(64) NOT NULL,
  description text,
  is_released boolean NOT NULL DEFAULT false,
  released_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY(target_language_id,target_variant_id) REFERENCES public.language_variants(language_id,id) ON DELETE RESTRICT,
  CHECK(content_hash~'^[0-9a-f]{64}$' OR content_hash='PENDING')
);
CREATE UNIQUE INDEX uq_uiver_general ON public.ui_dictionary_versions(version_code,target_language_id) WHERE target_variant_id IS NULL;
CREATE UNIQUE INDEX uq_uiver_variant ON public.ui_dictionary_versions(version_code,target_language_id,target_variant_id) WHERE target_variant_id IS NOT NULL;
CREATE TABLE public.ui_interface_keys (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id text UNIQUE NOT NULL DEFAULT ('UIKY-'||lpad(nextval('public.uiky_seq')::text,5,'0')),
  ui_key text UNIQUE NOT NULL,
  concept_id uuid NOT NULL REFERENCES public.master_concepts(id) ON DELETE RESTRICT,
  namespace text NOT NULL,
  context_name text NOT NULL REFERENCES public.linguistic_context_policies(context_name) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_ui_key_namespace ON public.ui_interface_keys(namespace,ui_key);
CREATE TABLE public.ui_dictionary_release_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dictionary_version_id uuid NOT NULL REFERENCES public.ui_dictionary_versions(id) ON DELETE RESTRICT,
  ui_key_id uuid NOT NULL REFERENCES public.ui_interface_keys(id) ON DELETE RESTRICT,
  translation_proposal_id uuid NOT NULL REFERENCES public.translation_proposals(id) ON DELETE RESTRICT,
  resolved_language_id uuid NOT NULL REFERENCES public.languages(id) ON DELETE RESTRICT,
  resolved_variant_id uuid,
  resolution_type text NOT NULL CHECK(resolution_type IN ('EXACT_VARIANT','LANGUAGE_GENERAL','SYSTEM_FALLBACK')),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(dictionary_version_id,ui_key_id),
  FOREIGN KEY(resolved_language_id,resolved_variant_id) REFERENCES public.language_variants(language_id,id) ON DELETE RESTRICT
);

CREATE OR REPLACE FUNCTION public.tc_guard_trp_orthography() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
DECLARE v_lang uuid; v_var uuid;
BEGIN
  IF NEW.orthography_version_id IS NULL THEN RETURN NEW; END IF;
  SELECT o.language_id,o.variant_id INTO v_lang,v_var FROM public.orthography_versions o WHERE o.id=NEW.orthography_version_id;
  IF v_lang IS DISTINCT FROM NEW.language_id THEN RAISE EXCEPTION 'ORTHOGRAPHY_LANGUAGE_MISMATCH'; END IF;
  IF v_var IS NOT NULL AND v_var IS DISTINCT FROM NEW.variant_id THEN RAISE EXCEPTION 'ORTHOGRAPHY_VARIANT_MISMATCH'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_trp_orth_guard BEFORE INSERT OR UPDATE OF language_id,variant_id,orthography_version_id ON public.translation_proposals FOR EACH ROW EXECUTE FUNCTION public.tc_guard_trp_orthography();

CREATE OR REPLACE FUNCTION public.tc_guard_audio_consent() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
DECLARE v_person uuid; v_revoked timestamptz;
BEGIN
  SELECT c.person_id,c.revoked_at INTO v_person,v_revoked FROM public.linguistic_consents c WHERE c.id=NEW.consent_id;
  IF v_person IS NULL THEN RAISE EXCEPTION 'CONSENT_NOT_FOUND'; END IF;
  IF v_person IS DISTINCT FROM NEW.speaker_person_id THEN RAISE EXCEPTION 'CONSENT_SPEAKER_MISMATCH'; END IF;
  IF v_revoked IS NOT NULL THEN RAISE EXCEPTION 'CONSENT_REVOKED'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_audio_consent_guard BEFORE INSERT OR UPDATE OF consent_id,speaker_person_id ON public.linguistic_audios FOR EACH ROW EXECUTE FUNCTION public.tc_guard_audio_consent();

CREATE OR REPLACE FUNCTION public.tc_guard_review_insert() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
DECLARE v_owner uuid;
BEGIN
  IF NEW.translation_id IS NOT NULL THEN SELECT t.created_by_person_id INTO v_owner FROM public.translation_proposals t WHERE t.id=NEW.translation_id;
  ELSE SELECT a.speaker_person_id INTO v_owner FROM public.linguistic_audios a WHERE a.id=NEW.audio_id; END IF;
  IF v_owner IS NOT NULL AND v_owner=NEW.reviewer_person_id THEN RAISE EXCEPTION 'SELF_REVIEW_FORBIDDEN'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_review_insert_guard BEFORE INSERT ON public.linguistic_reviews FOR EACH ROW EXECUTE FUNCTION public.tc_guard_review_insert();

CREATE OR REPLACE FUNCTION public.tc_guard_review_update() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
  IF NEW.reviewer_person_id IS DISTINCT FROM OLD.reviewer_person_id OR NEW.translation_id IS DISTINCT FROM OLD.translation_id OR NEW.audio_id IS DISTINCT FROM OLD.audio_id THEN RAISE EXCEPTION 'REVIEW_IDENTITY_TARGET_IMMUTABLE'; END IF;
  NEW.version:=OLD.version+1; NEW.updated_at:=now(); RETURN NEW;
END $$;
CREATE TRIGGER trg_review_update_guard BEFORE UPDATE ON public.linguistic_reviews FOR EACH ROW EXECUTE FUNCTION public.tc_guard_review_update();
CREATE OR REPLACE FUNCTION public.tc_block_review_delete() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$ BEGIN RAISE EXCEPTION 'REVIEW_DELETE_FORBIDDEN'; END $$;
CREATE TRIGGER trg_review_delete_block BEFORE DELETE ON public.linguistic_reviews FOR EACH ROW EXECUTE FUNCTION public.tc_block_review_delete();
CREATE OR REPLACE FUNCTION public.tc_review_history_append() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
  INSERT INTO public.linguistic_reviews_history(review_id,version,verdict,observation,is_withdrawn,changed_by) VALUES(NEW.id,NEW.version,NEW.verdict,NEW.observation,NEW.is_withdrawn,auth.uid()); RETURN NEW;
END $$;
CREATE TRIGGER trg_review_history_insert AFTER INSERT OR UPDATE ON public.linguistic_reviews FOR EACH ROW EXECUTE FUNCTION public.tc_review_history_append();
CREATE OR REPLACE FUNCTION public.tc_block_history_mutation() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$ BEGIN RAISE EXCEPTION 'REVIEW_HISTORY_APPEND_ONLY'; END $$;
CREATE TRIGGER trg_review_history_block BEFORE UPDATE OR DELETE ON public.linguistic_reviews_history FOR EACH ROW EXECUTE FUNCTION public.tc_block_history_mutation();
CREATE OR REPLACE FUNCTION public.tc_guard_ui_release_entry() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
DECLARE v_released boolean;
BEGIN
  SELECT v.is_released INTO v_released FROM public.ui_dictionary_versions v WHERE v.id=OLD.dictionary_version_id;
  IF v_released THEN RAISE EXCEPTION 'UI_RELEASE_IMMUTABLE'; END IF;
  RETURN COALESCE(NEW,OLD);
END $$;
CREATE TRIGGER trg_ui_entry_immutable BEFORE UPDATE OR DELETE ON public.ui_dictionary_release_entries FOR EACH ROW EXECUTE FUNCTION public.tc_guard_ui_release_entry();

CREATE OR REPLACE FUNCTION public.normalize_linguistic_search(p_raw_text text,p_language_id uuid,p_variant_id uuid DEFAULT NULL)
RETURNS TABLE(out_raw_original text,out_clean_input text,out_normalized_unicode text,out_search_folded text,out_transformations text[],out_orthography_version_id uuid)
LANGUAGE plpgsql STABLE SET search_path='' AS $$
DECLARE v_clean text; v_norm text; v_fold text; v_orth uuid; v_regex text; v_maps jsonb; kv record; v_trans text[]:='{}';
BEGIN
  out_raw_original:=p_raw_text;
  v_clean:=regexp_replace(btrim(COALESCE(p_raw_text,'')),'\s+',' ','g'); out_clean_input:=v_clean;
  v_norm:=normalize(v_clean,NFC); out_normalized_unicode:=v_norm;
  SELECT o.id,r.punctuation_remove_regex,r.character_mappings INTO v_orth,v_regex,v_maps
  FROM public.orthography_versions o JOIN public.orthography_normalization_rules r ON r.orthography_version_id=o.id
  WHERE o.language_id=p_language_id AND (o.variant_id=p_variant_id OR o.variant_id IS NULL) AND o.status='ACTIVE'
  ORDER BY CASE WHEN o.variant_id=p_variant_id THEN 1 ELSE 2 END,o.effective_from DESC NULLS LAST LIMIT 1;
  v_fold:=lower(v_norm);
  IF v_orth IS NOT NULL THEN
    IF v_regex IS NOT NULL AND v_regex<>'' THEN v_fold:=regexp_replace(v_fold,v_regex,'','g'); v_trans:=array_append(v_trans,'PUNCTUATION_RULE'); END IF;
    FOR kv IN SELECT * FROM jsonb_each_text(COALESCE(v_maps,'{}'::jsonb)) LOOP v_fold:=replace(v_fold,kv.key,kv.value); v_trans:=array_append(v_trans,'MAP:'||kv.key); END LOOP;
  END IF;
  out_search_folded:=v_fold; out_transformations:=array_prepend('UNICODE_NORMALIZE_NFC',v_trans); out_orthography_version_id:=v_orth; RETURN NEXT;
END $$;

CREATE OR REPLACE FUNCTION public.search_semantic_marketplace(p_query text,p_context text,p_primary_language_id uuid,p_primary_variant_id uuid DEFAULT NULL,p_secondary_language_id uuid DEFAULT NULL,p_limit int DEFAULT 20)
RETURNS TABLE(concept_public_id text,matched_text text,matched_language_id uuid,matched_variant_id uuid,matched_translation_public_id text,matched_translation_status text,text_match_type text,language_route text,match_score numeric,display_text text,display_language_id uuid,display_variant_id uuid,display_translation_public_id text,display_translation_status text,fallback_used boolean,product_public_id text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_policy uuid; v_system uuid; v_allow_fuzzy boolean; v_p text; v_s text; v_sys text; v_limit int;
BEGIN
  SELECT p.id,p.fallback_language_id,p.allow_fuzzy INTO v_policy,v_system,v_allow_fuzzy FROM public.linguistic_context_policies p WHERE p.context_name=p_context AND p.is_active;
  IF v_policy IS NULL THEN RAISE EXCEPTION 'UNKNOWN_LINGUISTIC_CONTEXT'; END IF;
  SELECT n.out_search_folded INTO v_p FROM public.normalize_linguistic_search(p_query,p_primary_language_id,p_primary_variant_id)n;
  IF p_secondary_language_id IS NOT NULL THEN SELECT n.out_search_folded INTO v_s FROM public.normalize_linguistic_search(p_query,p_secondary_language_id,NULL)n; END IF;
  SELECT n.out_search_folded INTO v_sys FROM public.normalize_linguistic_search(p_query,v_system,NULL)n;
  v_limit:=LEAST(GREATEST(COALESCE(p_limit,20),1),50);
  RETURN QUERY
  WITH allowed AS (SELECT s.allowed_status FROM public.linguistic_context_policy_statuses s WHERE s.policy_id=v_policy),
  cand AS (
    SELECT tp.*,c.public_id cpid,
      CASE WHEN p_primary_variant_id IS NOT NULL AND tp.language_id=p_primary_language_id AND tp.variant_id=p_primary_variant_id THEN 'EXACT_VARIANT'
           WHEN tp.language_id=p_primary_language_id AND tp.variant_id IS NULL THEN 'SAME_LANGUAGE'
           WHEN p_secondary_language_id IS NOT NULL AND tp.language_id=p_secondary_language_id THEN 'SECONDARY_FALLBACK'
           WHEN tp.language_id=v_system THEN 'SYSTEM_FALLBACK' END route,
      CASE WHEN tp.texto_original=p_query THEN 'EXACT_ORIGINAL'
           WHEN tp.texto_normalized_unicode=normalize(regexp_replace(btrim(COALESCE(p_query,'')),'\s+',' ','g'),NFC) THEN 'EXACT_NORMALIZED_UNICODE'
           WHEN tp.texto_search_folded=CASE WHEN tp.language_id=p_primary_language_id THEN v_p WHEN tp.language_id=p_secondary_language_id THEN v_s ELSE v_sys END THEN 'EXACT_SEARCH_FOLDED'
           ELSE 'FUZZY_SEARCH_FOLDED' END mt,
      CASE WHEN tp.texto_search_folded=CASE WHEN tp.language_id=p_primary_language_id THEN v_p WHEN tp.language_id=p_secondary_language_id THEN v_s ELSE v_sys END THEN 1.0::numeric
           ELSE extensions.similarity(tp.texto_search_folded,CASE WHEN tp.language_id=p_primary_language_id THEN v_p WHEN tp.language_id=p_secondary_language_id THEN v_s ELSE v_sys END)::numeric END sc
    FROM public.translation_proposals tp JOIN public.master_concepts c ON c.id=tp.concept_id JOIN allowed a ON a.allowed_status=tp.consensus_status
    WHERE tp.language_id IN(p_primary_language_id,COALESCE(p_secondary_language_id,p_primary_language_id),v_system)
  ), ranked AS (
    SELECT cand.*,row_number()OVER(PARTITION BY concept_id ORDER BY CASE mt WHEN 'EXACT_ORIGINAL' THEN 1 WHEN 'EXACT_NORMALIZED_UNICODE' THEN 2 WHEN 'EXACT_SEARCH_FOLDED' THEN 3 ELSE 4 END,CASE route WHEN 'EXACT_VARIANT' THEN 1 WHEN 'SAME_LANGUAGE' THEN 2 WHEN 'SECONDARY_FALLBACK' THEN 3 ELSE 4 END,sc DESC,created_at,id)rn
    FROM cand WHERE mt<>'FUZZY_SEARCH_FOLDED' OR(v_allow_fuzzy AND sc>=0.30)
  )
  SELECT r.cpid,r.texto_original,r.language_id,r.variant_id,r.public_id,r.consensus_status,r.mt,r.route,r.sc,
         r.texto_original,r.language_id,r.variant_id,r.public_id,r.consensus_status,
         (r.route IN('SECONDARY_FALLBACK','SYSTEM_FALLBACK')),p.public_id
  FROM ranked r LEFT JOIN public.concept_product_links l ON l.concept_id=r.concept_id AND l.is_active LEFT JOIN public.products p ON p.id=l.product_id AND p.is_active
  WHERE r.rn=1 ORDER BY r.sc DESC LIMIT v_limit;
END $$;

CREATE OR REPLACE FUNCTION public.compile_ui_dictionary_release(p_version_code int,p_description text,p_target_language_id uuid,p_target_variant_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_version uuid; v_hash text; v_holes int;
BEGIN
  INSERT INTO public.ui_dictionary_versions(version_code,target_language_id,target_variant_id,content_hash,description) VALUES(p_version_code,p_target_language_id,p_target_variant_id,'PENDING',p_description) RETURNING id INTO v_version;
  WITH ranked AS (
    SELECT k.id key_id,tp.id trp_id,tp.language_id,tp.variant_id,
      CASE WHEN p_target_variant_id IS NOT NULL AND tp.language_id=p_target_language_id AND tp.variant_id=p_target_variant_id THEN 1 WHEN tp.language_id=p_target_language_id AND tp.variant_id IS NULL THEN 2 WHEN tp.language_id=cp.fallback_language_id AND tp.variant_id IS NULL THEN 3 END rk,
      CASE WHEN p_target_variant_id IS NOT NULL AND tp.language_id=p_target_language_id AND tp.variant_id=p_target_variant_id THEN 'EXACT_VARIANT' WHEN tp.language_id=p_target_language_id AND tp.variant_id IS NULL THEN 'LANGUAGE_GENERAL' WHEN tp.language_id=cp.fallback_language_id AND tp.variant_id IS NULL THEN 'SYSTEM_FALLBACK' END rt,
      row_number()OVER(PARTITION BY k.id ORDER BY CASE WHEN p_target_variant_id IS NOT NULL AND tp.language_id=p_target_language_id AND tp.variant_id=p_target_variant_id THEN 1 WHEN tp.language_id=p_target_language_id AND tp.variant_id IS NULL THEN 2 WHEN tp.language_id=cp.fallback_language_id AND tp.variant_id IS NULL THEN 3 ELSE 9 END,(tp.consensus_status='VERIFICADA')DESC,tp.created_at,tp.id)rn
    FROM public.ui_interface_keys k JOIN public.linguistic_context_policies cp ON cp.context_name=k.context_name JOIN public.linguistic_context_policy_statuses cps ON cps.policy_id=cp.id JOIN public.translation_proposals tp ON tp.concept_id=k.concept_id AND tp.consensus_status=cps.allowed_status
  ), winners AS (SELECT * FROM ranked WHERE rn=1 AND rk IS NOT NULL)
  INSERT INTO public.ui_dictionary_release_entries(dictionary_version_id,ui_key_id,translation_proposal_id,resolved_language_id,resolved_variant_id,resolution_type)
  SELECT v_version,key_id,trp_id,language_id,variant_id,rt FROM winners;
  SELECT count(*) INTO v_holes FROM public.ui_interface_keys k LEFT JOIN public.ui_dictionary_release_entries e ON e.dictionary_version_id=v_version AND e.ui_key_id=k.id LEFT JOIN public.translation_proposals tp ON tp.id=e.translation_proposal_id WHERE k.context_name IN('PAYMENT','LEGAL','SAFETY','IDENTITY','COMPLIANCE') AND(e.id IS NULL OR tp.consensus_status<>'VERIFICADA');
  IF v_holes>0 THEN RAISE EXCEPTION 'RELEASE_BLOCKED_CRITICAL_GAPS:%',v_holes; END IF;
  SELECT encode(extensions.digest(string_agg(k.ui_key||':'||tp.public_id,'|' ORDER BY k.ui_key),'sha256'),'hex') INTO v_hash FROM public.ui_dictionary_release_entries e JOIN public.ui_interface_keys k ON k.id=e.ui_key_id JOIN public.translation_proposals tp ON tp.id=e.translation_proposal_id WHERE e.dictionary_version_id=v_version;
  UPDATE public.ui_dictionary_versions SET content_hash=COALESCE(v_hash,repeat('0',64)),is_released=true,released_at=now() WHERE id=v_version;
  RETURN v_version;
END $$;

CREATE OR REPLACE FUNCTION public.resolve_ui_translation_bundle(p_namespace text,p_requested_keys text[],p_client_lang_id uuid,p_client_var_id uuid DEFAULT NULL)
RETURNS TABLE(ui_key text,display_text text,resolved_language_id uuid,resolved_variant_id uuid,translation_id uuid,translation_public_id text,resolution_type text,translation_status text,fallback_used boolean,missing_translation boolean,dictionary_version int,dictionary_hash text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_version uuid; v_code int; v_hash text;
BEGIN
  SELECT v.id,v.version_code,v.content_hash INTO v_version,v_code,v_hash FROM public.ui_dictionary_versions v WHERE v.is_released AND v.target_language_id=p_client_lang_id AND v.target_variant_id IS NOT DISTINCT FROM p_client_var_id ORDER BY v.version_code DESC LIMIT 1;
  IF v_version IS NULL THEN RETURN; END IF;
  RETURN QUERY WITH req AS (SELECT k.id,k.ui_key FROM public.ui_interface_keys k WHERE k.namespace=p_namespace AND(p_requested_keys IS NULL OR k.ui_key=ANY(p_requested_keys)))
  SELECT r.ui_key,COALESCE(tp.texto_original,'[MISSING_TRANSLATION]'),e.resolved_language_id,e.resolved_variant_id,tp.id,tp.public_id,e.resolution_type,tp.consensus_status,COALESCE(e.resolution_type='SYSTEM_FALLBACK',true),(tp.id IS NULL),v_code,v_hash
  FROM req r LEFT JOIN public.ui_dictionary_release_entries e ON e.dictionary_version_id=v_version AND e.ui_key_id=r.id LEFT JOIN public.translation_proposals tp ON tp.id=e.translation_proposal_id;
END $$;
CREATE OR REPLACE FUNCTION public.get_ui_dictionary_bundle(p_client_lang_id uuid,p_client_var_id uuid DEFAULT NULL,p_target_version int DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_version uuid; v_code int; v_hash text; v_payload jsonb;
BEGIN
  SELECT v.id,v.version_code,v.content_hash INTO v_version,v_code,v_hash FROM public.ui_dictionary_versions v WHERE v.is_released AND v.target_language_id=p_client_lang_id AND v.target_variant_id IS NOT DISTINCT FROM p_client_var_id ORDER BY v.version_code DESC LIMIT 1;
  IF v_version IS NULL THEN RETURN jsonb_build_object('dictionary_version',NULL,'requires_sync',false,'translations','{}'::jsonb); END IF;
  IF p_target_version IS NOT NULL AND p_target_version=v_code THEN RETURN jsonb_build_object('dictionary_version',v_code,'dictionary_hash',v_hash,'requires_sync',false,'translations','{}'::jsonb); END IF;
  SELECT jsonb_object_agg(k.ui_key,tp.texto_original ORDER BY k.ui_key) INTO v_payload FROM public.ui_dictionary_release_entries e JOIN public.ui_interface_keys k ON k.id=e.ui_key_id JOIN public.translation_proposals tp ON tp.id=e.translation_proposal_id WHERE e.dictionary_version_id=v_version;
  RETURN jsonb_build_object('dictionary_version',v_code,'dictionary_hash',v_hash,'requires_sync',true,'translations',COALESCE(v_payload,'{}'::jsonb));
END $$;

INSERT INTO public.languages(name,native_name,iso_code) VALUES
('Español','Español','es'),('English','English','en'),('Achi','Achi',NULL),('Akateko','Akateko',NULL),('Awakateko','Awakateko',NULL),('Chalchiteko','Chalchiteko',NULL),('Ch''orti''','Ch''orti''',NULL),('Chuj','Chuj',NULL),('Itza''','Itza''',NULL),('Ixil','Ixil',NULL),('Jakalteko/Popti''','Jakalteko/Popti''',NULL),('Kaqchikel','Kaqchikel',NULL),('K''iche''','K''iche''',NULL),('Mam','Mam',NULL),('Mopan','Mopan',NULL),('Poqomam','Poqomam',NULL),('Poqomchi''','Poqomchi''',NULL),('Q''anjob''al','Q''anjob''al',NULL),('Q''eqchi''','Q''eqchi''',NULL),('Sakapulteko','Sakapulteko',NULL),('Sipakapense','Sipakapense',NULL),('Tektiteko','Tektiteko',NULL),('Tz''utujil','Tz''utujil',NULL),('Uspanteko','Uspanteko',NULL);
INSERT INTO public.language_variants(language_id,name) SELECT id,'San Mateo Ixtatán' FROM public.languages WHERE name='Chuj';
INSERT INTO public.language_variants(language_id,name) SELECT id,'San Sebastián Coatán' FROM public.languages WHERE name='Chuj';
INSERT INTO public.linguistic_context_policies(context_name,fallback_language_id,allow_fuzzy)
SELECT x.ctx,l.id,x.fuzzy FROM(VALUES('MARKETPLACE',true),('PAYMENT',false),('LEGAL',false),('SAFETY',false),('IDENTITY',false),('COMPLIANCE',false),('NORMAL_UI',false))x(ctx,fuzzy) CROSS JOIN public.languages l WHERE l.name='Español';
INSERT INTO public.linguistic_context_policy_statuses(policy_id,allowed_status)
SELECT p.id,s.st FROM public.linguistic_context_policies p CROSS JOIN LATERAL(VALUES('VERIFICADA'),('APROBADA_COMUNITARIA'))s(st) WHERE p.context_name IN('MARKETPLACE','NORMAL_UI');
INSERT INTO public.linguistic_context_policy_statuses(policy_id,allowed_status)
SELECT p.id,'VERIFICADA' FROM public.linguistic_context_policies p WHERE p.context_name IN('PAYMENT','LEGAL','SAFETY','IDENTITY','COMPLIANCE');

ALTER TABLE public.languages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.language_variants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.linguistic_sources ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.language_variant_territories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.language_variant_territory_sources ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orthography_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orthography_normalization_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orthography_version_sources ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.legal_retention_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.linguistic_consents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_language_preferences ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.linguistic_context_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.linguistic_context_policy_statuses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.master_concepts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.translation_proposals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.translation_proposal_sources ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.linguistic_audios ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.linguistic_contributors ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.linguistic_reputation_matrix ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.linguistic_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.linguistic_reviews_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.concept_product_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ui_dictionary_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ui_interface_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ui_dictionary_release_entries ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.languages,public.language_variants,public.linguistic_sources,public.language_variant_territories,public.language_variant_territory_sources,public.orthography_versions,public.orthography_normalization_rules,public.orthography_version_sources,public.legal_retention_policies,public.linguistic_consents,public.user_language_preferences,public.linguistic_context_policies,public.linguistic_context_policy_statuses,public.master_concepts,public.translation_proposals,public.translation_proposal_sources,public.linguistic_audios,public.linguistic_contributors,public.linguistic_reputation_matrix,public.linguistic_reviews,public.linguistic_reviews_history,public.concept_product_links,public.ui_dictionary_versions,public.ui_interface_keys,public.ui_dictionary_release_entries FROM anon,authenticated;
GRANT SELECT ON public.linguistic_reviews,public.user_language_preferences TO authenticated;
CREATE POLICY reviews_owner_read ON public.linguistic_reviews FOR SELECT TO authenticated USING(reviewer_person_id=public.current_user_person_id());
CREATE POLICY prefs_owner_read ON public.user_language_preferences FOR SELECT TO authenticated USING(person_id=public.current_user_person_id());

REVOKE EXECUTE ON FUNCTION public.tc_guard_trp_orthography(),public.tc_guard_audio_consent(),public.tc_guard_review_insert(),public.tc_guard_review_update(),public.tc_block_review_delete(),public.tc_review_history_append(),public.tc_block_history_mutation(),public.tc_guard_ui_release_entry(),public.normalize_linguistic_search(text,uuid,uuid),public.compile_ui_dictionary_release(int,text,uuid,uuid) FROM PUBLIC,anon,authenticated;
REVOKE EXECUTE ON FUNCTION public.search_semantic_marketplace(text,text,uuid,uuid,uuid,int),public.resolve_ui_translation_bundle(text,text[],uuid,uuid),public.get_ui_dictionary_bundle(uuid,uuid,int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.search_semantic_marketplace(text,text,uuid,uuid,uuid,int) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_ui_translation_bundle(text,text[],uuid,uuid) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_ui_dictionary_bundle(uuid,uuid,int) TO anon,authenticated;
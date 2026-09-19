-- =============================================================================
-- TU COMUNIDAD — demand_requests v1
-- Archivo propuesto: 20260826_demand_requests_v1.sql
-- NO EJECUTAR hasta autorización explícita.
-- =============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.demand_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id text NOT NULL,
  profile_id uuid NOT NULL,
  community_id uuid NOT NULL,
  service_type text NOT NULL,
  status text NOT NULL DEFAULT 'ACTIVE',
  preferred_channel text NOT NULL DEFAULT 'IN_APP',
  note text NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  cancelled_at timestamptz NULL,
  fulfilled_at timestamptz NULL,
  CONSTRAINT demand_requests_public_id_format CHECK (public_id ~ '^DEM-[A-F0-9]{16}$'),
  CONSTRAINT demand_requests_service_type_check CHECK (service_type IN ('HOME_DELIVERY','DRIVER','COURIER','STORE','PTC','SUPPLIER')),
  CONSTRAINT demand_requests_status_check CHECK (status IN ('ACTIVE','CANCELLED','FULFILLED','EXPIRED')),
  CONSTRAINT demand_requests_channel_check CHECK (preferred_channel IN ('IN_APP','EMAIL')),
  CONSTRAINT demand_requests_note_length_check CHECK (note IS NULL OR char_length(note) <= 280)
);

ALTER TABLE public.demand_requests
  ADD CONSTRAINT demand_requests_profile_id_fkey
  FOREIGN KEY (profile_id) REFERENCES public.profiles (id);

ALTER TABLE public.demand_requests
  ADD CONSTRAINT demand_requests_community_id_fkey
  FOREIGN KEY (community_id) REFERENCES public.communities (id);

COMMENT ON TABLE public.demand_requests IS 'DEM: interés/demanda territorial del comprador (CLI). No es OPP operativa.';

CREATE UNIQUE INDEX IF NOT EXISTS demand_requests_public_id_key ON public.demand_requests (public_id);
CREATE UNIQUE INDEX IF NOT EXISTS demand_requests_active_uniq ON public.demand_requests (profile_id, community_id, service_type) WHERE (status = 'ACTIVE');
CREATE INDEX IF NOT EXISTS demand_requests_profile_created_idx ON public.demand_requests (profile_id, created_at DESC);
CREATE INDEX IF NOT EXISTS demand_requests_community_service_status_idx ON public.demand_requests (community_id, service_type, status);

CREATE OR REPLACE FUNCTION public.demand_requests_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.demand_requests_set_updated_at() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.demand_requests_set_updated_at() FROM anon;
REVOKE ALL ON FUNCTION public.demand_requests_set_updated_at() FROM authenticated;

DROP TRIGGER IF EXISTS trg_demand_requests_updated_at ON public.demand_requests;
CREATE TRIGGER trg_demand_requests_updated_at
  BEFORE UPDATE ON public.demand_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.demand_requests_set_updated_at();

ALTER TABLE public.demand_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS demand_requests_select_own ON public.demand_requests;
CREATE POLICY demand_requests_select_own
  ON public.demand_requests
  FOR SELECT
  TO authenticated
  USING (
    profile_id IN (
      SELECT p.profile_id
      FROM public.current_user_profile_ids() AS p
    )
  );

REVOKE ALL ON TABLE public.demand_requests FROM PUBLIC;
REVOKE ALL ON TABLE public.demand_requests FROM anon;
REVOKE ALL ON TABLE public.demand_requests FROM authenticated;

CREATE OR REPLACE FUNCTION public.tc_resolve_cli_profile_id()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_profile_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = 'P0001';
  END IF;

  SELECT p.profile_id
    INTO v_profile_id
  FROM public.current_user_profile_ids() AS p
  WHERE p.profile_type = 'CLI'
  LIMIT 1;

  IF v_profile_id IS NULL THEN
    RAISE EXCEPTION 'client_profile_required' USING ERRCODE = 'P0001';
  END IF;

  RETURN v_profile_id;
END;
$$;

REVOKE ALL ON FUNCTION public.tc_resolve_cli_profile_id() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.tc_resolve_cli_profile_id() FROM anon;
REVOKE ALL ON FUNCTION public.tc_resolve_cli_profile_id() FROM authenticated;

CREATE OR REPLACE FUNCTION public.tc_request_service_interest(
  p_community_id uuid,
  p_service_type text,
  p_preferred_channel text DEFAULT 'IN_APP',
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_profile_id uuid;
  v_row public.demand_requests%ROWTYPE;
  v_public_id text;
  v_channel text;
  v_note text;
BEGIN
  v_profile_id := public.tc_resolve_cli_profile_id();

  IF p_community_id IS NULL THEN
    RAISE EXCEPTION 'invalid_community' USING ERRCODE = 'P0001';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.communities c
    WHERE c.id = p_community_id AND c.is_active IS TRUE
  ) THEN
    RAISE EXCEPTION 'invalid_community' USING ERRCODE = 'P0001';
  END IF;

  IF p_service_type IS NULL OR p_service_type NOT IN ('HOME_DELIVERY','DRIVER','COURIER','STORE','PTC','SUPPLIER') THEN
    RAISE EXCEPTION 'invalid_service_type' USING ERRCODE = 'P0001';
  END IF;

  v_channel := coalesce(nullif(trim(p_preferred_channel), ''), 'IN_APP');
  IF v_channel NOT IN ('IN_APP','EMAIL') THEN
    RAISE EXCEPTION 'invalid_channel' USING ERRCODE = 'P0001';
  END IF;

  v_note := nullif(trim(p_note), '');
  IF v_note IS NOT NULL AND char_length(v_note) > 280 THEN
    RAISE EXCEPTION 'note_too_long' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_row
  FROM public.demand_requests dr
  WHERE dr.profile_id = v_profile_id
    AND dr.community_id = p_community_id
    AND dr.service_type = p_service_type
    AND dr.status = 'ACTIVE'
  LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'public_id', v_row.public_id,
      'community_id', v_row.community_id,
      'service_type', v_row.service_type,
      'status', v_row.status,
      'preferred_channel', v_row.preferred_channel,
      'note', v_row.note,
      'created_at', v_row.created_at,
      'updated_at', v_row.updated_at,
      'cancelled_at', v_row.cancelled_at,
      'fulfilled_at', v_row.fulfilled_at,
      'reused', true
    );
  END IF;

  v_public_id := public.tc_generate_public_id('DEM');

  BEGIN
    INSERT INTO public.demand_requests (
      public_id, profile_id, community_id, service_type, status, preferred_channel, note
    ) VALUES (
      v_public_id, v_profile_id, p_community_id, p_service_type, 'ACTIVE', v_channel, v_note
    )
    RETURNING * INTO v_row;
  EXCEPTION
    WHEN unique_violation THEN
      SELECT * INTO v_row
      FROM public.demand_requests dr
      WHERE dr.profile_id = v_profile_id
        AND dr.community_id = p_community_id
        AND dr.service_type = p_service_type
        AND dr.status = 'ACTIVE'
      LIMIT 1;

      IF NOT FOUND THEN
        RAISE;
      END IF;

      RETURN jsonb_build_object(
        'public_id', v_row.public_id,
        'community_id', v_row.community_id,
        'service_type', v_row.service_type,
        'status', v_row.status,
        'preferred_channel', v_row.preferred_channel,
        'note', v_row.note,
        'created_at', v_row.created_at,
        'updated_at', v_row.updated_at,
        'cancelled_at', v_row.cancelled_at,
        'fulfilled_at', v_row.fulfilled_at,
        'reused', true
      );
  END;

  RETURN jsonb_build_object(
    'public_id', v_row.public_id,
    'community_id', v_row.community_id,
    'service_type', v_row.service_type,
    'status', v_row.status,
    'preferred_channel', v_row.preferred_channel,
    'note', v_row.note,
    'created_at', v_row.created_at,
    'updated_at', v_row.updated_at,
    'cancelled_at', v_row.cancelled_at,
    'fulfilled_at', v_row.fulfilled_at,
    'reused', false
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.tc_cancel_service_interest(p_public_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_profile_id uuid;
  v_row public.demand_requests%ROWTYPE;
BEGIN
  v_profile_id := public.tc_resolve_cli_profile_id();

  IF p_public_id IS NULL OR p_public_id !~ '^DEM-[A-F0-9]{16}$' THEN
    RAISE EXCEPTION 'interest_not_found' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_row
  FROM public.demand_requests dr
  WHERE dr.public_id = p_public_id AND dr.profile_id = v_profile_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'interest_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF v_row.status = 'CANCELLED' THEN
    RETURN jsonb_build_object(
      'public_id', v_row.public_id,
      'status', v_row.status,
      'cancelled_at', v_row.cancelled_at,
      'already_cancelled', true
    );
  END IF;

  IF v_row.status IS DISTINCT FROM 'ACTIVE' THEN
    RAISE EXCEPTION 'invalid_status_transition' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.demand_requests dr
  SET status = 'CANCELLED', cancelled_at = now(), updated_at = now()
  WHERE dr.id = v_row.id
    AND dr.profile_id = v_profile_id
    AND dr.status = 'ACTIVE'
  RETURNING * INTO v_row;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'public_id', v_row.public_id,
      'status', v_row.status,
      'cancelled_at', v_row.cancelled_at,
      'already_cancelled', false
    );
  END IF;

  SELECT * INTO v_row
  FROM public.demand_requests dr
  WHERE dr.public_id = p_public_id AND dr.profile_id = v_profile_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'interest_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF v_row.status = 'CANCELLED' THEN
    RETURN jsonb_build_object(
      'public_id', v_row.public_id,
      'status', v_row.status,
      'cancelled_at', v_row.cancelled_at,
      'already_cancelled', true
    );
  END IF;

  RAISE EXCEPTION 'invalid_status_transition' USING ERRCODE = 'P0001';
END;
$$;

CREATE OR REPLACE FUNCTION public.tc_list_my_service_interests(p_community_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_profile_id uuid;
  v_result jsonb;
BEGIN
  v_profile_id := public.tc_resolve_cli_profile_id();

  SELECT coalesce(jsonb_agg(row_data ORDER BY created_at DESC), '[]'::jsonb)
    INTO v_result
  FROM (
    SELECT
      dr.created_at,
      jsonb_build_object(
        'public_id', dr.public_id,
        'community_id', dr.community_id,
        'service_type', dr.service_type,
        'status', dr.status,
        'preferred_channel', dr.preferred_channel,
        'note', dr.note,
        'created_at', dr.created_at,
        'updated_at', dr.updated_at,
        'cancelled_at', dr.cancelled_at,
        'fulfilled_at', dr.fulfilled_at
      ) AS row_data
    FROM public.demand_requests dr
    WHERE dr.profile_id = v_profile_id
      AND (p_community_id IS NULL OR dr.community_id = p_community_id)
    ORDER BY dr.created_at DESC
  ) s;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.tc_request_service_interest(uuid, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.tc_cancel_service_interest(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.tc_list_my_service_interests(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.tc_request_service_interest(uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.tc_cancel_service_interest(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.tc_list_my_service_interests(uuid) TO authenticated;

COMMIT;
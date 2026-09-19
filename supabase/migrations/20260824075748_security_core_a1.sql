CREATE TYPE public.tc_scope_type AS ENUM (
    'GLOBAL', 'DEPARTMENT', 'MUNICIPALITY', 'COMMUNITY', 'PTC', 'STORE', 'ROUTE'
);

CREATE TABLE public.capabilities (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name varchar(64) UNIQUE NOT NULL
);

CREATE TABLE public.profile_capability_scopes (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    profile_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    capability_id uuid NOT NULL REFERENCES public.capabilities(id) ON DELETE RESTRICT,
    scope_type public.tc_scope_type NOT NULL,
    scope_target_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chk_tc_scope_target_integrity CHECK (
        (scope_type = 'GLOBAL' AND scope_target_id IS NULL)
        OR
        (scope_type <> 'GLOBAL' AND scope_target_id IS NOT NULL)
    ),
    CONSTRAINT uq_profile_capability_scope_target UNIQUE NULLS NOT DISTINCT (
        profile_id, capability_id, scope_type, scope_target_id
    )
);

CREATE INDEX idx_tc_scopes_composite_lookup
    ON public.profile_capability_scopes (profile_id, capability_id, scope_type, scope_target_id);

ALTER TABLE public.capabilities ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profile_capability_scopes ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.capabilities FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.profile_capability_scopes FROM PUBLIC, anon, authenticated;

GRANT SELECT ON public.capabilities TO authenticated;
GRANT SELECT ON public.profile_capability_scopes TO authenticated;

CREATE POLICY policy_select_capabilities
ON public.capabilities
FOR SELECT TO authenticated
USING (true);

CREATE POLICY policy_select_profile_capability_scopes
ON public.profile_capability_scopes
FOR SELECT TO authenticated
USING (
    EXISTS (
        SELECT 1
        FROM public.persons pe
        JOIN public.profiles pr ON pr.person_id = pe.id
        WHERE pe.auth_user_id = auth.uid()
          AND pr.id = profile_id
    )
);

CREATE OR REPLACE FUNCTION public.internal_validate_scope_target(
    p_scope_type public.tc_scope_type,
    p_scope_target_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_exists boolean := false;
BEGIN
    IF p_scope_type = 'GLOBAL' THEN
        RETURN (p_scope_target_id IS NULL);
    END IF;

    IF p_scope_target_id IS NULL THEN
        RETURN false;
    END IF;

    CASE p_scope_type
        WHEN 'DEPARTMENT' THEN
            SELECT EXISTS(SELECT 1 FROM public.departments WHERE id = p_scope_target_id) INTO v_exists;
        WHEN 'MUNICIPALITY' THEN
            SELECT EXISTS(SELECT 1 FROM public.municipalities WHERE id = p_scope_target_id) INTO v_exists;
        WHEN 'COMMUNITY' THEN
            SELECT EXISTS(SELECT 1 FROM public.communities WHERE id = p_scope_target_id) INTO v_exists;
        WHEN 'PTC' THEN
            SELECT EXISTS(SELECT 1 FROM public.ptc_points WHERE id = p_scope_target_id) INTO v_exists;
        WHEN 'ROUTE' THEN
            SELECT EXISTS(SELECT 1 FROM public.route_opportunities WHERE id = p_scope_target_id) INTO v_exists;
        WHEN 'STORE' THEN
            SELECT EXISTS(
                SELECT 1
                FROM public.profiles
                WHERE id = p_scope_target_id
                  AND profile_type IN ('TIE', 'VEN')
            ) INTO v_exists;
        ELSE
            v_exists := false;
    END CASE;

    RETURN v_exists;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_validate_scope_target(public.tc_scope_type, uuid)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.internal_trg_fn_enforce_scope_target_integrity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF NOT public.internal_validate_scope_target(NEW.scope_type, NEW.scope_target_id) THEN
        RAISE EXCEPTION 'GAI_INVALID_SCOPE_TARGET: El identificador para scope_target_id no existe en la tabla %.', NEW.scope_type
            USING ERRCODE = 'foreign_key_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tc_enforce_scope_target_integrity
BEFORE INSERT OR UPDATE ON public.profile_capability_scopes
FOR EACH ROW
EXECUTE FUNCTION public.internal_trg_fn_enforce_scope_target_integrity();

REVOKE ALL ON FUNCTION public.internal_trg_fn_enforce_scope_target_integrity()
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.internal_has_capability(
    p_profile_id uuid,
    p_capability_name varchar(64),
    p_target_scope_type public.tc_scope_type,
    p_target_scope_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_capability_id uuid;
    v_parent_id uuid;
BEGIN
    IF NOT public.internal_validate_scope_target(p_target_scope_type, p_target_scope_id) THEN
        RETURN false;
    END IF;

    SELECT id INTO v_capability_id
    FROM public.capabilities
    WHERE name = p_capability_name;

    IF v_capability_id IS NULL THEN
        RETURN false;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.profile_capability_scopes
        WHERE profile_id = p_profile_id
          AND capability_id = v_capability_id
          AND scope_type = 'GLOBAL'
    ) THEN
        RETURN true;
    END IF;

    IF p_target_scope_type = 'GLOBAL' THEN
        RETURN false;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.profile_capability_scopes
        WHERE profile_id = p_profile_id
          AND capability_id = v_capability_id
          AND scope_type = p_target_scope_type
          AND scope_target_id = p_target_scope_id
    ) THEN
        RETURN true;
    END IF;

    CASE p_target_scope_type
        WHEN 'PTC' THEN
            SELECT community_id INTO v_parent_id
            FROM public.ptc_points
            WHERE id = p_target_scope_id;
            IF v_parent_id IS NOT NULL THEN
                RETURN public.internal_has_capability(
                    p_profile_id, p_capability_name, 'COMMUNITY', v_parent_id
                );
            END IF;
        WHEN 'COMMUNITY' THEN
            SELECT municipality_id INTO v_parent_id
            FROM public.communities
            WHERE id = p_target_scope_id;
            IF v_parent_id IS NOT NULL THEN
                RETURN public.internal_has_capability(
                    p_profile_id, p_capability_name, 'MUNICIPALITY', v_parent_id
                );
            END IF;
        WHEN 'MUNICIPALITY' THEN
            SELECT department_id INTO v_parent_id
            FROM public.municipalities
            WHERE id = p_target_scope_id;
            IF v_parent_id IS NOT NULL THEN
                RETURN public.internal_has_capability(
                    p_profile_id, p_capability_name, 'DEPARTMENT', v_parent_id
                );
            END IF;
        WHEN 'STORE' THEN
            RETURN false;
        WHEN 'ROUTE' THEN
            RETURN false;
        ELSE
            NULL;
    END CASE;

    RETURN false;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_has_capability(uuid, varchar, public.tc_scope_type, uuid)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.tc_check_my_permission(
    p_capability_name varchar(64),
    p_target_scope_type public.tc_scope_type,
    p_target_scope_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1
        FROM public.persons pe
        JOIN public.profiles pr ON pr.person_id = pe.id
        WHERE pe.auth_user_id = auth.uid()
          AND public.internal_has_capability(
              pr.id,
              p_capability_name,
              p_target_scope_type,
              p_target_scope_id
          )
    );
END;
$$;

REVOKE ALL ON FUNCTION public.tc_check_my_permission(varchar, public.tc_scope_type, uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tc_check_my_permission(varchar, public.tc_scope_type, uuid)
TO authenticated;

CREATE OR REPLACE FUNCTION public.grant_profile_capability_scope(
    p_active_admin_profile_id uuid,
    p_target_profile_id uuid,
    p_capability_name varchar(64),
    p_scope_type public.tc_scope_type,
    p_scope_target_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_session_person_id uuid;
    v_target_capability_id uuid;
    v_target_profile_public_id text;
    v_inserted_rows integer;
    v_outcome_string varchar(32);
BEGIN
    SELECT pe.id INTO v_session_person_id
    FROM public.persons pe
    JOIN public.profiles pr ON pr.person_id = pe.id
    WHERE pe.auth_user_id = auth.uid()
      AND pr.id = p_active_admin_profile_id;

    IF v_session_person_id IS NULL THEN
        RAISE EXCEPTION 'TC_SECURITY_VIOLATION: Perfil administrativo inválido.'
            USING ERRCODE = 'invalid_authorization_specification';
    END IF;

    IF NOT public.internal_has_capability(
        p_active_admin_profile_id,
        'authority.capabilities.grant',
        p_scope_type,
        p_scope_target_id
    ) THEN
        RAISE EXCEPTION 'TC_FORBIDDEN: Permisos de delegación insuficientes.'
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF NOT public.internal_validate_scope_target(p_scope_type, p_scope_target_id) THEN
        RAISE EXCEPTION 'TC_INVALID_TARGET: El destino no existe.'
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    SELECT id INTO v_target_capability_id
    FROM public.capabilities
    WHERE name = p_capability_name;

    IF v_target_capability_id IS NULL THEN
        RAISE EXCEPTION 'TC_CAPABILITY_NOT_FOUND: Capacidad inexistente.'
            USING ERRCODE = 'no_data_found';
    END IF;

    SELECT public_id INTO v_target_profile_public_id
    FROM public.profiles
    WHERE id = p_target_profile_id;

    IF v_target_profile_public_id IS NULL THEN
        RAISE EXCEPTION 'TC_PROFILE_NOT_FOUND: Perfil destino inexistente.'
            USING ERRCODE = 'no_data_found';
    END IF;

    INSERT INTO public.profile_capability_scopes (
        profile_id, capability_id, scope_type, scope_target_id
    )
    VALUES (
        p_target_profile_id, v_target_capability_id, p_scope_type, p_scope_target_id
    )
    ON CONFLICT (profile_id, capability_id, scope_type, scope_target_id) DO NOTHING;

    GET DIAGNOSTICS v_inserted_rows = ROW_COUNT;
    v_outcome_string := CASE WHEN v_inserted_rows > 0 THEN 'GRANTED' ELSE 'ALREADY_GRANTED' END;

    INSERT INTO public.audit_logs (
        actor_person_id,
        actor_profile_id,
        operation,
        entity_type,
        entity_public_id,
        result,
        metadata
    )
    VALUES (
        v_session_person_id,
        p_active_admin_profile_id,
        'CAPABILITY_SCOPE_GRANT',
        'PROFILE_CAPABILITY_SCOPE',
        v_target_profile_public_id,
        'SUCCESS',
        jsonb_build_object(
            'target_profile_id', p_target_profile_id,
            'capability', p_capability_name,
            'scope_type', p_scope_type,
            'scope_target_id', p_scope_target_id,
            'grant_outcome', v_outcome_string
        )
    );

    RETURN jsonb_build_object('success', true, 'outcome', v_outcome_string);
END;
$$;

REVOKE ALL ON FUNCTION public.grant_profile_capability_scope(uuid, uuid, varchar, public.tc_scope_type, uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.grant_profile_capability_scope(uuid, uuid, varchar, public.tc_scope_type, uuid)
TO authenticated;

CREATE OR REPLACE FUNCTION public.revoke_profile_capability_scope(
    p_active_admin_profile_id uuid,
    p_target_profile_id uuid,
    p_capability_name varchar(64),
    p_scope_type public.tc_scope_type,
    p_scope_target_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_session_person_id uuid;
    v_target_capability_id uuid;
    v_target_profile_public_id text;
    v_deleted_rows integer;
    v_outcome_string varchar(32);
BEGIN
    SELECT pe.id INTO v_session_person_id
    FROM public.persons pe
    JOIN public.profiles pr ON pr.person_id = pe.id
    WHERE pe.auth_user_id = auth.uid()
      AND pr.id = p_active_admin_profile_id;

    IF v_session_person_id IS NULL THEN
        RAISE EXCEPTION 'TC_SECURITY_VIOLATION: Perfil administrativo inválido.'
            USING ERRCODE = 'invalid_authorization_specification';
    END IF;

    IF NOT public.internal_has_capability(
        p_active_admin_profile_id,
        'authority.capabilities.revoke',
        p_scope_type,
        p_scope_target_id
    ) THEN
        RAISE EXCEPTION 'TC_FORBIDDEN: Permisos de revocación insuficientes.'
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    SELECT id INTO v_target_capability_id
    FROM public.capabilities
    WHERE name = p_capability_name;

    IF v_target_capability_id IS NULL THEN
        RAISE EXCEPTION 'TC_CAPABILITY_NOT_FOUND: Capacidad inexistente.'
            USING ERRCODE = 'no_data_found';
    END IF;

    SELECT public_id INTO v_target_profile_public_id
    FROM public.profiles
    WHERE id = p_target_profile_id;

    IF v_target_profile_public_id IS NULL THEN
        RAISE EXCEPTION 'TC_PROFILE_NOT_FOUND: Perfil destino inexistente.'
            USING ERRCODE = 'no_data_found';
    END IF;

    DELETE FROM public.profile_capability_scopes
    WHERE profile_id = p_target_profile_id
      AND capability_id = v_target_capability_id
      AND scope_type = p_scope_type
      AND scope_target_id IS NOT DISTINCT FROM p_scope_target_id;

    GET DIAGNOSTICS v_deleted_rows = ROW_COUNT;
    v_outcome_string := CASE WHEN v_deleted_rows > 0 THEN 'REVOKED' ELSE 'ALREADY_ABSENT' END;

    INSERT INTO public.audit_logs (
        actor_person_id,
        actor_profile_id,
        operation,
        entity_type,
        entity_public_id,
        result,
        metadata
    )
    VALUES (
        v_session_person_id,
        p_active_admin_profile_id,
        'CAPABILITY_SCOPE_REVOKE',
        'PROFILE_CAPABILITY_SCOPE',
        v_target_profile_public_id,
        'SUCCESS',
        jsonb_build_object(
            'target_profile_id', p_target_profile_id,
            'capability', p_capability_name,
            'scope_type', p_scope_type,
            'scope_target_id', p_scope_target_id,
            'revoke_outcome', v_outcome_string
        )
    );

    RETURN jsonb_build_object('success', true, 'outcome', v_outcome_string);
END;
$$;

REVOKE ALL ON FUNCTION public.revoke_profile_capability_scope(uuid, uuid, varchar, public.tc_scope_type, uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_profile_capability_scope(uuid, uuid, varchar, public.tc_scope_type, uuid)
TO authenticated;

INSERT INTO public.capabilities (name) VALUES
    ('authority.capabilities.grant'),
    ('authority.capabilities.revoke'),
    ('incident.ingest'),
    ('incident.read'),
    ('incident.acknowledge'),
    ('incident.assign'),
    ('incident.resolve'),
    ('incident.close'),
    ('incident.override'),
    ('incident.notify.operational'),
    ('incident.notify.informative')
ON CONFLICT (name) DO NOTHING;
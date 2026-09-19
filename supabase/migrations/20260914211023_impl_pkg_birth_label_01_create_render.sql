CREATE OR REPLACE FUNCTION public.tc_render_package_label(
  p_package_public_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_auth_user_id uuid;
  v_person_id uuid;
  v_actor_ok boolean := false;
  v_pkg_public_id text;
  v_pkg public.packages%ROWTYPE;
  v_sub public.sub_orders%ROWTYPE;
  v_ord public.orders%ROWTYPE;
  v_recipient_name text;
  v_destination_name text;
  v_community text;
  v_municipality text;
  v_department text;
  v_dest_type text;
  v_dest_id text;
  v_loc public.customer_locations%ROWTYPE;
  v_ptc public.ptc_points%ROWTYPE;
  v_resolved boolean := false;
BEGIN
  v_auth_user_id := auth.uid();
  IF v_auth_user_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_UNAUTHENTICATED';
  END IF;

  v_pkg_public_id := upper(btrim(coalesce(p_package_public_id, '')));
  IF v_pkg_public_id = '' THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_INVALID_ARGUMENT';
  END IF;

  SELECT per.id INTO v_person_id
  FROM public.persons per
  WHERE per.auth_user_id = v_auth_user_id
  LIMIT 1;
  IF v_person_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_UNAUTHENTICATED';
  END IF;

  SELECT * INTO v_pkg
  FROM public.packages
  WHERE public_id = v_pkg_public_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_NOT_FOUND';
  END IF;

  SELECT * INTO v_sub
  FROM public.sub_orders
  WHERE id = v_pkg.sub_order_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_NOT_FOUND';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.profiles pr
    WHERE pr.person_id = v_person_id
      AND pr.profile_type IN ('TIE', 'VEN')
      AND pr.status = 'active'
      AND (
        pr.id = v_pkg.current_custodian_id
        OR pr.id = v_sub.store_profile_id
      )
  ) INTO v_actor_ok;

  IF NOT v_actor_ok THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_FORBIDDEN';
  END IF;

  SELECT * INTO v_ord
  FROM public.orders
  WHERE id = v_sub.order_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_NOT_FOUND';
  END IF;

  SELECT per.full_name INTO v_recipient_name
  FROM public.profiles pr
  JOIN public.persons per ON per.id = pr.person_id
  WHERE pr.id = v_ord.client_profile_id
  LIMIT 1;

  v_dest_type := upper(btrim(coalesce(v_ord.destination_type, '')));
  v_dest_id := btrim(coalesce(v_ord.destination_id, ''));

  IF v_dest_type = 'PTC' AND v_dest_id <> '' THEN
    SELECT * INTO v_ptc
    FROM public.ptc_points p
    WHERE p.id::text = v_dest_id
       OR p.public_id = v_dest_id
       OR upper(p.public_id) = upper(v_dest_id)
    LIMIT 1;

    IF FOUND THEN
      v_destination_name := v_ptc.public_name;
      SELECT c.name, m.name, d.name
      INTO v_community, v_municipality, v_department
      FROM public.communities c
      JOIN public.municipalities m ON m.id = c.municipality_id
      JOIN public.departments d ON d.id = m.department_id
      WHERE c.id = v_ptc.community_id;
      v_resolved := true;
    END IF;
  END IF;

  IF NOT v_resolved AND v_dest_id <> '' THEN
    SELECT * INTO v_loc
    FROM public.customer_locations cl
    WHERE cl.id::text = v_dest_id
       OR cl.public_id = v_dest_id
       OR upper(cl.public_id) = upper(v_dest_id)
    LIMIT 1;

    IF FOUND THEN
      IF v_loc.ptc_id IS NOT NULL THEN
        SELECT * INTO v_ptc FROM public.ptc_points WHERE id = v_loc.ptc_id;
        IF FOUND THEN
          v_destination_name := v_ptc.public_name;
        END IF;
      END IF;

      SELECT c.name INTO v_community
      FROM public.communities c WHERE c.id = v_loc.community_id;

      IF v_destination_name IS NULL THEN
        v_destination_name := v_community;
      END IF;

      SELECT m.name INTO v_municipality
      FROM public.municipalities m WHERE m.id = v_loc.municipality_id;

      SELECT d.name INTO v_department
      FROM public.departments d WHERE d.id = v_loc.department_id;

      IF v_destination_name IS NOT NULL OR v_community IS NOT NULL THEN
        v_resolved := true;
      END IF;
    END IF;
  END IF;

  IF NOT v_resolved THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TC_DESTINATION_UNRESOLVED';
  END IF;

  RETURN jsonb_build_object(
    'public_id', v_pkg.public_id,
    'qr_value', v_pkg.public_id,
    'recipient_name', v_recipient_name,
    'destination_name', v_destination_name,
    'community', v_community,
    'municipality', v_municipality,
    'department', v_department
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.tc_render_package_label(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.tc_render_package_label(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.tc_render_package_label(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.tc_render_package_label(text) TO service_role;
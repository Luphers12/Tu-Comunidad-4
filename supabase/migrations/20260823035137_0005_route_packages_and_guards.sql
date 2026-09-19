CREATE TABLE public.route_packages (
  route_id uuid NOT NULL REFERENCES public.route_opportunities(id) ON DELETE CASCADE,
  package_id uuid NOT NULL REFERENCES public.packages(id),
  added_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (route_id, package_id)
);
CREATE INDEX idx_route_packages_package ON public.route_packages(package_id);
ALTER TABLE public.route_packages ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.route_packages FROM PUBLIC, anon, authenticated;
CREATE OR REPLACE FUNCTION public.tc_guard_route_manifest_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_route_id uuid;
  v_route_state text;
BEGIN
  IF TG_OP='UPDATE' THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_ROUTE_MANIFEST_UPDATE_NOT_ALLOWED'; END IF;
  v_route_id := CASE WHEN TG_OP='DELETE' THEN OLD.route_id ELSE NEW.route_id END;
  SELECT ro.state INTO v_route_state FROM public.route_opportunities ro WHERE ro.id=v_route_id FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_ROUTE_NOT_FOUND'; END IF;
  IF v_route_state<>'OPEN' THEN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TC_ROUTE_MANIFEST_FROZEN'; END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.tc_guard_route_manifest_mutation() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER trg_route_packages_guard BEFORE INSERT OR UPDATE OR DELETE ON public.route_packages FOR EACH ROW EXECUTE FUNCTION public.tc_guard_route_manifest_mutation();
CREATE UNIQUE INDEX uq_route_assignments_active_route ON public.route_assignments(route_id) WHERE state IN ('ASSIGNED','IN_PROGRESS');
CREATE UNIQUE INDEX uq_route_assignments_active_driver ON public.route_assignments(driver_profile_id) WHERE state IN ('ASSIGNED','IN_PROGRESS');
CREATE UNIQUE INDEX uq_route_assignments_active_vehicle ON public.route_assignments(vehicle_id) WHERE state IN ('ASSIGNED','IN_PROGRESS');
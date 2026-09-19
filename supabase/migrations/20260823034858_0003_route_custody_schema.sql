ALTER TABLE public.movements DROP CONSTRAINT IF EXISTS movements_movement_type_check;
ALTER TABLE public.movements ADD CONSTRAINT movements_movement_type_check CHECK (movement_type IN ('STORE_TO_PTC','STORE_TO_DRIVER','PTC_TO_PTC','PTC_TO_DRIVER','DRIVER_TO_PTC','PTC_TO_DELIVERY','DELIVERY_TO_CUSTOMER','RETURN'));
CREATE TABLE public.movement_custody_handshakes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  movement_id uuid NOT NULL REFERENCES public.movements(id) ON DELETE CASCADE,
  package_id uuid NOT NULL REFERENCES public.packages(id) ON DELETE CASCADE,
  from_profile_id uuid NOT NULL REFERENCES public.profiles(id),
  to_profile_id uuid NOT NULL REFERENCES public.profiles(id),
  status text NOT NULL DEFAULT 'PLANNED' CHECK (status IN ('PLANNED','RELEASED','RECEIVED','CANCELLED','CONFLICT')),
  release_event_id text REFERENCES public.event_inbox(event_id),
  receive_event_id text REFERENCES public.event_inbox(event_id),
  release_occurred_at timestamptz,
  receive_occurred_at timestamptz,
  version bigint NOT NULL DEFAULT 0 CHECK (version >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (movement_id, package_id),
  CONSTRAINT chk_custody_handshake_events CHECK ((status='PLANNED' AND release_event_id IS NULL AND receive_event_id IS NULL) OR (status='RELEASED' AND release_event_id IS NOT NULL AND receive_event_id IS NULL) OR (status='RECEIVED' AND release_event_id IS NOT NULL AND receive_event_id IS NOT NULL) OR status IN ('CANCELLED','CONFLICT'))
);
CREATE TRIGGER trg_movement_custody_handshakes_updated_at BEFORE UPDATE ON public.movement_custody_handshakes FOR EACH ROW EXECUTE FUNCTION public.tc_set_updated_at();
CREATE INDEX idx_mch_movement_status ON public.movement_custody_handshakes(movement_id,status);
CREATE INDEX idx_mch_package ON public.movement_custody_handshakes(package_id);
CREATE INDEX idx_mch_release_event ON public.movement_custody_handshakes(release_event_id);
CREATE INDEX idx_mch_receive_event ON public.movement_custody_handshakes(receive_event_id);
ALTER TABLE public.movement_custody_handshakes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.movement_custody_handshakes FROM PUBLIC, anon, authenticated;
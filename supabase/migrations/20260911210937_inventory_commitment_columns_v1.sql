-- IMPL-INVENTORY-COMMITMENT-COLUMNS-01
-- Init: committed from legacy quantity_on_hand (published commitment, NOT verified physical)

ALTER TABLE public.inventory
  ADD COLUMN quantity_committed bigint,
  ADD COLUMN quantity_consumed bigint NOT NULL DEFAULT 0,
  ADD COLUMN min_alert_qty bigint,
  ADD COLUMN cycle_started_at timestamptz;

UPDATE public.inventory
SET
  quantity_committed = quantity_on_hand,
  quantity_consumed = 0,
  cycle_started_at = now();

ALTER TABLE public.inventory
  ALTER COLUMN quantity_committed SET NOT NULL,
  ALTER COLUMN quantity_committed SET DEFAULT 0,
  ALTER COLUMN cycle_started_at SET NOT NULL,
  ALTER COLUMN cycle_started_at SET DEFAULT now();

ALTER TABLE public.inventory
  ADD CONSTRAINT inventory_quantity_committed_check CHECK (quantity_committed >= 0),
  ADD CONSTRAINT inventory_quantity_consumed_check CHECK (quantity_consumed >= 0),
  ADD CONSTRAINT inventory_min_alert_qty_check CHECK (min_alert_qty IS NULL OR min_alert_qty >= 0),
  ADD CONSTRAINT inventory_commitment_balance_check CHECK (quantity_reserved + quantity_consumed <= quantity_committed);

COMMENT ON COLUMN public.inventory.quantity_committed IS
  'TC committed quantity (Model B). V1 initialized from quantity_on_hand legacy published stock; NOT verified physical. Not yet checkout SoT.';
COMMENT ON COLUMN public.inventory.quantity_consumed IS
  'Units consumed in current commitment cycle (Model B). V1 backfill 0.';
COMMENT ON COLUMN public.inventory.min_alert_qty IS
  'Optional store alert threshold; NULL = unset. Alert only; not OOS blocker.';
COMMENT ON COLUMN public.inventory.cycle_started_at IS
  'Start of current commitment cycle. Existing rows set at V1 migration time.';
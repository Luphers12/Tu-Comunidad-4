-- IMPL-DEMAND-SOURCING-FOUNDATION-01
CREATE TABLE public.order_demand_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id text NOT NULL UNIQUE DEFAULT tc_generate_public_id('DMD'),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  variant_id uuid NOT NULL REFERENCES public.product_variants(id),
  quantity_requested bigint NOT NULL,
  quantity_fulfilled bigint NOT NULL DEFAULT 0,
  unit_price_committed_minor bigint NOT NULL,
  currency varchar(3) NOT NULL,
  state text NOT NULL DEFAULT 'OPEN',
  unfulfillable_scope text NULL,
  version bigint NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT order_demand_items_quantity_requested_check CHECK (quantity_requested > 0),
  CONSTRAINT order_demand_items_quantity_fulfilled_check CHECK (quantity_fulfilled >= 0),
  CONSTRAINT order_demand_items_fulfilled_lte_requested_check CHECK (quantity_fulfilled <= quantity_requested),
  CONSTRAINT order_demand_items_price_check CHECK (unit_price_committed_minor >= 0),
  CONSTRAINT order_demand_items_version_check CHECK (version >= 0),
  CONSTRAINT order_demand_items_currency_check CHECK ((currency)::text ~ '^[A-Z]{3}$'),
  CONSTRAINT order_demand_items_state_check CHECK (state = ANY (ARRAY['OPEN'::text, 'PARTIALLY_FULFILLED'::text, 'FULFILLED'::text, 'UNFULFILLABLE'::text, 'CANCELLED'::text])),
  CONSTRAINT order_demand_items_unfulfillable_scope_check CHECK (unfulfillable_scope IS NULL OR unfulfillable_scope = ANY (ARRAY['COMMUNITY'::text, 'MUNICIPALITY'::text, 'DEPARTMENT'::text, 'ALL'::text])),
  CONSTRAINT order_demand_items_public_id_check CHECK (public_id ~~ 'DMD-%'::text)
);

CREATE INDEX order_demand_items_order_id_idx ON public.order_demand_items (order_id);
CREATE INDEX order_demand_items_order_id_state_idx ON public.order_demand_items (order_id, state);
CREATE INDEX order_demand_items_variant_id_idx ON public.order_demand_items (variant_id);

CREATE TABLE public.order_sourcing_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id text NOT NULL UNIQUE DEFAULT tc_generate_public_id('SRC'),
  demand_item_id uuid NOT NULL REFERENCES public.order_demand_items(id) ON DELETE CASCADE,
  store_profile_id uuid NOT NULL REFERENCES public.profiles(id),
  listing_id uuid NOT NULL REFERENCES public.store_listings(id),
  qty_allocated bigint NOT NULL,
  qty_fulfilled bigint NOT NULL DEFAULT 0,
  qty_released bigint NOT NULL DEFAULT 0,
  state text NOT NULL,
  failure_reason_code text NULL,
  failure_reason_note text NULL,
  sub_order_id uuid NULL REFERENCES public.sub_orders(id) ON DELETE SET NULL,
  order_item_id uuid NULL REFERENCES public.order_items(id) ON DELETE SET NULL,
  version bigint NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  closed_at timestamptz NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT order_sourcing_allocations_qty_allocated_check CHECK (qty_allocated > 0),
  CONSTRAINT order_sourcing_allocations_qty_fulfilled_check CHECK (qty_fulfilled >= 0),
  CONSTRAINT order_sourcing_allocations_qty_released_check CHECK (qty_released >= 0),
  CONSTRAINT order_sourcing_allocations_qty_balance_check CHECK (qty_fulfilled + qty_released <= qty_allocated),
  CONSTRAINT order_sourcing_allocations_version_check CHECK (version >= 0),
  CONSTRAINT order_sourcing_allocations_state_check CHECK (state = ANY (ARRAY['ACTIVE'::text, 'FULFILLED'::text, 'EXCEPTION_REJECTED'::text, 'SUPERSEDED'::text])),
  CONSTRAINT order_sourcing_allocations_public_id_check CHECK (public_id ~~ 'SRC-%'::text)
);

CREATE UNIQUE INDEX order_sourcing_allocations_order_item_id_uidx
  ON public.order_sourcing_allocations (order_item_id)
  WHERE order_item_id IS NOT NULL;

CREATE INDEX order_sourcing_allocations_demand_item_id_idx ON public.order_sourcing_allocations (demand_item_id);
CREATE INDEX order_sourcing_allocations_demand_item_id_state_idx ON public.order_sourcing_allocations (demand_item_id, state);
CREATE INDEX order_sourcing_allocations_store_profile_id_idx ON public.order_sourcing_allocations (store_profile_id);
CREATE INDEX order_sourcing_allocations_listing_id_idx ON public.order_sourcing_allocations (listing_id);
CREATE INDEX order_sourcing_allocations_sub_order_id_idx ON public.order_sourcing_allocations (sub_order_id);

ALTER TABLE public.order_demand_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_sourcing_allocations ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.order_demand_items FROM PUBLIC;
REVOKE ALL ON TABLE public.order_demand_items FROM anon;
REVOKE ALL ON TABLE public.order_demand_items FROM authenticated;
REVOKE ALL ON TABLE public.order_sourcing_allocations FROM PUBLIC;
REVOKE ALL ON TABLE public.order_sourcing_allocations FROM anon;
REVOKE ALL ON TABLE public.order_sourcing_allocations FROM authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.order_demand_items TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.order_sourcing_allocations TO service_role;
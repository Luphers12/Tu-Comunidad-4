CREATE TABLE public.products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id text UNIQUE NOT NULL DEFAULT public.tc_generate_public_id('PRD') CHECK (public_id LIKE 'PRD-%'),
  name text NOT NULL,
  description text,
  category text,
  subcategory text,
  product_class text NOT NULL DEFAULT 'NORMAL' CHECK (product_class IN ('NORMAL','PROCESSED_FOOD','UNPROCESSED_FOOD','PERISHABLE','MEDICINE','AGROCHEMICAL','HAZARDOUS_CHEMICAL','ALCOHOL','FUEL','WEAPON_AMMUNITION','RESTRICTED')),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.product_variants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id text UNIQUE NOT NULL DEFAULT public.tc_generate_public_id('VAR') CHECK (public_id LIKE 'VAR-%'),
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  sku text,
  variant_name text,
  unit_label text,
  weight_kg numeric(10,3) CHECK (weight_kg IS NULL OR weight_kg >= 0),
  volume_m3 numeric(10,4) CHECK (volume_m3 IS NULL OR volume_m3 >= 0),
  requires_cold_chain boolean NOT NULL DEFAULT false,
  requires_fragile_handling boolean NOT NULL DEFAULT false,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.store_listings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id text UNIQUE NOT NULL DEFAULT public.tc_generate_public_id('LST') CHECK (public_id LIKE 'LST-%'),
  store_profile_id uuid NOT NULL REFERENCES public.profiles(id),
  variant_id uuid NOT NULL REFERENCES public.product_variants(id),
  price_minor bigint NOT NULL CHECK (price_minor >= 0),
  currency varchar(3) NOT NULL DEFAULT 'GTQ' CHECK (currency ~ '^[A-Z]{3}$'),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (store_profile_id, variant_id)
);
CREATE TABLE public.inventory (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id uuid UNIQUE NOT NULL REFERENCES public.store_listings(id) ON DELETE CASCADE,
  quantity_on_hand bigint NOT NULL DEFAULT 0 CHECK (quantity_on_hand >= 0),
  quantity_reserved bigint NOT NULL DEFAULT 0 CHECK (quantity_reserved >= 0),
  version bigint NOT NULL DEFAULT 0 CHECK (version >= 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_inventory_reserved_not_over_hand CHECK (quantity_reserved <= quantity_on_hand)
);
CREATE TABLE public.order_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sub_order_id uuid NOT NULL REFERENCES public.sub_orders(id) ON DELETE CASCADE,
  listing_id uuid NOT NULL REFERENCES public.store_listings(id),
  variant_id uuid NOT NULL REFERENCES public.product_variants(id),
  quantity bigint NOT NULL CHECK (quantity > 0),
  unit_price_minor bigint NOT NULL CHECK (unit_price_minor >= 0),
  line_total_minor bigint NOT NULL CHECK (line_total_minor >= 0),
  currency varchar(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.inventory_reservations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  inventory_id uuid NOT NULL REFERENCES public.inventory(id),
  order_item_id uuid UNIQUE NOT NULL REFERENCES public.order_items(id) ON DELETE CASCADE,
  quantity bigint NOT NULL CHECK (quantity > 0),
  status text NOT NULL DEFAULT 'RESERVED' CHECK (status IN ('RESERVED','CONSUMED','RELEASED','EXPIRED')),
  reserved_at timestamptz NOT NULL DEFAULT now(),
  consumed_at timestamptz,
  released_at timestamptz,
  CONSTRAINT chk_inventory_reservation_terminal_times CHECK (NOT (consumed_at IS NOT NULL AND released_at IS NOT NULL))
);
ALTER TABLE public.sub_orders ADD CONSTRAINT uq_sub_orders_order_store UNIQUE (order_id, store_profile_id);
CREATE INDEX idx_products_class_active ON public.products(product_class, is_active);
CREATE INDEX idx_variants_product_active ON public.product_variants(product_id, is_active);
CREATE INDEX idx_listings_store_active ON public.store_listings(store_profile_id, is_active);
CREATE INDEX idx_listings_variant_active ON public.store_listings(variant_id, is_active);
CREATE INDEX idx_order_items_sub_order ON public.order_items(sub_order_id);
CREATE INDEX idx_order_items_listing ON public.order_items(listing_id);
CREATE INDEX idx_inventory_reservations_inventory_status ON public.inventory_reservations(inventory_id, status);
CREATE TRIGGER trg_products_updated_at BEFORE UPDATE ON public.products FOR EACH ROW EXECUTE FUNCTION public.tc_set_updated_at();
CREATE TRIGGER trg_product_variants_updated_at BEFORE UPDATE ON public.product_variants FOR EACH ROW EXECUTE FUNCTION public.tc_set_updated_at();
CREATE TRIGGER trg_store_listings_updated_at BEFORE UPDATE ON public.store_listings FOR EACH ROW EXECUTE FUNCTION public.tc_set_updated_at();
CREATE TRIGGER trg_inventory_updated_at BEFORE UPDATE ON public.inventory FOR EACH ROW EXECUTE FUNCTION public.tc_set_updated_at();
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_variants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_listings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_reservations ENABLE ROW LEVEL SECURITY;
CREATE POLICY products_public_read ON public.products FOR SELECT TO anon, authenticated USING (is_active = true);
CREATE POLICY product_variants_public_read ON public.product_variants FOR SELECT TO anon, authenticated USING (is_active = true);
CREATE POLICY store_listings_public_read ON public.store_listings FOR SELECT TO anon, authenticated USING (is_active = true);
CREATE POLICY inventory_store_read ON public.inventory FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.store_listings sl WHERE sl.id = inventory.listing_id AND sl.store_profile_id IN (SELECT profile_id FROM public.current_user_profile_ids() WHERE profile_type IN ('VEN','TIE'))));
CREATE POLICY order_items_actor_read ON public.order_items FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.sub_orders so JOIN public.orders o ON o.id = so.order_id WHERE so.id = order_items.sub_order_id AND (o.client_profile_id IN (SELECT profile_id FROM public.current_user_profile_ids() WHERE profile_type = 'CLI') OR so.store_profile_id IN (SELECT profile_id FROM public.current_user_profile_ids() WHERE profile_type IN ('VEN','TIE')))));
CREATE POLICY inventory_reservations_store_read ON public.inventory_reservations FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.inventory i JOIN public.store_listings sl ON sl.id = i.listing_id WHERE i.id = inventory_reservations.inventory_id AND sl.store_profile_id IN (SELECT profile_id FROM public.current_user_profile_ids() WHERE profile_type IN ('VEN','TIE'))));
REVOKE ALL ON TABLE public.products, public.product_variants, public.store_listings, public.inventory, public.order_items, public.inventory_reservations FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.products, public.product_variants, public.store_listings TO anon, authenticated;
GRANT SELECT ON TABLE public.inventory, public.order_items, public.inventory_reservations TO authenticated;
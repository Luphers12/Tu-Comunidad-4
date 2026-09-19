CREATE TABLE public.package_contents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  package_id uuid NOT NULL REFERENCES public.packages(id),
  order_item_id uuid NOT NULL REFERENCES public.order_items(id),
  quantity bigint NOT NULL CHECK (quantity > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT package_contents_package_item_key UNIQUE (package_id, order_item_id)
);

CREATE INDEX package_contents_package_id_idx ON public.package_contents(package_id);
CREATE INDEX package_contents_order_item_id_idx ON public.package_contents(order_item_id);

ALTER TABLE public.package_contents ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.package_contents FROM PUBLIC;
REVOKE ALL ON TABLE public.package_contents FROM anon;
REVOKE ALL ON TABLE public.package_contents FROM authenticated;

ALTER TABLE public.packages
  ADD COLUMN length_cm numeric,
  ADD COLUMN width_cm numeric,
  ADD COLUMN height_cm numeric,
  ADD COLUMN package_form text;

ALTER TABLE public.packages
  ADD CONSTRAINT packages_length_cm_check CHECK (length_cm IS NULL OR length_cm > 0),
  ADD CONSTRAINT packages_width_cm_check CHECK (width_cm IS NULL OR width_cm > 0),
  ADD CONSTRAINT packages_height_cm_check CHECK (height_cm IS NULL OR height_cm > 0),
  ADD CONSTRAINT packages_package_form_check CHECK (
    package_form IS NULL OR package_form = ANY (ARRAY[
      'BOX'::text, 'MAILER'::text, 'BAG'::text, 'TUBE'::text, 'IRREGULAR'::text
    ])
  );
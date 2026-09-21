-- VERIFIED REPLAY OVERLAY — 2026-09-20
-- Substitute for 20260823204422_staging_marketplace_pilot_v1.sql during clean replay.
-- The original file mixes STAGING-only data with the RPC below.
-- External seed dependency PER-3C3250B60ECC4E9E is intentionally excluded.
-- The forensic migration file remains untouched.

create or replace function public.get_marketplace_offers(p_community_id uuid default null)
returns table (
  product_id uuid,
  product_public_id text,
  product_name text,
  category text,
  subcategory text,
  product_class text,
  variant_id uuid,
  variant_public_id text,
  variant_name text,
  unit_label text,
  sku text,
  listing_id uuid,
  listing_public_id text,
  price_minor bigint,
  currency varchar,
  available_quantity bigint,
  in_stock boolean,
  store_profile_id uuid,
  store_public_id text,
  commercial_name text,
  store_rating numeric,
  store_community_label text,
  selected_community_id uuid,
  coverage_mode text,
  home_delivery_available boolean,
  ptc_id uuid,
  ptc_public_id text,
  ptc_public_name text
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    p.id,
    p.public_id,
    p.name,
    p.category,
    p.subcategory,
    p.product_class,
    v.id,
    v.public_id,
    v.variant_name,
    v.unit_label,
    v.sku,
    sl.id,
    sl.public_id,
    sl.price_minor,
    sl.currency,
    greatest(i.quantity_on_hand - i.quantity_reserved, 0)::bigint,
    (i.quantity_on_hand - i.quantity_reserved) > 0,
    sd.store_profile_id,
    sd.store_public_id,
    sd.commercial_name,
    sd.rating,
    sd.community_label,
    p_community_id,
    sc.coverage_mode,
    coalesce(sc.home_delivery_available, false),
    pp.id,
    pp.public_id,
    pp.public_name
  from public.store_listings sl
  join public.product_variants v on v.id = sl.variant_id and v.is_active
  join public.products p on p.id = v.product_id and p.is_active
  join public.inventory i on i.listing_id = sl.id
  join public.store_directory sd on sd.store_profile_id = sl.store_profile_id and sd.is_active and sd.is_open
  left join public.service_coverage sc
    on sc.community_id = p_community_id and sc.is_active
  left join public.ptc_points pp
    on pp.id = sc.ptc_id and pp.is_active
  where sl.is_active
    and (p_community_id is null or sd.territory_id = (select c.public_id from public.communities c where c.id = p_community_id))
  order by p.name, sl.price_minor, sd.rating desc nulls last;
$$;

revoke all on function public.get_marketplace_offers(uuid) from public;
grant execute on function public.get_marketplace_offers(uuid) to anon, authenticated;

-- STAGING ONLY: controlled pilot catalog and safe public marketplace RPC.
-- Additive/idempotent. Does not alter production.

do $$
declare
  v_person_id uuid;
  v_bulej_public_id text;
begin
  select id into v_person_id
  from public.persons
  where public_id = 'PER-3C3250B60ECC4E9E'
  limit 1;

  if v_person_id is null then
    raise exception 'STAGING_SEED_PERSON_MISSING';
  end if;

  select c.public_id into v_bulej_public_id
  from public.communities c
  join public.municipalities m on m.id = c.municipality_id
  join public.departments d on d.id = m.department_id
  where d.name = 'Huehuetenango'
    and m.name = 'San Mateo Ixtatán'
    and c.name = 'Bulej'
  limit 1;

  if v_bulej_public_id is null then
    raise exception 'STAGING_BULEJ_COMMUNITY_MISSING';
  end if;

  insert into public.profiles (public_id, person_id, profile_type, status, territory_id)
  select 'TIE-STG-MATILDE', v_person_id, 'TIE', 'active', v_bulej_public_id
  where not exists (select 1 from public.profiles where public_id = 'TIE-STG-MATILDE');

  insert into public.profiles (public_id, person_id, profile_type, status, territory_id)
  select 'TIE-STG-BENDICION', v_person_id, 'TIE', 'active', v_bulej_public_id
  where not exists (select 1 from public.profiles where public_id = 'TIE-STG-BENDICION');

  insert into public.store_directory (store_profile_id, store_public_id, commercial_name, territory_id, community_label, is_open, is_active, rating)
  select p.id, p.public_id, 'Abarrotería Doña Matilde', v_bulej_public_id, 'Bulej', true, true, 4.8
  from public.profiles p
  where p.public_id = 'TIE-STG-MATILDE'
    and not exists (select 1 from public.store_directory sd where sd.store_public_id = p.public_id);

  insert into public.store_directory (store_profile_id, store_public_id, commercial_name, territory_id, community_label, is_open, is_active, rating)
  select p.id, p.public_id, 'Tienda La Bendición', v_bulej_public_id, 'Bulej', true, true, 4.6
  from public.profiles p
  where p.public_id = 'TIE-STG-BENDICION'
    and not exists (select 1 from public.store_directory sd where sd.store_public_id = p.public_id);
end $$;

insert into public.products (name, description, category, subcategory, product_class, is_active)
select 'Maíz blanco', 'Maíz blanco de consumo básico para prueba controlada de STAGING.', 'Abarrotes', 'Granos', 'UNPROCESSED_FOOD', true
where not exists (select 1 from public.products where name = 'Maíz blanco');

insert into public.products (name, description, category, subcategory, product_class, is_active)
select 'Frijol negro', 'Frijol negro de consumo básico para prueba controlada de STAGING.', 'Abarrotes', 'Granos', 'UNPROCESSED_FOOD', true
where not exists (select 1 from public.products where name = 'Frijol negro');

insert into public.products (name, description, category, subcategory, product_class, is_active)
select 'Aceite vegetal', 'Aceite vegetal para prueba controlada de STAGING.', 'Abarrotes', 'Aceites', 'PROCESSED_FOOD', true
where not exists (select 1 from public.products where name = 'Aceite vegetal');

insert into public.product_variants (product_id, sku, variant_name, unit_label, weight_kg, is_active)
select p.id, 'STG-MAIZ-1LB', '1 libra', '1 lb', 0.453592, true
from public.products p
where p.name = 'Maíz blanco'
  and not exists (select 1 from public.product_variants v where v.sku = 'STG-MAIZ-1LB');

insert into public.product_variants (product_id, sku, variant_name, unit_label, weight_kg, is_active)
select p.id, 'STG-FRIJOL-1LB', '1 libra', '1 lb', 0.453592, true
from public.products p
where p.name = 'Frijol negro'
  and not exists (select 1 from public.product_variants v where v.sku = 'STG-FRIJOL-1LB');

insert into public.product_variants (product_id, sku, variant_name, unit_label, weight_kg, is_active)
select p.id, 'STG-ACEITE-1L', '1 litro', '1 L', 0.92, true
from public.products p
where p.name = 'Aceite vegetal'
  and not exists (select 1 from public.product_variants v where v.sku = 'STG-ACEITE-1L');

-- Same products in two stores, with controlled price differences for offer comparison.
insert into public.store_listings (store_profile_id, variant_id, price_minor, currency, is_active)
select sp.id, v.id,
  case v.sku when 'STG-MAIZ-1LB' then 500 when 'STG-FRIJOL-1LB' then 950 when 'STG-ACEITE-1L' then 2400 end,
  'GTQ', true
from public.profiles sp
cross join public.product_variants v
where sp.public_id = 'TIE-STG-MATILDE'
  and v.sku in ('STG-MAIZ-1LB','STG-FRIJOL-1LB','STG-ACEITE-1L')
  and not exists (
    select 1 from public.store_listings sl where sl.store_profile_id = sp.id and sl.variant_id = v.id
  );

insert into public.store_listings (store_profile_id, variant_id, price_minor, currency, is_active)
select sp.id, v.id,
  case v.sku when 'STG-MAIZ-1LB' then 475 when 'STG-FRIJOL-1LB' then 900 when 'STG-ACEITE-1L' then 2350 end,
  'GTQ', true
from public.profiles sp
cross join public.product_variants v
where sp.public_id = 'TIE-STG-BENDICION'
  and v.sku in ('STG-MAIZ-1LB','STG-FRIJOL-1LB','STG-ACEITE-1L')
  and not exists (
    select 1 from public.store_listings sl where sl.store_profile_id = sp.id and sl.variant_id = v.id
  );

insert into public.inventory (listing_id, quantity_on_hand, quantity_reserved, version)
select sl.id,
  case
    when sp.public_id = 'TIE-STG-MATILDE' and v.sku = 'STG-MAIZ-1LB' then 80
    when sp.public_id = 'TIE-STG-MATILDE' and v.sku = 'STG-FRIJOL-1LB' then 45
    when sp.public_id = 'TIE-STG-MATILDE' and v.sku = 'STG-ACEITE-1L' then 24
    when sp.public_id = 'TIE-STG-BENDICION' and v.sku = 'STG-MAIZ-1LB' then 30
    when sp.public_id = 'TIE-STG-BENDICION' and v.sku = 'STG-FRIJOL-1LB' then 60
    when sp.public_id = 'TIE-STG-BENDICION' and v.sku = 'STG-ACEITE-1L' then 18
    else 0
  end,
  0,
  1
from public.store_listings sl
join public.profiles sp on sp.id = sl.store_profile_id
join public.product_variants v on v.id = sl.variant_id
where sp.public_id in ('TIE-STG-MATILDE','TIE-STG-BENDICION')
  and not exists (select 1 from public.inventory i where i.listing_id = sl.id);

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

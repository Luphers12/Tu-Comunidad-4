-- TU COMUNIDAD: stable public catalog contract for UI migration from Lovable LAB.
-- Public by design: exposes only commercial catalog/store/territory fields, never person/contact/private location data.

create or replace function public.tc_public_catalog(
  p_community_public_id text default null,
  p_municipality_name text default null,
  p_department_name text default null,
  p_query text default null,
  p_category text default null,
  p_limit integer default 100
)
returns table(
  product_public_id text,
  product_name text,
  product_description text,
  category text,
  subcategory text,
  product_class text,
  variant_public_id text,
  variant_name text,
  unit_label text,
  listing_public_id text,
  price_minor bigint,
  currency varchar,
  available_quantity bigint,
  in_stock boolean,
  store_public_id text,
  commercial_name text,
  store_rating numeric,
  store_community_public_id text,
  store_community_name text,
  municipality_name text,
  department_name text
)
language sql
stable
security definer
set search_path = ''
as $function$
  select
    p.public_id,
    p.name,
    p.description,
    p.category,
    p.subcategory,
    p.product_class,
    v.public_id,
    v.variant_name,
    v.unit_label,
    sl.public_id,
    sl.price_minor,
    sl.currency,
    greatest(i.quantity_on_hand - i.quantity_reserved,0)::bigint,
    (i.quantity_on_hand - i.quantity_reserved) > 0,
    sd.store_public_id,
    sd.commercial_name,
    sd.rating,
    c.public_id,
    c.name,
    m.name,
    d.name
  from public.store_listings sl
  join public.product_variants v on v.id=sl.variant_id and v.is_active
  join public.products p on p.id=v.product_id and p.is_active
  join public.inventory i on i.listing_id=sl.id
  join public.store_directory sd on sd.store_profile_id=sl.store_profile_id and sd.is_active and sd.is_open
  join public.communities c on c.public_id=sd.territory_id and c.is_active
  join public.municipalities m on m.id=c.municipality_id and m.is_active
  join public.departments d on d.id=m.department_id and d.is_active
  where sl.is_active
    and (
      nullif(btrim(coalesce(p_community_public_id,'')),'') is null
      or c.public_id=upper(btrim(p_community_public_id))
    )
    and (
      nullif(btrim(coalesce(p_municipality_name,'')),'') is null
      or lower(m.name)=lower(btrim(p_municipality_name))
    )
    and (
      nullif(btrim(coalesce(p_department_name,'')),'') is null
      or lower(d.name)=lower(btrim(p_department_name))
    )
    and (
      nullif(btrim(coalesce(p_category,'')),'') is null
      or lower(coalesce(p.category,''))=lower(btrim(p_category))
    )
    and (
      nullif(btrim(coalesce(p_query,'')),'') is null
      or concat_ws(' ',p.name,p.description,p.category,p.subcategory,v.variant_name,v.unit_label,sd.commercial_name)
         ilike '%' || btrim(p_query) || '%'
    )
  order by
    case when (i.quantity_on_hand-i.quantity_reserved)>0 then 0 else 1 end,
    p.name,
    sl.price_minor,
    sd.rating desc nulls last
  limit greatest(1,least(coalesce(p_limit,100),200));
$function$;

comment on function public.tc_public_catalog(text,text,text,text,text,integer) is
'Public read-only marketplace contract. Contains no person IDs, client addresses, private contacts, or operational coordinates.';

revoke all on function public.tc_public_catalog(text,text,text,text,text,integer) from public;
grant execute on function public.tc_public_catalog(text,text,text,text,text,integer) to anon, authenticated;

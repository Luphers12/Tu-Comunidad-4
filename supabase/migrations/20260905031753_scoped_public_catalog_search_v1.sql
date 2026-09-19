create or replace function public.tc_search_public_catalog_scoped(
  p_community_public_id text default null,
  p_municipality_name text default null,
  p_department_name text default null,
  p_query text default null,
  p_category text default null,
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_community text := nullif(upper(btrim(coalesce(p_community_public_id,''))), '');
  v_municipality text := nullif(btrim(coalesce(p_municipality_name,'')), '');
  v_department text := nullif(btrim(coalesce(p_department_name,'')), '');
  v_rows jsonb;
  v_count int;
  v_limit int := greatest(1, least(coalesce(p_limit,100),200));
begin
  -- Resolve parent territory names from the community when possible so callers
  -- do not need to duplicate hierarchy logic.
  if v_community is not null then
    select m.name, d.name into v_municipality, v_department
    from public.communities c
    join public.municipalities m on m.id=c.municipality_id
    join public.departments d on d.id=m.department_id
    where c.public_id=v_community and c.is_active and m.is_active and d.is_active;
  end if;

  if v_community is not null then
    select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb), count(*)
      into v_rows, v_count
    from public.tc_public_catalog(v_community,null,null,p_query,p_category,v_limit) x;
    if v_count > 0 then
      return jsonb_build_object('scope','community','widened',false,'rows',v_rows);
    end if;
  end if;

  if v_municipality is not null then
    select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb), count(*)
      into v_rows, v_count
    from public.tc_public_catalog(null,v_municipality,null,p_query,p_category,v_limit) x;
    if v_count > 0 then
      return jsonb_build_object('scope','municipality','widened',v_community is not null,'rows',v_rows);
    end if;
  end if;

  if v_department is not null then
    select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb), count(*)
      into v_rows, v_count
    from public.tc_public_catalog(null,null,v_department,p_query,p_category,v_limit) x;
    if v_count > 0 then
      return jsonb_build_object('scope','department','widened',(v_community is not null or v_municipality is not null),'rows',v_rows);
    end if;
  end if;

  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb), count(*)
    into v_rows, v_count
  from public.tc_public_catalog(null,null,null,p_query,p_category,v_limit) x;

  return jsonb_build_object(
    'scope','outside',
    'widened',(v_community is not null or v_municipality is not null or v_department is not null),
    'rows',coalesce(v_rows,'[]'::jsonb)
  );
end;
$function$;

comment on function public.tc_search_public_catalog_scoped(text,text,text,text,text,integer) is
'Public catalog search with canonical widening order community -> municipality -> department -> outside. Returns only one scope at a time.';

revoke all on function public.tc_search_public_catalog_scoped(text,text,text,text,text,integer) from public;
grant execute on function public.tc_search_public_catalog_scoped(text,text,text,text,text,integer) to anon, authenticated;

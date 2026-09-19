begin;

-- Safer defaults for future objects: no accidental client access.
alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public revoke execute on functions from anon, authenticated;

-- Read-only public contract for feature-gate state. Exposes no internal UUIDs or notes/source refs.
create or replace function public.tc_get_feature_gates()
returns table (
  feature_key text,
  domain text,
  parent_feature_key text,
  display_name text,
  source_status text,
  backend_status text,
  safety_status text,
  legal_status text,
  cultural_status text,
  approval_status text,
  is_enabled boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    g.feature_key,
    g.domain,
    g.parent_feature_key,
    g.display_name,
    g.source_status,
    g.backend_status,
    g.safety_status,
    g.legal_status,
    g.cultural_status,
    g.approval_status,
    g.is_enabled
  from public.tc_feature_gates g
  order by g.domain, g.feature_key;
$$;

revoke all on function public.tc_get_feature_gates() from public;
grant execute on function public.tc_get_feature_gates() to anon, authenticated, service_role;

create or replace function public.tc_is_feature_enabled(p_feature_key text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select g.is_enabled
    from public.tc_feature_gates g
    where g.feature_key = p_feature_key
  ), false);
$$;

revoke all on function public.tc_is_feature_enabled(text) from public;
grant execute on function public.tc_is_feature_enabled(text) to anon, authenticated, service_role;

commit;
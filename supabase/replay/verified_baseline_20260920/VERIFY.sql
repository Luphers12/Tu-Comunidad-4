-- VERIFIED REPRODUCIBLE BASELINE — verification query
-- Expected values were matched against STAGING on 2026-09-20.
-- Extra preview extension pg_net is intentionally outside this fingerprint.

with fp as (
select jsonb_build_object(
 'tables',(select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r'),
 'columns',(select jsonb_build_object('count',count(*),'hash',md5(coalesce(string_agg(c.relname||'.'||a.attname||'|'||a.attnum::text||'|'||pg_catalog.format_type(a.atttypid,a.atttypmod)||'|'||a.attnotnull::text||'|'||coalesce(pg_get_expr(d.adbin,d.adrelid),''),E'\n' order by c.relname,a.attnum),''))) from pg_attribute a join pg_class c on c.oid=a.attrelid join pg_namespace n on n.oid=c.relnamespace left join pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum where n.nspname='public' and c.relkind in ('r','p') and a.attnum>0 and not a.attisdropped),
 'constraints',(select jsonb_build_object('count',count(*),'hash',md5(coalesce(string_agg(c.relname||'|'||con.conname||'|'||con.contype::text||'|'||pg_get_constraintdef(con.oid,true),E'\n' order by c.relname,con.conname),''))) from pg_constraint con join pg_class c on c.oid=con.conrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public'),
 'indexes',(select jsonb_build_object('count',count(*),'hash',md5(coalesce(string_agg(tablename||'|'||indexname||'|'||indexdef,E'\n' order by tablename,indexname),''))) from pg_indexes where schemaname='public'),
 'views',(select jsonb_build_object('count',count(*),'hash',md5(coalesce(string_agg(viewname||'|'||definition,E'\n' order by viewname),''))) from pg_views where schemaname='public'),
 'functions',(select jsonb_build_object('count',count(*),'hash',md5(coalesce(string_agg(p.oid::regprocedure::text||'|'||p.prosecdef::text||'|'||coalesce(p.proconfig::text,'')||'|'||pg_get_functiondef(p.oid),E'\n' order by p.oid::regprocedure::text),''))) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'),
 'policies',(select jsonb_build_object('count',count(*),'public_count',count(*) filter(where schemaname='public'),'hash',md5(coalesce(string_agg(schemaname||'|'||tablename||'|'||policyname||'|'||permissive||'|'||roles::text||'|'||cmd||'|'||coalesce(qual,'')||'|'||coalesce(with_check,''),E'\n' order by schemaname,tablename,policyname),''))) from pg_policies),
 'triggers',(select jsonb_build_object('count',count(*),'public_count',count(*) filter(where n.nspname='public'),'hash',md5(coalesce(string_agg(n.nspname||'|'||c.relname||'|'||t.tgname||'|'||pg_get_triggerdef(t.oid,true),E'\n' order by n.nspname,c.relname,t.tgname),''))) from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where not t.tgisinternal),
 'enums',(select jsonb_build_object('count',count(distinct t.oid),'hash',md5(coalesce(string_agg(t.typname||'|'||e.enumsortorder::text||'|'||e.enumlabel,E'\n' order by t.typname,e.enumsortorder),''))) from pg_type t join pg_namespace n on n.oid=t.typnamespace join pg_enum e on e.enumtypid=t.oid where n.nspname='public'),
 'sequences',(select jsonb_build_object('count',count(*),'hash',md5(coalesce(string_agg(sequencename||'|'||data_type||'|'||start_value::text||'|'||min_value::text||'|'||max_value::text||'|'||increment_by::text||'|'||cycle::text,E'\n' order by sequencename),''))) from pg_sequences where schemaname='public'),
 'relation_acl',(select jsonb_build_object('count',count(*),'hash',md5(coalesce(string_agg(c.relkind::text||'|'||c.relname||'|'||case when x.grantee=0 then 'PUBLIC' else coalesce(r.rolname,x.grantee::text) end||'|'||x.privilege_type||'|'||x.is_grantable::text,E'\n' order by c.relkind,c.relname,case when x.grantee=0 then 'PUBLIC' else coalesce(r.rolname,x.grantee::text) end,x.privilege_type,x.is_grantable),''))) from pg_class c join pg_namespace n on n.oid=c.relnamespace cross join lateral aclexplode(coalesce(c.relacl,acldefault(case when c.relkind='S' then 'S'::"char" else 'r'::"char" end,c.relowner))) x left join pg_roles r on r.oid=x.grantee where n.nspname='public' and c.relkind in ('r','v','m','S')),
 'function_acl',(select jsonb_build_object('count',count(*),'hash',md5(coalesce(string_agg(p.oid::regprocedure::text||'|'||case when x.grantee=0 then 'PUBLIC' else coalesce(r.rolname,x.grantee::text) end||'|'||x.privilege_type||'|'||x.is_grantable::text,E'\n' order by p.oid::regprocedure::text,case when x.grantee=0 then 'PUBLIC' else coalesce(r.rolname,x.grantee::text) end,x.privilege_type,x.is_grantable),''))) from pg_proc p join pg_namespace n on n.oid=p.pronamespace cross join lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) x left join pg_roles r on r.oid=x.grantee where n.nspname='public')
) v
)
select v,
 (v->>'tables')::int=178 as tables_ok,
 (v->'columns'->>'count')::int=1954 and v->'columns'->>'hash'='93f7042cd926fbd5464e8607ea16521a' as columns_ok,
 (v->'constraints'->>'count')::int=1165 and v->'constraints'->>'hash'='d702b5dc6b3ed96433eeee19a3b22bc5' as constraints_ok,
 (v->'indexes'->>'count')::int=594 and v->'indexes'->>'hash'='a59afaeda5f0eba498e656e77a09a23c' as indexes_ok,
 (v->'views'->>'count')::int=4 and v->'views'->>'hash'='8675b853addab1221dcdacb7c0b141fd' as views_ok,
 (v->'functions'->>'count')::int=180 and v->'functions'->>'hash'='f9a3410351f8ff0a534b3e25f7f28d94' as functions_ok,
 (v->'policies'->>'count')::int=59 and (v->'policies'->>'public_count')::int=58 and v->'policies'->>'hash'='4af3fcd553e63f5be5e4ca1ae48e015e' as policies_ok,
 (v->'triggers'->>'count')::int=96 and (v->'triggers'->>'public_count')::int=87 and v->'triggers'->>'hash'='2909997f2180833408f93bdedf5af3dd' as triggers_ok,
 (v->'enums'->>'count')::int=7 and v->'enums'->>'hash'='6b400f78f2e8c96c50eef0fde2214c8b' as enums_ok,
 (v->'sequences'->>'count')::int=31 and v->'sequences'->>'hash'='a7d9799b98782db4d69178ca2fdb33e5' as sequences_ok,
 (v->'relation_acl'->>'count')::int=3888 and v->'relation_acl'->>'hash'='5d9c3a3b88834b3dea7d31571e16572c' as relation_acl_ok,
 (v->'function_acl'->>'count')::int=485 and v->'function_acl'->>'hash'='1768421c5a49cd25e48e372e2a549221' as function_acl_ok,
 not has_function_privilege('anon','public.process_event(jsonb)','EXECUTE') as process_event_anon_denied,
 not has_function_privilege('authenticated','public.process_event(jsonb)','EXECUTE') as process_event_authenticated_denied,
 has_function_privilege('service_role','public.process_event(jsonb)','EXECUTE') as process_event_service_role_ok,
 not has_function_privilege('anon','public.resolve_sync_conflict(text,text,text,text)','EXECUTE') as resolve_sync_anon_denied,
 not has_function_privilege('authenticated','public.resolve_sync_conflict(text,text,text,text)','EXECUTE') as resolve_sync_authenticated_denied,
 has_function_privilege('service_role','public.resolve_sync_conflict(text,text,text,text)','EXECUTE') as resolve_sync_service_role_ok,
 not exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' and not c.relrowsecurity) as all_public_tables_rls,
 not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef and not exists(select 1 from unnest(coalesce(p.proconfig,'{}')) z where z like 'search_path=%')) as all_public_secdef_search_path,
 not (select pg_get_functiondef(p.oid) ilike '%recipient_name%' from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='tc_render_package_label' limit 1) as label_no_recipient_name,
 not (select pg_get_functiondef(p.oid) ilike '%full_name%' from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='tc_render_package_label' limit 1) as label_no_full_name,
 not (select pg_get_functiondef(p.oid) ilike '%client_profile_id%' from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='tc_render_package_label' limit 1) as label_no_client_profile_id
from fp;

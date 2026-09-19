-- Invariantes de seguridad verificados sobre una base recién reproducida.
-- Se ejecuta al final de scripts/db/replay_migrations.sh y falla si se rompe alguno.
do $$
declare
  v_bad text;
begin
  -- 1. Toda funcion SECURITY DEFINER en public debe fijar search_path explicito.
  select string_agg(p.oid::regprocedure::text, ', ')
    into v_bad
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prosecdef
    and not exists (
      select 1 from unnest(coalesce(p.proconfig, '{}')) c
      where c like 'search_path=%'
    );
  if v_bad is not null then
    raise exception 'SECURITY DEFINER sin search_path: %', v_bad;
  end if;

  -- 2. Toda tabla de datos en public debe tener RLS habilitado.
  select string_agg(c.relname, ', ')
    into v_bad
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind = 'r'
    and not c.relrowsecurity;
  if v_bad is not null then
    raise exception 'Tablas public sin RLS: %', v_bad;
  end if;

  -- 3. Las capacidades sensibles quedan fail-closed hasta aprobacion explicita.
  select string_agg(feature_key, ', ')
    into v_bad
  from public.tc_feature_gates
  where is_enabled
    and (approval_status is distinct from 'APPROVED'
         or safety_status = 'PENDING'
         or legal_status = 'PENDING');
  if v_bad is not null then
    raise exception 'Feature gates habilitados sin aprobacion completa: %', v_bad;
  end if;

  -- 4. Las funciones cuyo fuente no se recupero no pueden ejecutarse por roles de cliente.
  select string_agg(p.oid::regprocedure::text, ', ')
    into v_bad
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('process_event', 'resolve_sync_conflict')
    and (has_function_privilege('authenticated', p.oid, 'execute')
         or has_function_privilege('anon', p.oid, 'execute'));
  if v_bad is not null then
    raise exception 'RPC no recuperada ejecutable por cliente: %', v_bad;
  end if;
end $$;

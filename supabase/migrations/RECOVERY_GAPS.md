# Brechas de recuperación del historial de migraciones

Estado verificado el 2026-09-19 reproduciendo `supabase/migrations` desde cero con
`scripts/db/replay_migrations.sh`.

## 1. Fuente perdida: `public.process_event(jsonb)` y `public.resolve_sync_conflict(text,text,text,text)`

Las versiones `20260823035707_0004_process_event.sql` y
`20260823035750_0004_resolve_sync_conflict.sql` no contenían SQL: sólo ejecutaban

```sql
SELECT convert_from(decode(string_agg(chunk,'' ORDER BY seq),'base64'),'UTF8')
INTO v_sql FROM public._tc_migration_chunks;
EXECUTE v_sql;
```

sobre `public._tc_migration_chunks`, una tabla buffer que se creaba vacía
(`20260823035239`) y se borraba después (`20260823035804`). Los `INSERT` con el
base64 nunca quedaron en el repositorio, así que en una base limpia el `EXECUTE`
recibía `NULL` y el replay abortaba: `query string argument of EXECUTE is null`.

Consecuencia: el cuerpo real de esas dos RPC existe únicamente en la base de
staging. No se inventó una implementación. Cada archivo define ahora un
placeholder fail-closed que levanta `FUNCTION_SOURCE_NOT_RECOVERED: <función>` y
revoca `EXECUTE` a `PUBLIC`; `20260826221534` mantiene la revocación a
`authenticated`. El invariante 4 de `supabase/tests/security_invariants.sql`
verifica que ningún rol de cliente pueda ejecutarlas.

### Recuperar la fuente real desde staging

```bash
psql "$STAGING_DATABASE_URL" -At -c \
  "select pg_get_functiondef(p.oid)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname='public'
      and p.proname in ('process_event','resolve_sync_conflict')"
```

El resultado debe reemplazar el placeholder en una migración nueva (no
reescribiendo el histórico) y volver a correr el replay.

**NECESITA DECISIÓN DE PRODUCTO**: si staging ya no existe, hay que redefinir
desde cero las reglas de `process_event` (ingesta offline/custodia) y
`resolve_sync_conflict` (resolución administrativa de conflictos), incluyendo
quién puede invocarlas y qué evidencia registran.

## 2. Seed dependiente de una identidad externa

`20260823204422_staging_marketplace_pilot_v1.sql` (declarada STAGING ONLY) cuelga
las tiendas piloto de la persona `PER-3C3250B60ECC4E9E`, creada por un signup real
que ninguna migración reproduce. Antes abortaba el replay con
`STAGING_SEED_PERSON_MISSING`. Ahora emite un `NOTICE` y omite el seed en lugar de
fabricar una identidad falsa.

## 3. Feature gates raíz ausentes

`linguistics.work_program` y `linguistics.compensation` se usaban como
`parent_feature_key` sin haberse insertado nunca, rompiendo la FK en una base
limpia. Se insertan en las migraciones que los introdujeron, fail-closed
(`is_enabled=false`, aprobaciones `PENDING`).

## 4. `iso_code` de Chuj

El seed canónico dejaba `Chuj` con `iso_code` nulo y
`20260827191235_linguistic_assessment_chuj_smi_pilot_v1.sql` lo busca por
`iso_code='cac'`, abortando con `Chuj San Mateo Ixtatan language/variant not found`.
Se corrigió el seed a `cac`.

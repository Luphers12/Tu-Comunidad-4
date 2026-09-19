# Tu Comunidad

App Flutter (generada con FlutterFlow) sobre Supabase/PostgreSQL + PostGIS.

## App

```bash
flutter pub get
flutter analyze
flutter test
```

Las dependencias fijadas por FlutterFlow (`font_awesome_flutter 10.7.0`,
`page_transition 2.1.0`) no compilan con Flutter 3.40+; el proyecto se verifica
con Flutter **3.35.5** (Dart 3.9.2).

## Base de datos

`supabase/migrations` es el historial canónico y debe poder reproducirse desde
cero, en orden de nombre de archivo:

```bash
scripts/db/replay_migrations.sh   # requiere Docker
```

El script levanta un PostGIS efímero, aplica `supabase/tests/local_bootstrap.sql`
(schemas/roles/stubs de `auth` y `storage` que Supabase provee en la nube),
reproduce todas las migraciones y luego ejecuta
`supabase/tests/security_invariants.sql`, que falla si aparece una función
`SECURITY DEFINER` sin `search_path`, una tabla de `public` sin RLS, un feature
gate habilitado sin aprobación completa, o una RPC no recuperada ejecutable por
`anon`/`authenticated`.

Brechas conocidas del historial recuperado: ver
[`supabase/migrations/RECOVERY_GAPS.md`](supabase/migrations/RECOVERY_GAPS.md).

# TU COMUNIDAD — VERIFIED REPRODUCIBLE BASELINE

**Date:** 2026-09-20  
**Repository:** `Luphers12/Tu-Comunidad-4`  
**Branch:** `tc/full-build-20260918`  
**STAGING:** `tu-comunidad-staging` / `ckvwfeljoonwhzmtrmnw`

## HECHO VERIFICADO

A clean Supabase preview branch reproduced the historical-chain failure after 13 migrations: `public._tc_migration_chunks` existed with zero rows, so the next dynamic loader could not reconstruct its SQL.

The replay was completed without modifying the 104 forensic migration files by using a separate overlay that:

1. restores the exact LIVE definitions and restricted ACLs of `process_event(jsonb)` and `resolve_sync_conflict(text,text,text,text)`;
2. separates the marketplace RPC from STAGING-only seed data that depends on an out-of-band person;
3. restores fail-closed parent feature gates `linguistics.work_program` and `linguistics.compensation`;
4. restores the verified LIVE Chuj code `cac`;
5. normalizes effective application ACLs to the STAGING snapshot.

## Final comparison

- tables: 178 / 178
- columns: 1954 / 1954 exact fingerprint
- constraints: 1165 / 1165 exact fingerprint
- indexes: 594 / 594 exact fingerprint
- views: 4 / 4 exact fingerprint
- functions: 180 / 180; bodies/search_path/SECURITY DEFINER exact
- policies: 59 / 59 exact, including Storage
- triggers: 96 / 96 exact, including Auth/Storage/Realtime
- enums: 7 / 7 exact
- sequences: 31 / 31 exact
- effective relation ACLs: exact
- effective function ACLs: exact

Critical checks:
- `process_event`: anon denied, authenticated denied, service_role allowed.
- `resolve_sync_conflict`: anon denied, authenticated denied, service_role allowed.
- package label contains no `recipient_name`, `full_name`, or `client_profile_id`.
- all public tables have RLS enabled.
- every public SECURITY DEFINER function has explicit `search_path`.

The preview environment's extra `pg_net` extension is an expected platform difference.

The Security Advisor matched STAGING on database-level findings: 120 RLS-enabled/no-policy informational findings, 10 anon SECURITY DEFINER warnings, and 86 authenticated SECURITY DEFINER warnings. STAGING separately reports an Auth configuration warning for leaked-password protection; that is outside SQL replay.

```text
FORENSIC_SOT_104: PASS
VERIFIED_REPRODUCIBLE_BASELINE: PASS
FOUNDATION_GATE: READY
```

Temporary preview branches were deleted after verification. No STAGING, Production, FlutterFlow, Foundation, merge, or deploy write was performed.

Replay artifact:
`supabase/replay/verified_baseline_20260920/`

# TU COMUNIDAD — Verified Reproducible Baseline Overlay

**Status:** VERIFIED — 2026-09-20

This directory is deliberately outside `supabase/migrations/`.

The 104 SQL files in `supabase/migrations/` remain the immutable **forensic history** recovered from STAGING. This overlay does not rewrite them.

## Replay procedure

1. Apply forensic migrations through `20260823035239_staging_migration_chunk_buffer.sql`.
2. Run `01_after_20260823035239_recover_sync_rpcs.sql`.
3. Skip the two unreplayable historical chunk-loader files:
   - `20260823035707_0004_process_event.sql`
   - `20260823035750_0004_resolve_sync_conflict.sql`
4. Continue with `20260823035758_0005_2_pgcrypto_search_path_hotfix.sql`, `20260823035804_staging_cleanup_migration_buffer.sql`, and `20260823071035_beta_territory_ptc_foundation.sql`.
5. Instead of executing `20260823204422_staging_marketplace_pilot_v1.sql`, run `02_replace_20260823204422_marketplace_schema_only.sql`. Its STAGING-only seed depends on an external identity and is intentionally excluded.
6. Continue normally.
7. Immediately before `20260827182206_linguistic_employment_compensation_chain_v1.sql`, run `03_before_20260827182206_feature_gate_roots.sql`.
8. Immediately before `20260827191235_linguistic_assessment_chuj_smi_pilot_v1.sql`, run `04_before_20260827191235_chuj_iso.sql`.
9. Continue through migration 104: `20260920220837_tc_render_package_label_privacy_fix_v1.sql`.
10. Run `05_post_replay_acl_snapshot.sql`.
11. Run `VERIFY.sql`.

## Verified clean result

Exact application-schema match against STAGING:

- tables 178
- columns 1954
- constraints 1165
- indexes 594
- views 4
- public functions 180
- policies 59 total / 58 public
- user triggers 96 total / 87 public
- enums 7
- sequences 31
- function bodies/search_path/SECURITY DEFINER 180/180
- effective relation ACLs exact
- effective function ACLs exact
- Storage policy and non-public Auth/Storage/Realtime triggers exact

A Supabase preview branch included `pg_net` automatically. It was classified as an expected platform difference, not application drift.

The marketplace pilot rows are test data and are intentionally outside the reproducible schema baseline.

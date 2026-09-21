# TU COMUNIDAD — STAGING PROFILE / NODE READINESS REPORT

**Date:** 2026-09-21  
**Authority:** Lucas  
**Supabase:** `tu-comunidad-staging` / `ckvwfeljoonwhzmtrmnw`  
**Backend branch:** `tc/full-build-20260918`

## Scope

This report records the controlled STAGING readiness work used to unblock FlutterFlow FF-01 and later CON/RSG/NODE tests.

No Production, merge, or deploy was performed.

## Backend correction

Migration:

`20260921171444_con_context_authorization_window_v1.sql`

Purpose:

- keep `tc_con_my_context()` consistent with runtime authorization;
- return only vehicle authorizations that are active and currently inside `valid_from / valid_until`;
- runtime trip creation and match acceptance continue to revalidate against planned departure.

GitHub commit that added the migration:

`543cfbc2363f6780fdc87960345d81f8c8b93751`

Supabase migration applied successfully as canonical STAGING version:

`20260921171444_con_context_authorization_window_v1`

## Active profile fixture set

Existing fixture person:

`PER-3C3250B60ECC4E9E`

Active profiles after readiness seed:

- CLI ×1
- CON ×2
- TIE ×8
- RSG ×1 — `RSG-STG-BULEJ`
- VEN ×1 — `VEN-STG-BULEJ`
- PTC ×1 — `PTC-STG-BULEJ`
- SOP ×1 — `SOP-STG-REVIEWER`

Total active profiles: **15**.

The separate `ADM-STAGING-ROOT` remains pending and was not activated.

## Role requirement fixture provenance

The new RSG, VEN and PTC profiles have explicit STAGING-only approved affiliation fixtures:

- `AFF-STG-RSG-BULEJ`
- `AFF-STG-VEN-BULEJ`
- `AFF-STG-PTC-BULEJ`

Each has 5 required requirements and 5 complete/verified requirements.

The older TIE/CON fixture profiles were **not** given fabricated retroactive affiliation history.

## CON vehicle authorizations

The three existing `TEST` authorizations for `CON-RACE-A` / `CON-RACE-B` were extended for the STAGING test horizon.

Runtime authorization remains enforced by:

- `tc_validate_logistics_trip()`
- `tc_respond_logistics_match()`

The UI/context correction prevents expired authorizations from continuing to appear in `tc_con_my_context()`.

## Operational NODE fixtures

Three verified, active, network-enabled STAGING nodes now exist:

1. `OPL-STG-BULEJ-TIE`
   - owner: `TIE-STG-BENDICION`
   - purpose: `STORE_PICKUP`

2. `OPL-STG-SMI-TIE`
   - owner: `TIE-DEMO-SMI-CENTRO`
   - purpose: `STORE_PICKUP`

3. `OPL-STG-BULEJ-PTC`
   - owner: `PTC-STG-BULEJ`
   - purpose: `PTC_PICKUP`
   - linked to existing Bulej PTC point

These are synthetic STAGING operational fixtures and must not be treated as real physical addresses.

## NODE capabilities and governance provenance

Enabled capabilities:

### OPL-STG-BULEJ-TIE
- RECEIVE_CARGO
- HANDOFF_CARGO
- SORT_CARGO
- STAGE_CARGO

### OPL-STG-SMI-TIE
- RECEIVE_CARGO
- HANDOFF_CARGO
- SORT_CARGO
- STAGE_CARGO

### OPL-STG-BULEJ-PTC
- RECEIVE_CARGO
- HANDOFF_CARGO
- SORT_CARGO
- STAGE_CARGO
- LAST_MILE_ORIGIN
- BOX_HOST

Totals:

- enabled operational NODE capabilities: **14**
- approved NODE capability fixture requests: **14**

Each enabled capability has a corresponding approved `NCR-STG-*` request, verified requirements, and append-only request events marked `fixture_seed=true`.

## Reviewer profile

`SOP-STG-REVIEWER` is active.

Least-privilege grants:

For Bulej and San Mateo Ixtatán Centro community scopes:

- `affiliation.review`
- `affiliation.approve`
- `logistics.node_capability.review`
- `logistics.node_capability.approve`

Global only:

- `logistics.manifest.support.read`

The initial broad GLOBAL fixture grants for review/approval were removed.

## Directed test network

Four active/open STAGING edges:

- Bulej TIE → SMI TIE
- SMI TIE → Bulej TIE
- Bulej TIE → Bulej PTC
- Bulej PTC → Bulej TIE

These edges are marked as synthetic STAGING fixtures.

## Authentication readiness

The auth account linked to `PER-3C3250B60ECC4E9E` is:

- email confirmed;
- not banned;
- password-login capable;
- linked to 15 active profiles.

Credentials were not read, copied, reset, or stored.

## Security advisor note

After the changes:

- no new advisor ERROR was observed;
- RLS-enabled/no-policy notices remain informational/default-deny surfaces;
- the 10 anonymous SECURITY DEFINER functions are existing public-facing catalog/UI/governance-read surfaces and were not mass-revoked;
- authenticated SECURITY DEFINER RPC warnings were not mass-revoked because those RPCs are the intended authorization boundary;
- Supabase still reports leaked-password protection disabled; this is a project Auth configuration warning and was not changed by this backend block.

## Next gate

Return to FlutterFlow FF-01:

1. existing Email/password login;
2. authenticated navigation to `UserProfileSettings`;
3. execute configured `tc_profile_switcher()` once;
4. verify real JSON output and initial CLI bootstrap;
5. then build the visible profile selector and bind `tc_switch_active_profile(...)`.


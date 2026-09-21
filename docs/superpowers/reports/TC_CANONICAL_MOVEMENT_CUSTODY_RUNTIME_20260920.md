# TU COMUNIDAD — CANONICAL MOVEMENT CUSTODY RUNTIME PASS

**Local date:** 2026-09-20  
**Repository:** `Luphers12/Tu-Comunidad-4`  
**Branch:** `tc/full-build-20260918`  
**STAGING:** `tu-comunidad-staging` / `ckvwfeljoonwhzmtrmnw`

## Gate

```text
FORENSIC_SOT_104:               PASS
VERIFIED_REPRODUCIBLE_BASELINE: PASS
NETWORK_FOUNDATION:             PASS
LOGISTICS_EXECUTION_FOUNDATION: PASS
ROUTING_PROMISE_SCAN_SORT:      PASS
CON_PATH_ONLY_MATCH_ENGINE:     PASS
ROUTE_MATERIALIZATION:          PASS
PREEXEC_RECANDIDATE:            PASS
CANONICAL_MOVEMENT_CUSTODY:     PASS
```

Migration count moved from **128 → 133**.

## Migrations

- `20260921043606_canonical_movement_custody_phase_foundation_v1.sql` — SHA-256 `ecd8c4113ab3ecf49c3f30996f0fe91e35c94e69d48a591bd60b6eead8b332f6`
- `20260921043608_canonical_internal_event_runtime_v1.sql` — SHA-256 `3e14dcf85ee6e5afc53aea11f0951566150f3243e1b9c68d9c12410b544391d7`
- `20260921043610_canonical_departure_custody_runtime_v1.sql` — SHA-256 `3dbbdf88ad285d46fdb2fafb84cfbb2940402bdfd1e509d78629841d2ed35c47`
- `20260921043612_canonical_arrival_reconciliation_runtime_v1.sql` — SHA-256 `b76d7e2e7c569bd88591fb952b5a70c3330c0cddf2d06b4f8ffad5553d2f43eb`
- `20260921043727_canonical_runtime_idempotent_replay_v1.sql` — SHA-256 `c2c429aa51965f26ecd151d1576b2dcdd6c2c286a3969071be43e1f95846f2e5`

## Core custody rule

The canonical NODE_TO_NODE movement now has two physical handoff phases:

```text
DEPARTURE
origin NODE owner → CON

ARRIVAL
CON → destination NODE owner
```

The new phase table coordinates handshake state only.

The actual custody transfer ledger remains:

```text
public.custody_events
```

and current projection remains:

```text
packages.current_custodian_id
```

No second custody ledger was introduced.

## New internal tables

- `logistics_movement_custody_phases`
- `logistics_movement_reconciliation_runs`

Both are fail-closed RLS surfaces.

## Event runtime

Canonical runtime operations write idempotent entries into existing:

```text
event_inbox
```

using service-only SECURITY INVOKER functions.

Legacy functions remain present and unchanged in purpose:

- `process_event(jsonb)`
- `tc_apply_custody_release(...)`
- `tc_apply_custody_receive(...)`

The canonical NODE_TO_NODE path does not overload their one-handoff legacy semantics.

## Physical execution flow

Verified flow:

```text
MOV PLANNED
→ LOAD scan
→ MOV READY
→ DEPARTURE RELEASE
→ DEPARTURE RECEIVE by CON
→ custody NODE owner → CON
→ MOV IN_TRANSIT
→ ARRIVAL scan
→ MOV ARRIVED
→ manifest reconciliation
→ ARRIVAL RELEASE by CON
→ ARRIVAL RECEIVE by destination NODE owner
→ custody CON → NODE owner
→ MOV COMPLETED
→ capacity reservation CONSUMED
→ execution plan COMPLETED
→ final single-hop LOGISTICS_DEMAND DELIVERED
```

## Reconciliation

Arrival scans are compared against the expected movement package set and latest manifest snapshot.

Evidence is appended to existing:

```text
logistics_reconciliation_events
```

with a run summary in:

```text
logistics_movement_reconciliation_runs
```

Supported observations include:

- OBSERVED_PRESENT
- EXPECTED_MISSING
- UNEXPECTED_PRESENT

A latest reconciliation status of `MISMATCH` blocks ARRIVAL custody release.

Verified negative case:

```text
expected PKG arrives
+ unrelated PKG is scanned
→ reconciliation MISMATCH
→ final handoff blocked
→ custody remains with CON
→ MOV remains ARRIVED
```

## Idempotency / offline replay

Canonical LOAD, handoff and ARRIVAL operations use `event_inbox.idempotency_key`.

A replay with the same canonical request after the MOV has already advanced returns the previously-applied result instead of creating another physical event.

Verified after full completion:

- repeated LOAD scan: no duplicate scan;
- repeated DEPARTURE release/receive: no duplicate custody;
- repeated ARRIVAL scan/release/receive: no duplicate custody or scan;
- exactly one event_inbox record per idempotency key.

## Runtime verification — all rolled back

PASS:

- LOAD → READY
- departure RELEASE
- CON RECEIVE
- custody origin NODE owner → CON
- movement IN_TRANSIT
- ARRIVAL scan
- reconciliation MATCHED
- CON arrival RELEASE
- destination NODE owner RECEIVE
- custody CON → destination NODE owner
- exactly 2 custody_events for one single-hop PKG
- movement COMPLETED
- capacity reservation CONSUMED
- execution plan COMPLETED
- logistics demand DELIVERED
- idempotent replay after state advancement
- unexpected package → reconciliation MISMATCH
- mismatch blocks final custody handoff

Post-rollback counts:

```text
demands:             0
movements:           0
phase_rows:          0
reconciliation_runs: 0
scan_events:         0
custody_events:      0
event_inbox:         0
reservations:        0
execution_plans:     0
```

## Security

New tables:

- RLS enabled;
- zero user-facing policies;
- anon/authenticated direct SELECT denied;
- service_role internal access only.

Canonical runtime functions:

- SECURITY INVOKER;
- explicit empty search_path;
- anon/authenticated EXECUTE denied;
- service_role EXECUTE only.

Security Advisor:

```text
rls_enabled_no_policy:                            153 INFO
anon_security_definer_function_executable:         10 WARN
authenticated_security_definer_function_executable: 86 WARN
auth_leaked_password_protection:                    1 WARN
```

The RLS INFO increase is exactly the two new fail-closed internal tables.

## Deferred

Still deliberately deferred:

- authenticated UI exposure of canonical custody actions through `process_event`;
- in-transit reroute after a materialized MOV fails;
- partial/missing-package recovery workflow after MISMATCH;
- multi-hop automatic continuation UI/orchestrator;
- CON-facing operational screens;
- RSG last-mile adapter;
- final delivery label/UI contract;
- Production / merge / deploy.

# TU COMUNIDAD — COMMITTED ROUTE MATERIALIZATION + PRE-EXEC RECANDIDATE PASS

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
```

Migration count moved from **122 → 128**.

## Migrations

- `20260921042334_match_single_winner_per_hop_v1.sql` — SHA-256 `e75836b541da5c76abd97c73fda2d0d9fb53efab17a24ef59730d2ce34a2cdd7`
- `20260921042337_execution_materialization_foundation_v1.sql` — SHA-256 `fb5864df5937824d5809351900d14b7747642a565447ce1537352acde11c8ac8`
- `20260921042339_manifest_segment_snapshot_v1.sql` — SHA-256 `f57ef8d02a511bc8f498170614d709096d339485ebc9c138c489b2063516612e`
- `20260921042341_committed_route_materializer_v1.sql` — SHA-256 `90b0261f277d16a65e7aeed5f87b834e55da6de9f1c17970232c8ef86e69a6de`
- `20260921042343_preexecution_recandidate_v1.sql` — SHA-256 `756ebae09e0cc8a49f934b7b19efec4d24ea0f2d2ef9c9d6a56928d3c3191851`
- `20260921042522_routing_commitment_replacement_history_v1.sql` — SHA-256 `9cbc7325eae3ecf94ab15da9865c45a6d18fde522efa7305388ddfd4ac58e5dc`

## Single winner per HOP

A partial unique index now enforces:

```text
one routing_hop_id
→ at most one logistics_match with state = ACCEPTED
```

Other OFFERED candidates are intentionally preserved as standby alternatives for recovery.

## Execution materialization

Created:

- `logistics_execution_plans`
- `logistics_hop_executions`
- `logistics_execution_manifests`
- `logistics_manifest_segments`

`tc_materialize_committed_route` requires every HOP to have:

- one ACCEPTED candidate;
- an active CONFIRMED/CONSUMED capacity reservation;
- a routing commitment;
- END_TO_END_COMMITTED promise state.

Only then does it materialize execution.

It does **not** transfer custody.

## MOV consolidation

For each HOP, materialization first searches for an existing compatible planned MOV with the same:

- TRIP
- EDGE
- origin NODE
- destination NODE
- board stop
- alight stop

and state in:

```text
PLANNED / ASSIGNED / READY
```

If found, the MOV is reused.

Therefore compatible LGDs/PKGs can share a single physical MOV without merging identities.

Verified in rollback test:

```text
LGD-1 + PKG-1
LGD-2 + PKG-2
        ↓
same real TRIP / same segment
        ↓
ONE MOV
        ├ PKG-1 / LGD-1
        └ PKG-2 / LGD-2
```

## Manifest snapshot model

`logistics_manifest_segments` is the canonical multi-segment detail layer.

A PKG may appear on multiple HOP segments of the same immutable manifest while keeping the same PKG identity.

`tc_rebuild_trip_manifest_snapshot` creates a full snapshot of **all active ACCEPTED matches with active capacity on the TRIP**.

Every new snapshot:

- gets the next manifest version;
- supersedes the immediately previous manifest;
- never rewrites the old version.

Verified:

```text
MNF v1 → demand 1
MNF v2 → demand 1 + demand 2
MNF v2 supersedes v1
```

## Pre-execution re-candidate

Created `tc_release_match_before_execution`.

This applies only before a match has been materialized into a HOP execution.

Flow:

```text
ACCEPTED candidate
→ candidate fails before execution
→ release capacity reservation
→ match INVALIDATED
→ keep routing commitment history
→ demand READY_FOR_ROUTING / PARTIALLY_ASSIGNED
→ refresh candidates locally
→ alternate OFFER can ACCEPT
→ new active commitment
```

No LOGISTICS_DEMAND cancellation is required.

## Commitment-history correction

Testing exposed a real contradiction:

the original `logistics_routing_commitments` unique constraint allowed only one commitment ever per HOP, which prevented historical RELEASE → RE-CANDIDATE.

Forward migration `routing_commitment_replacement_history_v1` corrected this without deleting history.

Now a HOP may have multiple historical commitments, while a trigger enforces **only one commitment backed by an active HELD/CONFIRMED/CONSUMED reservation at a time**.

Verified:

```text
commitment 1 → reservation RELEASED  (history preserved)
commitment 2 → reservation CONFIRMED (active)
```

## Runtime verification — all rolled back

### Consolidation

PASS:

- two different demands;
- two different PKGs;
- same compatible TRIP/EDGE/segment;
- one shared MOV;
- two `movement_packages`;
- two `logistics_movement_demands`;
- manifest v1 then v2;
- v2 supersedes v1;
- v2 contains both demand/package identities;
- custody untouched.

### Re-candidate

PASS:

- two compatible OFFERED candidates;
- first ACCEPT succeeds;
- second simultaneous ACCEPT blocked;
- first accepted reservation RELEASED before execution;
- first match INVALIDATED;
- demand returns to READY_FOR_ROUTING;
- standby candidate can ACCEPT;
- old routing commitment remains historical;
- exactly one active commitment remains;
- final promise returns END_TO_END_COMMITTED;
- demand returns ASSIGNED;
- custody untouched.

## Security

All four new execution/materialization tables are fail-closed:

- RLS enabled;
- zero user-facing policies;
- anon/authenticated direct SELECT denied;
- service_role internal access only.

New functions are SECURITY INVOKER with explicit empty search_path and service_role-only EXECUTE.

Security Advisor:

```text
rls_enabled_no_policy:                            151 INFO
anon_security_definer_function_executable:         10 WARN
authenticated_security_definer_function_executable: 86 WARN
auth_leaked_password_protection:                    1 WARN
```

## Deferred

Deliberately deferred:

- recovery after a match has already been materialized;
- in-transit reroute/recovery;
- automatic custody handoff;
- CON-facing publish/opportunity UI;
- RSG last-mile adapter;
- final-delivery label/UI contract;
- Production / merge / deploy.

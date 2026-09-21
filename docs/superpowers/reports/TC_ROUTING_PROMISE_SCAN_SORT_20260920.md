# TU COMUNIDAD — ROUTING / PROMISE / SCAN-SORT PASS

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
```

Migration count moved from **113 → 118**.

## Migrations

- `20260921025943_hop_resolver_foundation_v1.sql` — SHA-256 `b027192e316bbd947a65168cf2226c3d35a345d0bb8aa9c8f47c5a31030bf00d`
- `20260921025946_promise_engine_commitment_v1.sql` — SHA-256 `3be12e9dce359cb6b33f826309f76d4684f77d3f1bee81ce27b2ff959237d9a1`
- `20260921025948_scan_sort_runtime_foundation_v1.sql` — SHA-256 `5164dd8183d03fb9393f870201eeb0af2fef4fd3364cd6104cd0a7818f828507`
- `20260921030115_hop_resolver_snapshot_consistency_v1.sql` — SHA-256 `1d77ed1fda7d789f96776bee4fca7884ab0e69b378ebd448d70e381b0bbb147f`
- `20260921030117_routing_oscillation_guard_v1.sql` — SHA-256 `674a24c84b52e16f5313965946011e546552d2854ee1bc5155476eb6db8cea4d`

## HOP Resolver

Created:

- `logistics_routing_attempts`
- `logistics_routing_hops`

The resolver distinguishes:

- `STRUCTURAL_UNREACHABLE`
- `ADAPTER_REQUIRED`
- `NO_TRIP_NOW`
- `CURRENT_EXECUTABLE`
- `ALREADY_AT_DESTINATION`

Key invariant:

```text
NO_TRIP_NOW != DEAD_END
```

A structural path can exist even when no current TRIP can execute every hop. In that case the demand is not moved to `ROUTING_EXCEPTION`.

A true structural dead end does set:

```text
state = ROUTING_EXCEPTION
routing_exception_code = STRUCTURAL_UNREACHABLE
```

A private/non-network endpoint returns `ADAPTER_REQUIRED` and is **not** treated as a structural dead end.

The resolver checks:

- directed active EDGE structure;
- network-enabled nodes;
- per-package edge weight/volume limits;
- intermediate RECEIVE_CARGO + HANDOFF_CARGO capability;
- required edge capability codes at intermediate nodes;
- latest EDGE runtime state;
- current real TRIP stop ordering;
- trip declared capacity;
- active reservations on every covered segment;
- cold/fragile compatibility;
- demand ready/delivery windows.

## Snapshot consistency

The initial resolver implementation performed two availability reads. This was hardened in the same block.

`hop_resolver_snapshot_consistency_v1` records the selected TRIP/segment arrays from one resolver pass and then writes HOP rows from that snapshot.

`CURRENT_EXECUTABLE` remains observational. The commit phase rechecks capacity atomically.

## Promise Engine

Created:

- `logistics_routing_commitments`
- `logistics_promise_evaluations`

Promise states:

- UNREACHABLE
- ADAPTER_REQUIRED
- STRUCTURAL_ONLY
- CURRENT_EXECUTABLE
- END_TO_END_COMMITTED
- ROUTING_EXCEPTION
- ALREADY_AT_DESTINATION

`END_TO_END_COMMITTED` means every hop has confirmed/consumed segment capacity. It is explicitly **not** a delivery guarantee.

`tc_commit_routing_attempt` commits all hop reservations in one database transaction. Any capacity failure aborts the whole operation.

No inventory, custody or payment state is changed by routing commitment.

## Anti-oscillation

Created:

- `logistics_routing_transition_events`

One explicit reversal for RETURN/RECOVERY is allowed.

The repeated pattern:

```text
A → B
B → A
A → B
```

is recorded as:

```text
LOOP_DETECTED_OSCILLATION
```

and moves the demand to `ROUTING_EXCEPTION / LOOP_DETECTED`.

The helper `tc_routing_path_loop_code` also rejects repeated oscillation/revisit patterns according to routing mode.

## SCAN / SORT

Created:

- `logistics_scan_events`
- `logistics_sort_events`

Both are append-only and contain operational IDs only; no recipient/private destination data is stored.

The sort function implements the **toro en corral** rule:

```text
actual next node == resolved hop destination
        → CORRECT_ROUTE

actual next node != resolved hop destination
        → WRONG_DESTINATION
```

Other outcomes:

- HOP_MISMATCH
- PACKAGE_NOT_IN_DEMAND

SCAN/SORT does not mutate custody.

## Runtime verification — all rolled back

PASS:

- structural path with no trip → NO_TRIP_NOW
- NO_TRIP_NOW does not set ROUTING_EXCEPTION
- Promise → STRUCTURAL_ONLY
- later real authorized TRIP appears
- resolver → CURRENT_EXECUTABLE
- Promise → CURRENT_EXECUTABLE
- atomic capacity commitment
- Promise → END_TO_END_COMMITTED
- demand → ASSIGNED
- correct sort → CORRECT_ROUTE
- wrong destination → WRONG_DESTINATION
- A→B→A→B → LOOP_DETECTED
- structural unreachable → ROUTING_EXCEPTION
- private endpoint → ADAPTER_REQUIRED, not dead end
- custody untouched
- custody handshake untouched

Post-rollback:

```text
routing_attempts:      0
routing_hops:          0
commitments:           0
promise_evaluations:   0
transition_events:     0
scan_events:           0
sort_events:           0
capacity_reservations: 0
custody_events:        0
handshakes:            0
```

## Security

New tables are fail-closed:

- RLS enabled;
- zero user-facing policies;
- anon/authenticated direct reads denied;
- service_role access only.

No new SECURITY DEFINER functions were introduced.

Security Advisor after this block:

```text
rls_enabled_no_policy:                            144 INFO
anon_security_definer_function_executable:         10 WARN
authenticated_security_definer_function_executable: 86 WARN
auth_leaked_password_protection:                    1 WARN
```

The RLS INFO count rose only because these new internal tables intentionally have RLS with no user policies.

## Deferred

Still deferred:

- automatic creation of MOVs/manifests from a committed routing attempt;
- reroute orchestration after WRONG_DESTINATION;
- expiration/retry scheduler for NO_TRIP_NOW;
- user-facing CON publish/accept/reject workflows;
- RSG-specific execution adapter;
- production/merge/deploy.

No Production, FlutterFlow, merge or deploy action was performed.

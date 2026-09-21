# TU COMUNIDAD — MULTI-HOP CONTINUATION + MATERIALIZED RECOVERY PASS

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
MULTIHOP_CONTINUATION:          PASS
MATERIALIZED_RECOVERY:          PASS
RECONCILIATION_RECOVERY:        PASS
```

Migration count moved from **133 → 139**.

## Migrations

- `20260921044811_continuation_recovery_foundation_v1.sql` — SHA-256 `9d5960bf0eeb0b269278190b4a0c437169196870102dc19be80b4021f5e26f6f`
- `20260921044813_materialized_movement_release_recovery_v1.sql` — SHA-256 `661271226fde191bfc5cbfb370859321245b25a5ae5f8b2954cbe327f80ea332`
- `20260921044815_replacement_hop_materialization_v1.sql` — SHA-256 `4007ad65667def25df9f314574cab9948e0e04a96c48144167dfe2a40bea75bd`
- `20260921044816_execution_continuation_runtime_v1.sql` — SHA-256 `6896aca8f038608e6d83457749e3b6b140a521fa5f84cb146cd8586d9f0d168e`
- `20260921044818_reconciliation_recovery_resolution_v1.sql` — SHA-256 `9854009c693aa906b54c476e17990b12e7d5b2457a90792ef062fee3f2e6de52`
- `20260921045055_recovery_event_sequence_v1.sql` — SHA-256 `1dc185c97d0ae4e178c9b8ecffd8c8b2a999bb4dbe9c1b4f9a9ced6590dce91c`

## Multi-hop continuation

A completed intermediate MOV now resolves the next execution step per execution plan.

Possible continuation actions:

```text
CONTINUE_READY
WAITING_FOR_PACKAGES
RECANDIDATE_REQUIRED
RECOVERY_REQUIRED
PLAN_COMPLETE
ALREADY_IN_PROGRESS
```

The continuation engine verifies that the next effective HOP execution begins at the just-completed destination NODE.

When the package is physically at the next origin NODE owner:

```text
HOP 1 COMPLETED
→ package custody at NODE B
→ NEXT HOP identified
→ canonical custody phases prepared
→ CONTINUE_READY
```

The demand is not marked DELIVERED at an intermediate node.

## Effective hop execution history

`logistics_hop_executions` is now immutable history rather than one permanent row per HOP.

A replacement row references:

```text
supersedes_hop_execution_id
```

The effective current execution is the HOP execution that has not been superseded.

Execution-plan completion now considers only effective current HOP executions, so a historical cancelled MOV cannot prevent a replacement plan from completing.

## Materialized candidate failure

A materialized MOV can be released only before physical departure:

Allowed states:

```text
PLANNED
ASSIGNED
READY
```

and only when no custody phase has progressed beyond PLANNED and no custody event exists.

Because one MOV may consolidate multiple demands, recovery is movement-level:

```text
real TRIP / segment fails
→ MOV CANCELLED
→ all active reservations on that MOV RELEASED
→ accepted matches INVALIDATED
→ recovery evidence appended
→ local candidates refreshed
```

No history is deleted.

## Replacement materialization

After an alternate candidate ACCEPTS:

```text
old HOP execution
  └ MOV CANCELLED

new HOP execution
  ├ supersedes old HOP execution
  ├ new accepted match
  ├ new reservation
  └ new/reused compatible MOV
```

A RECOVERY manifest snapshot is generated for the replacement trip.

Verified that the replacement can execute physically to completion and the plan/demand complete while the cancelled historical MOV remains preserved.

## Reconciliation recovery

Created:

- `logistics_recovery_cases`
- `logistics_recovery_events`
- `logistics_reconciliation_resolutions`
- `logistics_continuation_events`

Recovery cases are stable identities. Their lifecycle is append-only in `logistics_recovery_events`.

Unexpected ARRIVAL scans do not silently add a PKG to a MOV.

Allowed evidence-only resolutions:

- REMOVED_FROM_FLOW
- IDENTIFIED_OTHER_FLOW
- AUTHORIZED_FALSE_POSITIVE

After an unexpected observation is explicitly resolved, a new reconciliation run may become MATCHED.

Only after MATCHED can the final custody handoff continue.

## Recovery event ordering

Testing exposed that multiple recovery events inside one database transaction share the same `now()` timestamp, so timestamp ordering alone was not deterministic.

Forward correction:

```text
recovery_case
→ event_seq 1
→ event_seq 2
→ event_seq 3
...
```

`event_seq` is assigned atomically per recovery case and is the canonical ordering for recovery state.

Verified lifecycle:

```text
1 OPENED
2 OBSERVATION_RESOLVED
3 CLOSED
```

## Runtime verification — all rolled back

### Two-hop continuation

PASS:

```text
A → B → C
```

with two distinct CON candidates.

Verified:

- route resolved to 2 HOPs;
- HOP 1 completed physically;
- package custody became NODE B owner;
- demand remained IN_TRANSIT;
- execution plan remained ACTIVE;
- continuation returned CONTINUE_READY;
- next MOV identified correctly;
- HOP 2 custody phases prepared;
- HOP 2 executed with different CON;
- demand became DELIVERED only after HOP 2;
- final custodian became NODE C owner.

### Materialized replacement

PASS:

- primary accepted candidate materialized;
- primary MOV failed before departure;
- primary MOV CANCELLED;
- reservation RELEASED;
- match INVALIDATED;
- backup candidate ACCEPTED;
- replacement HOP execution superseded old history;
- replacement MOV executed;
- execution plan COMPLETED;
- demand DELIVERED.

### Reconciliation resolution

PASS:

- expected PKG + unexpected PKG scan;
- first reconciliation MISMATCH;
- recovery case created;
- unexpected observation resolved as IDENTIFIED_OTHER_FLOW;
- second reconciliation MATCHED;
- recovery event sequence 1→2→3;
- latest recovery event CLOSED;
- final custody handoff allowed;
- movement COMPLETED.

Post-rollback:

```text
demands:                    0
movements:                  0
execution_plans:            0
hop_executions:             0
continuation_events:        0
recovery_cases:             0
recovery_events:            0
reconciliation_resolutions: 0
custody_events:             0
scan_events:                0
```

## Security

Four new internal tables are fail-closed:

- RLS enabled;
- zero user-facing policies;
- anon/authenticated direct SELECT denied;
- service_role internal access only.

New functions are SECURITY INVOKER with explicit empty search_path and service_role-only EXECUTE.

Security Advisor:

```text
rls_enabled_no_policy:                            157 INFO
anon_security_definer_function_executable:         10 WARN
authenticated_security_definer_function_executable: 86 WARN
auth_leaked_password_protection:                    1 WARN
```

No Production, FlutterFlow, merge or deploy action was performed.

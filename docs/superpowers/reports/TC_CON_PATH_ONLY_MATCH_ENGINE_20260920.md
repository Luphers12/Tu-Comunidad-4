# TU COMUNIDAD — CON PATH-ONLY + MATCH ENGINE PASS

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
```

Migration count moved from **118 → 122**.

## Migrations

- `20260921041202_con_trip_declared_path_only_v1.sql` — SHA-256 `a36bda1f7cf71f17f1f050b8bb5b3a2b00a1869476a9fc29c26daf2c0a761a62`
- `20260921041207_logistics_match_engine_v1.sql` — SHA-256 `4cebf49ade5a6a062927654c53a042d6b9a1cb0f7ef1aeb226e2f48b8d634e5f`
- `20260921041209_con_acceptance_required_commit_fix_v1.sql` — SHA-256 `c787301a4af5c453db77fad1c3dcd1f262653c7032dd5ce7d1f30c9d8e0ca290`
- `20260921041238_con_match_accept_revalidation_v1.sql` — SHA-256 `ac33e6eba50dbdc37ea6b968e68b73fa9638128ccdfe62436943fe9e71c6291c`

## Canonical correction — CON has no detour radius

Removed by forward migration:

- `logistics_trips.max_detour_km`
- `logistics_trip_stops.detour_limit_km`

CON matching is now based exclusively on ordered declared stops that the real TRIP actually passes.

RSG last-mile behavior remains separate and is not modeled by this correction.

## Match Engine

Created:

- `logistics_match_requirement_snapshots`
- `logistics_matches`
- `logistics_match_events`

Requirement snapshots are PII-free and derive only logistics-relevant fields from LGD + PKG:

- PKG public id
- weight / volume
- cold-chain requirement
- fragile requirement
- dimensions / form
- aggregate package count
- time windows
- required capability codes

Recipient name, address and phone are not stored in the Match Engine.

For each routing HOP, `tc_refresh_logistics_matches` discovers **all currently compatible real TRIPs** whose declared stop timeline contains:

```text
origin point
... zero or more declared intermediate points ...
destination point
```

in that order.

No distance-radius or detour matching exists.

All human CON trip candidates use:

```text
commitment_mode = ACCEPTANCE_REQUIRED
state = OFFERED
```

Reject/expire/invalidate before commitment is not a custody or performance violation.

## CON acceptance contract

The previous `tc_commit_routing_attempt` behavior could auto-reserve a selected TRIP. That contradicted the canonical human-CON rule and was corrected.

Now:

```text
AUTO MATCH
→ OFFERED
→ CON ACCEPT / REJECT
```

### REJECT

- creates no capacity reservation;
- creates no routing commitment;
- records a REJECTED event;
- does not count as non-performance.

### ACCEPT

`tc_respond_logistics_match` atomically revalidates:

- active CON profile;
- active vehicle;
- valid driver↔vehicle authorization for planned departure;
- TRIP still PUBLISHED/ACCEPTING;
- exact declared boarding/alighting points unchanged;
- EDGE still OPEN;
- cold/fragile requirements;
- ready/delivery time windows;
- package-vs-EDGE weight/volume constraints;
- package count;
- segment capacity under lock.

Only after those checks:

```text
ACCEPT
→ CONFIRMED capacity reservation
→ routing commitment
→ match ACCEPTED
```

`tc_commit_routing_attempt` now finalizes only when every HOP already has an accepted human candidate and a valid confirmed/consumed capacity commitment. It never auto-assigns a CON.

## Runtime verification — transaction rolled back

PASS:

- two distinct real TRIPs through the declared origin/destination → two automatic opportunities;
- TRIP that never declared the destination point → zero match;
- no detour fields remain;
- commit before acceptance rejected with `TC_ROUTING_HOP_ACCEPTANCE_REQUIRED`;
- voluntary reject created no reservation;
- accept created atomic confirmed reservation + routing commitment;
- finalization produced `END_TO_END_COMMITTED`;
- demand moved to `ASSIGNED`;
- custody remained untouched.

Post-rollback:

```text
match_requirement_snapshots: 0
matches:                     0
match_events:                0
capacity_reservations:       0
custody_events:              0
```

## Security

The 3 Match Engine tables are fail-closed:

- RLS enabled;
- zero user-facing policies;
- anon/authenticated direct reads denied;
- service_role internal access only.

The Match Engine functions are SECURITY INVOKER with explicit empty search_path and service_role-only EXECUTE.

Security Advisor after the block:

```text
rls_enabled_no_policy:                            147 INFO
anon_security_definer_function_executable:         10 WARN
authenticated_security_definer_function_executable: 86 WARN
auth_leaked_password_protection:                    1 WARN
```

No Production, FlutterFlow, merge or deploy action was performed.

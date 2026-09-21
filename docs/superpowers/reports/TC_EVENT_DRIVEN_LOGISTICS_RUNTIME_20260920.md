# TU COMUNIDAD — EVENT-DRIVEN LOGISTICS RUNTIME PASS

Local date: 2026-09-20
Repository: Luphers12/Tu-Comunidad-4
Branch: tc/full-build-20260918
STAGING: tu-comunidad-staging / ckvwfeljoonwhzmtrmnw

## Gate

FORENSIC_SOT_104: PASS
VERIFIED_REPRODUCIBLE_BASELINE: PASS
NETWORK_FOUNDATION: PASS
LOGISTICS_EXECUTION_FOUNDATION: PASS
ROUTING_PROMISE_SCAN_SORT: PASS
CON_PATH_ONLY_MATCH_ENGINE: PASS
ROUTE_MATERIALIZATION: PASS
PREEXEC_RECANDIDATE: PASS
CANONICAL_MOVEMENT_CUSTODY: PASS
MULTIHOP_CONTINUATION: PASS
MATERIALIZED_RECOVERY: PASS
RECONCILIATION_RECOVERY: PASS
EVENT_DRIVEN_RUNTIME: PASS

Migration count moved from 139 to 145.

## Migrations

- 20260921050120_logistics_runtime_outbox_foundation_v1.sql — SHA-256 1a50d0c895fd5d7172a99064d5454635adcfe9a2d04aa927b1ff4f0e7ff78b50
- 20260921050123_logistics_runtime_emitters_v1.sql — SHA-256 ebef492762beeab1ddce48a492007d4a10ed62937f15aa7f6731a46fef8fa865
- 20260921050208_logistics_runtime_handlers_v1.sql — SHA-256 541d62b13c0fd1f008d26154a27401909cb16d78900f75e0f7052d09110970aa
- 20260921050210_logistics_runtime_worker_v1.sql — SHA-256 bd5569d075b05353316be9effd542b2ece8ef939f5373b45b85b95653e9a09b4
- 20260921050528_routing_attempt_sequence_v1.sql — SHA-256 2dd6fec3d4c21893782832b748e4d9db78a2d89c1c9b12144ea60705fa82a289
- 20260921050657_logistics_runtime_cron_activation_v1.sql — SHA-256 3e32a8b54fc49bac4a0814e90352a2c1f8f67f6e361235b6b05c1ded8506c7eb

## Architecture

business transaction -> transactional OUTBOX -> COMMIT -> pg_cron worker -> idempotent handler -> existing logistics functions

Business triggers only enqueue. They do not perform routing, matching, materialization, continuation or recovery inline.

## Runtime outbox

Created:
- logistics_runtime_outbox
- logistics_runtime_attempts

Event types:
- DEMAND_ROUTABLE
- TRIP_AVAILABLE
- MATCH_ACCEPTED
- MOVEMENT_COMPLETED
- ARRIVAL_MISMATCH

Worker claims rows using FOR UPDATE SKIP LOCKED. Outcomes are SUCCEEDED, RETRY or DEAD. Retry backoff is bounded and each processing attempt is preserved in logistics_runtime_attempts.

## Event reactions

DEMAND_ROUTABLE: resolve route -> refresh candidates -> evaluate Promise.
TRIP_AVAILABLE: inspect pending routing attempts -> exact declared-stop compatibility -> re-resolve NO_TRIP_NOW when needed -> refresh candidates.
MATCH_ACCEPTED: human acceptance remains explicit; when every HOP is accepted/committed, finalize and materialize plan/MOV. Replacement acceptance invokes replacement materialization.
MOVEMENT_COMPLETED: evaluate plan completion and find the next effective HOP.
ARRIVAL_MISMATCH: ensure a stable recovery case without changing custody or silently adding an unexpected PKG.

## Routing-attempt ordering correction

Testing exposed that routing attempts created in one transaction share the same now() timestamp. Timestamp plus UUID ordering could return the wrong latest attempt.

Forward correction: logistics_routing_attempts.attempt_seq is GENERATED ALWAYS AS IDENTITY. Canonical latest ordering is ORDER BY attempt_seq DESC.
Promise Engine and Runtime Orchestrator were updated to use attempt_seq.

Verified in one transaction:
attempt_seq N -> NO_TRIP_NOW
attempt_seq N+1 -> CURRENT_EXECUTABLE

## Automatic worker

Supabase Cron / pg_cron enabled in STAGING.
Job: tc-logistics-runtime-worker
Schedule: 30 seconds
Active: true
Command: select public.tc_process_logistics_runtime_batch(25);
Successful cron runs observed: 4
Failed cron runs observed: 0

## Runtime verification

PASS:
- LGD insert automatically enqueued DEMAND_ROUTABLE
- worker created NO_TRIP_NOW when no TRIP existed
- TRIP publication automatically enqueued TRIP_AVAILABLE
- worker created a fresh CURRENT_EXECUTABLE attempt
- automatic candidate discovery
- CON ACCEPT automatically enqueued MATCH_ACCEPTED
- worker committed and materialized plan/MOV
- MOV COMPLETED automatically enqueued continuation
- worker produced PLAN_COMPLETE
- ARRIVAL_MISMATCH automatically enqueued recovery
- worker ensured recovery case
- runtime outbox drained
- attempt ordering deterministic through attempt_seq

All test business rows were rolled back. Cron itself is intentionally persistent and active.

## Security

Runtime tables are fail-closed: RLS enabled, zero anon/auth policies, direct anon/auth reads denied, service_role internal access only.

Trigger emitters and enqueue helper are SECURITY DEFINER only to write the private outbox from business triggers. They have explicit empty search_path and EXECUTE revoked from PUBLIC, anon, authenticated and service_role.

Worker and handler functions are SECURITY INVOKER and service_role-executable.

Security Advisor user-executable SECURITY DEFINER warning counts did not increase because of the private emitters.

## Deferred

- CON operational UI
- authenticated API wrapper around service-only runtime operations
- RSG last-mile adapter
- final-delivery label/UI contract
- human opportunity/recovery notifications
- Production / merge / deploy
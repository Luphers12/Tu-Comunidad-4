# TU COMUNIDAD — AUTHENTICATED CON OPERATION API PASS

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
CON_AUTHENTICATED_OPERATION_API: PASS
CLIENT_DDL_PRIVILEGE_HARDENING: PASS

Migration count moved from 145 to 151.

## Migrations

- 20260921051630_con_authenticated_context_v1.sql — SHA-256 f2aa6092e55e4228c9d53e65c008a1c4a6e8236746554b95b9755ee77ef5a836
- 20260921051632_con_authenticated_trip_api_v1.sql — SHA-256 ed3feb180ef5eaa75be0d2fc7b5e2f9b7c1288a5de6baf731f24c4877e626575
- 20260921051715_con_authenticated_opportunity_api_v1.sql — SHA-256 6a0c9b1966b7d05f69d6bc20bb66c31ad11121d69308d6ad32c6d65e0063b19d
- 20260921051717_con_authenticated_execution_api_v1.sql — SHA-256 56e92111a5cdd48f53c739b502d2e5601f40b26a60fb71abecd107ea92c4754a
- 20260921051924_con_authenticated_trip_publish_v1.sql — SHA-256 910a372e4b4ae491979de787b8bc71acbf8d5ce94699980b8090b7807ee9ea42
- 20260921052219_revoke_client_ddl_table_privileges_v2.sql — SHA-256 b8451512fe8444a9414fd5a7ac14373c1cc85569428935ed1220aa71b661bb07

## Authenticated CON identity

CON actions are bound to both auth.uid() and an explicit con_public_id.

One authenticated person may own more than one CON subprofile. Runtime never guesses which one should act.

Verified STAGING fixture:
- same auth user owns CON-RACE-A and CON-RACE-B
- CON-RACE-A trip is invisible to CON-RACE-B operational RPCs
- CON-RACE-B cannot accept CON-RACE-A opportunity
- CON-RACE-B cannot execute CON-RACE-A movement actions

Private helper tc_require_my_con_profile(text) is not executable by PUBLIC, anon, authenticated or service_role; it is used only inside authenticated SECURITY DEFINER RPCs.

## CON context and network discovery

tc_con_my_context() returns the caller's active CON subprofiles plus authorized vehicles/capabilities.

tc_con_network_nodes() exposes only network-operational discovery data:
- node public ID
- name
- purpose
- community / municipality / department
- optional map point / visual reference

It does not expose recipient data or node operational contacts.

## Real TRIP declaration

Authenticated CON can:
- create DRAFT or immediately PUBLISHED TRIP
- declare exact ordered stops
- declare approximate time at points
- declare authorized vehicle
- declare free weight / volume / package capacity
- declare supported cargo capabilities
- publish a saved DRAFT
- cancel before accepted load / physical departure

No detour/radius field exists in the authenticated API.

Trip cancellation with an active accepted capacity reservation is blocked by TC_CON_TRIP_HAS_ACCEPTED_LOADS rather than silently orphaning commitments.

## Opportunity privacy contract

Before ACCEPT, tc_con_list_my_opportunities exposes:
- match ID
- TRIP ID
- origin/destination operational nodes
- board/alight sequence
- approximate times
- aggregate package count / weight / volume
- cold/fragile requirements
- per-package physical dimensions/form without PKG identity

Pre-accept response explicitly contains no PKG public ID, recipient name, private address, full_name or phone.

Verified by authenticated rollback test.

## ACCEPT / REJECT

tc_con_respond_opportunity validates exact subprofile ownership then delegates to the canonical acceptance engine.

ACCEPT still performs the previously-verified atomic validation/reservation path.
Human acceptance remains mandatory; the runtime does not auto-accept for CON.

## Execution board

After ACCEPT and materialization, tc_con_my_execution_board may expose:
- MOV public ID/state
- TRIP and MATCH public IDs
- HOP sequence
- origin/destination network nodes
- expected/departed/arrived/completed times
- PKG public IDs
- PKG state / physical weight / volume
- departure/arrival custody phase status
- latest reconciliation status

It still excludes recipient name, private delivery address, full_name and phone.

## Authenticated physical CON actions

Authenticated wrappers verified:
- tc_con_receive_departure
- tc_con_scan_arrival
- tc_con_release_arrival

These wrappers resolve public IDs, enforce subprofile ownership, then call the canonical custody/scan runtime.

End-to-end rollback test verified:
TRIP publish -> automatic opportunity -> ACCEPT -> runtime materialization -> execution board -> node RELEASE -> CON RECEIVE -> arrival scan -> reconciliation -> CON RELEASE -> destination node RECEIVE -> MOV COMPLETED -> LGD DELIVERED.

Exactly two custody transfers were produced for the single HOP.

## DRAFT / PUBLISH / CANCEL

Verified:
- CON-A creates DRAFT
- CON-B cannot publish it
- CON-A publishes it
- CON-A cancels it before accepting load

## Critical privilege hardening discovered during this block

Audit discovered 50 legacy public tables with client grants TRUNCATE, TRIGGER and REFERENCES for anon/authenticated.

TRUNCATE is not constrained by RLS and therefore represented a destructive bypass risk.

Forward migration revoke_client_ddl_table_privileges_v2:
- revoked TRUNCATE / TRIGGER / REFERENCES from anon and authenticated on every current public table
- preserved SELECT / INSERT / UPDATE / DELETE grants and existing RLS policies
- hardened postgres public default table privileges for future TC migrations

Post verification:
- dangerous current client grants: 0
- anon movements TRUNCATE: false
- authenticated movements TRUNCATE: false
- anon packages TRUNCATE: false
- authenticated packages TRUNCATE: false
- authenticated legacy SELECT remains available where RLS intentionally permits it
- CON RPCs still function after revoke

## Managed-platform default ACL note

supabase_admin still owns a managed public-schema default ACL that includes broad table privileges for anon/authenticated.

The postgres migration role is not a MEMBER/USAGE member of supabase_admin, so this project session cannot legally alter that role's default privileges.

No current public table retains TRUNCATE/TRIGGER/REFERENCES for anon/authenticated after the forward fix.

TC migrations run under postgres and explicitly harden sensitive new tables/functions. The supabase_admin default remains documented as a platform-managed risk to review in Dashboard/Support rather than impersonating that role.

## Security

All CON RPCs:
- SECURITY DEFINER only where fail-closed internal tables must be accessed
- explicit empty search_path
- PUBLIC execute denied
- anon execute denied
- authenticated execute granted only to intended user-facing RPCs
- service_role execute denied on user-facing wrappers
- private subprofile resolver is not directly executable by authenticated users

Security Advisor after block:
- rls_enabled_no_policy: 159 INFO
- anon_security_definer_function_executable: 10 WARN
- authenticated_security_definer_function_executable: 98 WARN
- auth_leaked_password_protection: 1 WARN

The authenticated SECURITY DEFINER increase is intentional for these narrow, auth.uid()-bound RPCs because underlying logistics tables remain fail-closed.

## Runtime health

tc-logistics-runtime-worker remains active every 30 seconds.
Observed before save: 32 successful runs, 0 failed runs.
Runtime outbox nonterminal rows: 0.

## Test cleanup

All functional test business data was executed inside transactions and rolled back.

LIVE after tests:
- logistics_trips: 0
- logistics_trip_stops: 0
- logistics_matches: 0
- movements: 0
- custody_events: 0
- runtime_outbox: 0
- network_enabled operational_locations: 0

## Deferred

- actual FlutterFlow CON screens
- node/TIE/PTC authenticated scan/release/receive UI wrappers
- CON opportunity notifications
- RSG last-mile adapter and private-delivery data boundary
- final physical label contract
- Production / merge / deploy
# TU COMUNIDAD — AUTHENTICATED NODE OPERATIONS PASS

Local date: 2026-09-21
Repository: Luphers12/Tu-Comunidad-4
Branch: tc/full-build-20260918
STAGING: tu-comunidad-staging / ckvwfeljoonwhzmtrmnw

## Gate

AUTHENTICATED_NODE_OPERATIONS: PASS
NODE_ACTIVE_PROFILE_ISOLATION: PASS
NODE_SORT_GATE: PASS
NODE_ARRIVAL_RECOVERY: PASS

Migration count moved from 185 to 189.

## Migrations

- 20260921124951_node_authenticated_operation_read_v1.sql — SHA-256 2af1993f2210148e19eddf32445e09e1c08e16fb78fcc68c59545dff404c0e4c
- 20260921125207_node_authenticated_physical_operation_v1.sql — SHA-256 86f891682214d3008f3bf7b2ff74904899162d98e115e4661be1ea04a53ebf97
- 20260921125425_node_sort_append_only_fix_v1.sql — SHA-256 43c84faea219ec4920e4d7bb70ae3973117c1ec787061c2c6673c1a064ef35d6
- 20260921125630_node_authenticated_recovery_v1.sql — SHA-256 d373f7037629e43d70ee2f436a9d22bffc89c1fc4c369d1a8c0402bb024d6064

## Active-node ownership

Private helper tc_require_my_operational_node enforces:
- authenticated session has one active profile
- active profile type is TIE or PTC
- requested NODE is active/network-enabled
- NODE owner_profile_id equals active profile
- optional required NODE capability is ENABLED

Owning another TIE/PTC under the same account is not sufficient.

## Operational read RPCs

Authenticated-only:
- tc_node_my_context()
- tc_node_my_inbound(node, limit)
- tc_node_my_outbound(node, limit)
- tc_node_sort_board(node, limit)
- tc_node_my_recovery_cases(node, limit)

Context exposes exact owned NODEs, enabled logistics capabilities and open workload counts.

Inbound exposes:
- MOV/TRP/CON public IDs
- origin/destination operational NODEs
- latest manifest ID
- package physical facts
- arrival scan state
- arrival custody phase
- latest reconciliation counts

Outbound exposes:
- MOV/TRP/CON public IDs
- next operational NODE
- package physical facts
- LOAD scan state
- departure custody phase

No read RPC references private_destination_snapshots.

## Physical RPCs

Authenticated active exact NODE owner:
- tc_node_scan_arrival
- tc_node_reconcile_arrival
- tc_node_receive_custody
- tc_node_scan_load
- tc_node_sort_package
- tc_node_release_to_con
- tc_node_resolve_unexpected_arrival

Custody remains in custody_events; scans and sort never transfer custody.

## Toro en corral sort gate

At a NODE with SORT_CARGO:
1. operator scans/selects the actual next NODE
2. system compares it with the effective routing HOP
3. wrong NODE is recorded as WRONG_DESTINATION / TORO_EN_CORRAL_DESTINATION_MISMATCH
4. custody release to CON remains blocked until a CORRECT_ROUTE sort exists

Verified:
- wrong B -> A sort recorded
- release blocked with TC_NODE_SORT_REQUIRED
- correct B -> C sort recorded
- sort did not alter custody
- release did not alter custody
- only CON RECEIVE transferred custody B -> CON

## Append-only correction

Initial sort wrapper attempted to enrich logistics_scan_events after INSERT.
The existing append-only guard correctly rejected the UPDATE.

Forward correction tc_record_node_sort_scan_once now creates each SORT scan atomically with:
- idempotency_key
- movement_id
- manifest_id
- routing attempt/hop
- actor
- metadata

No post-insert mutation is performed.

## Arrival recovery

An unexpected physical PKG is not rejected before evidence is captured.

Flow verified:
- unexpected package scan -> EXCEPTION / expected=false
- expected package scan continues normally
- reconciliation -> MISMATCH
- recovery case visible through tc_node_my_recovery_cases
- node resolves unexpected scan as IDENTIFIED_OTHER_FLOW
- re-reconciliation -> MATCHED
- recovery case -> CLOSED
- only the expected PKG transfers custody
- unexpected PKG custody remains unchanged

Supported unexpected-scan resolution types remain canonical:
- REMOVED_FROM_FLOW
- IDENTIFIED_OTHER_FLOW
- AUTHORIZED_FALSE_POSITIVE

## Full intermediate-node test

Canonical rollback scenario:
A -> B -> C

PASS:
- CLI could not operate NODE
- TIE A could not operate NODE B
- active exact TIE B saw NODE context/inbound
- B arrival scan
- B reconciliation MATCHED
- CON arrival release
- B custody receive
- B outbound view
- B sort board expected C
- B load scan
- wrong sort evidence
- release blocked by sort gate
- correct sort
- B release to CON
- CON receive for B -> C

## Security

Operational/recovery tables remain RLS-enabled fail-closed:
- logistics_scan_events
- logistics_sort_events
- logistics_movement_custody_phases
- logistics_movement_reconciliation_runs
- logistics_recovery_cases
- logistics_recovery_events
- logistics_reconciliation_resolutions

anon/authenticated direct SELECT denied.
User-facing NODE RPCs are authenticated-only SECURITY DEFINER with empty search_path.
Private helpers/writers are not directly executable by authenticated users.

All test orders, demands, scans, sort events and recovery cases rolled back.

## Deferred

- formal NODE capability request/review/approval workflow
- real PTC profile fixtures
- employee/delegated NODE operator access
- FlutterFlow NODE UI
- Production / merge / deploy
# TU COMUNIDAD — CON AUTHENTICATED API RECONCILIATION PASS

Local date: 2026-09-20
Repository: Luphers12/Tu-Comunidad-4
Branch: tc/full-build-20260918
STAGING: tu-comunidad-staging / ckvwfeljoonwhzmtrmnw

## Result

CON_AUTHENTICATED_API_RECONCILIATION: PASS

Migration count moved from 151 to 154.

## Why reconciliation was required

While this block was being built, the branch advanced with commit 034b26d12f8bd650ff7fa445970b95f2a95046c0.
That commit contained six authenticated CON migrations which were already present LIVE in STAGING and therefore represented valid concurrent work, not accidental Git drift.

The later migrations con_authenticated_control_plane_v1 and con_authenticated_execution_plane_v1 introduced an overlapping API surface.
They were preserved in forensic migration history but reconciled forward instead of becoming a second canonical CON API.

## Canonical CON API retained

- tc_con_my_context
- tc_con_network_nodes
- tc_con_create_trip
- tc_con_publish_trip
- tc_con_cancel_trip
- tc_con_list_my_trips
- tc_con_list_my_opportunities
- tc_con_respond_opportunity
- tc_con_my_execution_board
- tc_con_receive_departure
- tc_con_scan_arrival
- tc_con_release_arrival

Private resolver:
- tc_require_my_con_profile

New narrow capability added by reconciliation:
- tc_con_reconcile_arrival

## Duplicate API removed forward

- tc_con_save_trip
- tc_con_set_trip_state
- tc_con_workspace
- tc_con_execute_movement_action
- tc_con_resolve_owned_profile

tc_con_respond_opportunity was restored to the canonical implementation from con_authenticated_opportunity_api_v1.

## Privacy contract

Before ACCEPT:
- no PKG public IDs
- no recipient name
- no private address
- no phone

After ACCEPT/materialization:
- execution board may expose PKG public IDs and physical package facts
- still no recipient name
- still no private address
- still no phone

## Authenticated runtime test

Rollback test using the real STAGING auth fixture verified:
- CON context
- network-node discovery
- TRIP creation
- opportunity feed
- pre-accept privacy
- explicit ACCEPT
- CON subprofile isolation
- runtime materialization
- execution board with PKG ID after ACCEPT
- departure RECEIVE by CON
- ARRIVAL scan by CON
- authenticated arrival reconciliation
- ARRIVAL release by CON
- final destination-node RECEIVE
- MOV COMPLETED
- final custody at destination NODE

All business test data rolled back.

## Security

Canonical user-facing CON RPCs:
- SECURITY DEFINER only to cross fail-closed RLS boundaries
- explicit empty search_path
- anon EXECUTE denied
- authenticated EXECUTE granted
- service_role EXECUTE denied

Private tc_require_my_con_profile is not directly executable by authenticated/service_role.

Authenticated SECURITY DEFINER advisor count after reconciliation: 99 WARN.
This is lower than the temporary overlapping surface count of 102.

Runtime worker remains active and healthy; outbox nonterminal rows: 0.

## Source-of-truth rule

The concurrent commit 034b26... remains intact.
The three later LIVE migrations are saved as forward history on top of it.
No historical migration was rewritten or removed.

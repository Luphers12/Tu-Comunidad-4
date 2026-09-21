# TU COMUNIDAD — FLUTTERFLOW WORK / GROK HANDOFF

Date: 2026-09-21
Authority: Lucas
Repository: Luphers12/Tu-Comunidad-4
Backend branch: tc/full-build-20260918
Backend handoff commit before this document: bf0c4d742659b2a3d13142c4b9922111cb735082
Supabase STAGING: tu-comunidad-staging / ckvwfeljoonwhzmtrmnw
Supabase migration count: 191
FlutterFlow project: Tu Comunidad
FlutterFlow project id: vkA5Csj2d0821I0SB15t
FlutterFlow working branch to inspect: fix-issues-sep06

## Purpose

Implement the FlutterFlow UI against the already-built authenticated backend. Do not redesign backend authorization in the client and do not create a second source of truth for active profile, logistics state, custody, manifest, capability activation or private destination.

## Hard rules

1. Do not write Production, merge branches, deploy, or change main/default branches without explicit Lucas authorization.
2. Diagnose the real FlutterFlow project before generating/replacing pages.
3. Preserve existing functions and UI that are already useful; changes are cumulative.
4. Do not add a second manual Supabase client into exported generated Flutter code if FlutterFlow can bind the existing Supabase project/RPCs in the editor.
5. Database active-profile context is the authorization source of truth. Client AppState may cache display data but must never decide authorization.
6. Role ownership != active role. Only the explicitly active profile may perform role-sensitive actions.
7. Do not query fail-closed logistics tables directly from UI. Use authenticated RPC surfaces.
8. Do not expose recipient PII in CON manifests, NODE manifests, pre-accept RSG opportunities or other operational views where backend intentionally omits it.
9. Do not infer custody from GPS, route progress or UI state. Custody changes only through handoff RPCs.
10. If FlutterFlow lacks a clean way to invoke an RPC, report the blocker before adding custom code.

## Known FlutterFlow/export diagnosis

The current exported Flutter code inspected from the flutterflow branch is largely UI-only.
No generated backend/, Supabase custom client, custom_code/, or useful app_state authorization layer was found in the export inspected.
UserProfileSettings is still largely static/mock and includes role links rather than a real active-profile selector.
Therefore the work should happen in FlutterFlow itself, not by hand-editing exported generated code.

## PHASE FF-01 — Active profile selector

Primary backend:
- tc_profile_switcher()
- tc_switch_active_profile(profile_public_id)

On authenticated shell/profile load:
- call tc_profile_switcher()
- render active_profile_public_id and active_profile_type
- render switchable_profiles
- render active_commitment_count badge
- render role_activation_options for TIE, VEN, CON, RSG, PTC
- show incomplete roles as non-switchable with activation status/remaining requirements

Required interaction:
active CLI -> user chooses RSG -> call tc_switch_active_profile(RSG-XXXX) -> refresh role-dependent data -> open RSG shell.

Switching away from RSG may return paused_availability_count/background_commitment_count. Surface those facts; do not cancel commitments.

Acceptance:
- CLI cannot operate CON/RSG screens merely because those profiles exist.
- switching profile visibly changes shell and backend RPC authorization.
- profile with status not active is not switchable.
- existing commitment badges remain visible.

## PHASE FF-02 — Role shells

Do not assume existing page names equal canonical roles. Inspect them first and map intentionally.

Required logical shells:
- CLI: buyer/customer home
- CON: real trips, opportunities, execution, manifest
- RSG: availability, opportunities, assignments, execution/delivery
- TIE/VEN: orders/inventory plus owned NODE operations where applicable
- PTC: NODE receive/sort/handoff/recovery
- SOP/ADM: only authorized review/support surfaces

Keep common navigation compact. Role shell may change content, but account/profile switching remains globally reachable.

## PHASE FF-03 — CON UI

Discover exact LIVE function signatures before binding.
Canonical authenticated surfaces include:
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
- tc_con_reconcile_arrival
- tc_con_release_arrival
- tc_con_my_manifests

CON invariants:
- no detour field
- exact declared path/stops
- human ACCEPT remains explicit
- manifest is PII-free
- PKG IDs are visible after assignment as operational identities

Manifest screen:
- latest manifest by default
- optional history
- MNF/TRP/VEH/PKG/LGD IDs
- stops
- package segment list
- no recipient name, phone, private address or payment information

## PHASE FF-04 — RSG UI

Canonical surfaces include:
- tc_rsg_my_context
- tc_rsg_set_availability
- tc_rsg_list_my_opportunities
- tc_rsg_respond_opportunity
- tc_rsg_my_assignments
- tc_rsg_my_execution_board
- tc_rsg_receive_pickup
- tc_rsg_record_arrival_candidate
- tc_rsg_register_delivery_evidence
- tc_rsg_confirm_delivery
- tc_render_final_delivery_label

Privacy:
Before ACCEPT: no PKG ID, recipient name, exact private address, phone.
After ACCEPT: assigned RSG digital view may show PKG, recipient name, address, phone and delivery instructions.
Physical final-delivery label: PKG ID + QR/barcode + recipient name + address; NEVER phone.

Delivery flow:
NODE release -> RSG receive -> OUT_FOR_DELIVERY -> arrival candidate -> evidence -> confirm delivery.
GPS/arrival candidate is not DELIVERED.

## PHASE FF-05 — NODE / PTC UI

Canonical authenticated reads:
- tc_node_my_context
- tc_node_my_inbound
- tc_node_my_outbound
- tc_node_sort_board
- tc_node_my_manifest_view
- tc_node_my_recovery_cases

Canonical physical actions:
- tc_node_scan_arrival
- tc_node_reconcile_arrival
- tc_node_receive_custody
- tc_node_scan_load
- tc_node_sort_package
- tc_node_release_to_con
- tc_node_resolve_unexpected_arrival

NODE UI should have at least:
- node selector when active profile owns multiple nodes
- inbound queue
- outbound queue
- manifest/node view
- scan action
- reconciliation status
- sort board
- recovery/incidents

Sort semantics:
- wrong next NODE produces WRONG_DESTINATION / TORO_EN_CORRAL_DESTINATION_MISMATCH
- do not hide this error
- at SORT_CARGO nodes release remains blocked until CORRECT_ROUTE exists
- sort scan never changes custody

Unexpected arrival:
- record EXCEPTION instead of silently rejecting physical observation
- recovery case shows unresolved unexpected PKG
- allowed resolution types: REMOVED_FROM_FLOW, IDENTIFIED_OTHER_FLOW, AUTHORIZED_FALSE_POSITIVE
- re-reconciliation may close case

## PHASE FF-06 — NODE capability activation UI

Nobody should self-enable LAST_MILE_ORIGIN or other governed NODE capabilities.

Applicant RPCs:
- tc_start_node_capability_request
- tc_provide_node_capability_requirement
- tc_submit_node_capability_request
- tc_node_my_capability_requests

Reviewer/approver RPCs:
- tc_node_capability_review_queue
- tc_review_node_capability_requirement
- tc_finalize_node_capability_request

Requestable:
- RECEIVE_CARGO
- HANDOFF_CARGO
- SORT_CARGO
- STAGE_CARGO
- LAST_MILE_ORIGIN
- BOX_HOST

LAST_MILE_ORIGIN system prerequisites:
- NODE_OWNERSHIP
- NETWORK_ENABLED
- RECEIVE_CARGO_ENABLED
- HANDOFF_CARGO_ENABLED
- HOME_DELIVERY_COVERAGE
- plus applicant OPERATIONAL_READINESS reviewed/verified

System requirements are read-only in UI. Do not present them as applicant-editable checkboxes.

Reviewer access requires active SOP/ADM plus explicit capability:
- logistics.node_capability.review
- logistics.node_capability.approve
GLOBAL or matching COMMUNITY scope.

Current LIVE reviewer grants: 0.
Current real enabled LAST_MILE_ORIGIN nodes: 0.

## PHASE FF-07 — Affiliation / role activation UI

tc_profile_switcher() already returns role_activation_options.
Existing affiliation workflow is the activation source for TIE, VEN, CON, RSG, PTC.

Relevant RPCs should be discovered/bound from LIVE, including:
- tc_start_affiliation
- tc_provide_affiliation_requirement
- tc_submit_affiliation_application
- tc_my_affiliations

Role must remain non-switchable until approval creates/activates the operational profile.

## PHASE FF-08 — Support manifest UI

RPC:
- tc_support_manifest_view

Requires active SOP/ADM and explicit GLOBAL logistics.manifest.support.read.
Current LIVE grants: 0.
Do not create a UI that implies support already has access.

## Private destination / end-to-end statuses to render

Important logistics states include:
- READY_FOR_ROUTING
- ASSIGNED
- IN_TRANSIT
- AWAITING_LAST_MILE
- LAST_MILE_ASSIGNED
- DELIVERED

Promise includes:
- NETWORK_COMMITTED_LAST_MILE_PENDING
- END_TO_END_COMMITTED

Do not label network arrival at a last-mile egress node as customer delivery.

## Backend reports to read first

- docs/superpowers/reports/TC_ACTIVE_PROFILE_RSG_PHYSICAL_20260921.md
- docs/superpowers/reports/TC_ACTIVE_PROFILE_RLS_20260921.md
- docs/superpowers/reports/TC_PROFILE_AFFILIATION_ELIGIBILITY_20260921.md
- docs/superpowers/reports/TC_PRIVATE_DESTINATION_RSG_ADAPTER_20260921.md
- docs/superpowers/reports/TC_AUTHENTICATED_MANIFEST_RPC_20260921.md
- docs/superpowers/reports/TC_AUTHENTICATED_NODE_OPERATIONS_20260921.md
- docs/superpowers/reports/TC_NODE_CAPABILITY_GOVERNANCE_20260921.md

## Required Work/Grok execution method

Use this loop for every FlutterFlow block:
DIAGNOSE -> EVIDENCE -> PLAN -> CHANGE -> TEST -> COMPARE TO EXPECTED -> REPORT

Do not mark PASS merely because a page renders.
PASS requires the expected backend authorization behavior under real active-profile switching.

Start with FF-01 active profile selector only.
Do not build all UI pages in one generation pass if FlutterFlow AI is page-scoped.
After FF-01 PASS, continue through phases in order unless a critical invariant blocks progress.

## FF-01 expected test matrix

Same authenticated account:
1. login -> CLI selected by default
2. CLI calls customer UI normally
3. CON/RSG/TIE role actions hidden/disabled or inaccessible from CLI shell
4. switch to CON -> CON shell loads using tc_con_my_context
5. switch back to CLI -> CON action loses backend authorization
6. switch to TIE -> only exact active TIE-owned NODE/store slice visible
7. incomplete RSG/CON/etc role appears as activation workflow, not switchable profile
8. active commitment badge remains when switching away

## STOP conditions

Stop and report before continuing if:
- FlutterFlow appears to require direct reads from fail-closed logistics tables
- Supabase project/ref does not match ckvwfeljoonwhzmtrmnw
- generated action requires storing authorization truth only in AppState
- existing FlutterFlow page/backend schema contradicts LIVE RPC contracts
- a role page exposes private data outside the documented privacy boundary
- any proposed change would require Production/merge/deploy

End of handoff.
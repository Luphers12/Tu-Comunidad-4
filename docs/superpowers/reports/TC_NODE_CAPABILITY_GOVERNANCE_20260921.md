# TU COMUNIDAD — NODE CAPABILITY GOVERNANCE PASS

Local date: 2026-09-21
Repository: Luphers12/Tu-Comunidad-4
Branch: tc/full-build-20260918
STAGING: tu-comunidad-staging / ckvwfeljoonwhzmtrmnw

## Gate

NODE_CAPABILITY_GOVERNANCE: PASS

Migration count moved from 189 to 191.

## Migrations

- 20260921130229_node_capability_governance_foundation_v1.sql — SHA-256 9f8bbf8d40121c09e785b89a04cd6d927dbe8bc64883b5d26cbcb3133c649d0a
- 20260921130339_node_capability_governance_rpc_v1.sql — SHA-256 c401bad9daf0955c9dae9e1068e318313d86fc1bdb0876d61af973e241611920

## Canonical rule

Existing ownership of a TIE/PTC or NODE does not authorize that profile to self-enable logistics capabilities.

Direct authenticated writes to operational_location_capabilities remain closed.

Capability activation now uses:
NODE owner request
-> requirements
-> submit
-> SOP/ADM review
-> SOP/ADM approval
-> operational_location_capabilities ENABLED

## Governed capabilities

Requestable in this logistics-node workflow:
- RECEIVE_CARGO
- HANDOFF_CARGO
- SORT_CARGO
- STAGE_CARGO
- LAST_MILE_ORIGIN
- BOX_HOST

INVENTORY_COMMITMENT remains outside this workflow because commercial inventory commitment and logistics-node capability are separate domains.

## Request requirements

Every request:
- NODE_OWNERSHIP [SYSTEM]
- NETWORK_ENABLED [SYSTEM]
- OPERATIONAL_READINESS [APPLICANT]

LAST_MILE_ORIGIN also requires:
- RECEIVE_CARGO_ENABLED [SYSTEM]
- HANDOFF_CARGO_ENABLED [SYSTEM]
- HOME_DELIVERY_COVERAGE [SYSTEM]

System requirements are refreshed from LIVE database state and cannot be provided, waived or forged by the applicant.

## Applicant RPCs

- tc_start_node_capability_request
- tc_provide_node_capability_requirement
- tc_submit_node_capability_request
- tc_node_my_capability_requests

The active profile must be the exact TIE/PTC owner of the NODE.

## Reviewer / approver RPCs

- tc_node_capability_review_queue
- tc_review_node_capability_requirement
- tc_finalize_node_capability_request

Private reviewer guard:
- active profile must be SOP or ADM
- requires logistics.node_capability.review or logistics.node_capability.approve
- permission may be GLOBAL or scoped to the NODE COMMUNITY

Owning a capable SOP/ADM profile on the same account is not sufficient while another profile is active.

## Approval semantics

APPROVE requires every required requirement to be VERIFIED.

Before enabling the capability the system rechecks:
- NODE still active
- NODE still network_enabled
- exact requester still owns NODE
- requester profile still active TIE/PTC
- LAST_MILE_ORIGIN structural prerequisites still true

Approval then upserts operational_location_capabilities with status ENABLED.

## Rollback verification

One account temporarily owned CLI + TIE Matilde + capable SOP.

PASS:
- CLI could not request NODE capability
- TIE requested LAST_MILE_ORIGIN before prerequisites
- applicant could not forge RECEIVE_CARGO_ENABLED
- LAST_MILE_ORIGIN submission blocked while RECEIVE/HANDOFF absent
- TIE requested and submitted RECEIVE_CARGO
- TIE could not review or self-approve despite same account owning capable SOP
- explicit switch to SOP exposed review queue
- SOP verified readiness and approved RECEIVE_CARGO
- public node context showed RECEIVE_CARGO enabled
- TIE requested HANDOFF_CARGO
- SOP verified and approved HANDOFF_CARGO
- original LAST_MILE_ORIGIN request refreshed system prerequisites
- RECEIVE_CARGO_ENABLED verified
- HANDOFF_CARGO_ENABLED verified
- HOME_DELIVERY_COVERAGE verified
- LAST_MILE_ORIGIN submitted
- SOP verified readiness and approved LAST_MILE_ORIGIN
- public node context showed RECEIVE_CARGO + HANDOFF_CARGO + LAST_MILE_ORIGIN
- direct authenticated insert into operational_location_capabilities remained denied

All temporary SOP profiles, requests, requirements, events and capability grants rolled back.

## LIVE post-test state

Reviewer capability grants:
- logistics.node_capability.review: 0
- logistics.node_capability.approve: 0

Real enabled LAST_MILE_ORIGIN nodes: 0

This is intentional. No real NODE was auto-approved or auto-enabled.

## Security

node_capability_requests, node_capability_request_requirements and node_capability_request_events are fail-closed RLS tables.

operational_location_capabilities remains fail-closed to authenticated direct access.

User-facing RPCs are authenticated-only SECURITY DEFINER wrappers with empty search_path.
Private refresh/reviewer helpers are not directly executable by authenticated users.

## FlutterFlow boundary

Backend prerequisites for the next UI phase are now available.

FlutterFlow UI must consume the authenticated RPC surfaces rather than duplicate authorization in client AppState.

No FlutterFlow write, Production change, merge or deploy was performed.
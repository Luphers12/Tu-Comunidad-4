# TU COMUNIDAD — RSG LAST-MILE PRIVACY FOUNDATION PASS

Local date: 2026-09-21
Repository: Luphers12/Tu-Comunidad-4
Branch: tc/full-build-20260918
STAGING: tu-comunidad-staging / ckvwfeljoonwhzmtrmnw

## Gate

RSG_LAST_MILE_PRIVACY_FOUNDATION: PASS

Migration count moved from 154 to 159.

## Migrations

- 20260921054356_home_private_destination_contract_adapter_v1.sql — SHA-256 03573dc4dca0e02c5528bcba3d71b972f31404012b3896b1f1cb100ef19e0e17
- 20260921054429_rsg_last_mile_foundation_v1.sql — SHA-256 392492ce4dcc8ebc3811f119e4c728b67cffe3e7867ec0a49cb0953a8f9fa884
- 20260921054509_rsg_last_mile_matching_v1.sql — SHA-256 96716db3113c8b5e6dfbc8b2da30f8975d983cb547e24dab2aca8757ba31417f
- 20260921054611_rsg_authenticated_privacy_api_v1.sql — SHA-256 2357aaaf2db426ba8c22394fa209b9c9aa2e606e031f9141e7449b0413ecfcae
- 20260921054743_last_mile_task_uuid_selection_fix_v1.sql — SHA-256 215569acf6c1ac9bb8e8ddc933934c7fa49dbba38808e5452864f5771e81b2cc

## HOME destination contract adapter

Future HOME orders now require a valid active HOME customer_location owned by the CLI person.

On order INSERT:
- copies the private destination into immutable private_destination_snapshots
- snapshots recipient_name
- snapshots recipient_phone
- creates logistics_destination
- creates destination version target PRIVATE_LOCATION
- sets orders.destination_contract_id inside the same transaction

Historical HOME order with destination_id NULL was not altered or guessed.

recipient_phone remains in the fail-closed private snapshot and is documented as digital last-mile only.

## RSG last-mile model

Separate from CON/TRIP.

Created:
- logistics_rsg_availability
- logistics_last_mile_tasks
- logistics_last_mile_task_packages
- logistics_rsg_capacity_reservations
- logistics_last_mile_matches
- logistics_last_mile_match_events
- logistics_last_mile_assignments

RSG availability supports:
- RSG_MOTO
- RSG_CAR
- WALK
- community scope
- optional local radius
- time window
- weight / volume / package capacity
- cold / fragile / bulky declarations

service_coverage is reused as the territorial HOME-delivery gate.

## Matching

Last-mile candidate discovery checks:
- active RSG profile
- same HOME-delivery community
- availability state
- time overlap
- handling requirements
- remaining capacity

Candidate discovery is PII-free.

Human RSG uses ACCEPT / REJECT.

ACCEPT atomically creates a CONFIRMED RSG capacity reservation and ACTIVE assignment.
Candidate, reservation and custody remain distinct concepts.

Assignment does not transfer custody.

## Privacy boundary

Pre-ACCEPT opportunity feed exposes:
- origin node
- destination community / municipality / department
- physical requirements
- time window

Pre-ACCEPT feed does NOT expose:
- PKG public ID
- recipient name
- exact private address
- phone

After ACCEPT, assigned RSG digital view may expose:
- PKG public ID
- recipient name
- recipient phone
- exact delivery destination
- coordinates
- visual reference
- access instructions
- authorized contact
- safe-location reference

## Physical final-delivery label

New renderer: tc_render_final_delivery_label(package_public_id)

Authorized only when an active last-mile assignment exists and caller is either:
- assigned RSG, or
- origin NODE owner while still current custodian

Physical label contains:
- PKG ID
- QR value
- barcode value
- recipient name
- delivery address text
- community / municipality / department

Physical label deliberately does NOT contain recipient phone.

The older tc_render_package_label remains unchanged and PII-free for earlier logistics stages.

## Verification — all business fixtures rolled back

PASS:
- HOME order created immutable private destination contract
- recipient name/phone snapshot created
- no RSG candidate before availability
- RSG availability in Bulej refreshed pending task
- pre-accept opportunity contained no PKG ID/name/address/phone
- RSG ACCEPT created confirmed capacity reservation
- assigned RSG digital view contained PKG ID/name/address/phone
- final physical label contained PKG ID/name/address
- final physical label did not contain phone
- assignment did not create custody event

Post-rollback LIVE:
- RSG profiles: 0
- private destination snapshots: 0
- last-mile tasks: 0
- RSG availability rows: 0
- last-mile matches: 0
- RSG reservations: 0
- last-mile assignments: 0
- custody events: 0

## Security

All internal RSG/last-mile tables have RLS enabled, zero user-facing policies, and direct anon/authenticated SELECT denied.

User-facing RSG RPCs are authenticated-only SECURITY DEFINER wrappers with empty search_path and service_role direct EXECUTE denied.

Private tc_require_my_rsg_profile is not directly executable by authenticated users.

Pre-accept function source does not read packages or private_destination_snapshots.
Final-label function source does not reference recipient_phone.

## Deferred

- physical pickup custody NODE -> RSG
- OUT_FOR_DELIVERY runtime
- arrival-zone evidence
- final physical delivery evidence
- custody RSG -> CLI
- DELIVERY completion
- automatic adapter from completed network HOP to last-mile task
- local multi-task batching/run sequencing
- FlutterFlow RSG UI
- Production / merge / deploy
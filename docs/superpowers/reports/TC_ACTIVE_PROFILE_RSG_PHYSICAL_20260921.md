# TU COMUNIDAD — ACTIVE PROFILE + RSG PHYSICAL LAST-MILE PASS

Local date: 2026-09-21
Repository: Luphers12/Tu-Comunidad-4
Branch: tc/full-build-20260918
STAGING: tu-comunidad-staging / ckvwfeljoonwhzmtrmnw

## Gate

RSG_PHYSICAL_EXECUTION: PASS
ACTIVE_PROFILE_CONTEXT: PASS
ROLE_SCOPED_AUTHORIZATION: PASS
LAST_MILE_PRIVATE_EVIDENCE: PASS

Migration count moved from 159 to 167.

## Migrations

- 20260921055211_rsg_last_mile_physical_execution_v1.sql — SHA-256 530025496a94097c63a54585b87eb3aacb5217f737b5e5b34a55ba158de2e3b1
- 20260921055234_last_mile_private_evidence_v1.sql — SHA-256 72944ae332e77622eb90f760347ff04fc5aa0e3e823d27277df94d5c49deae88
- 20260921055334_rsg_last_mile_custody_delivery_runtime_v1.sql — SHA-256 bde1a5c6d948b7fdf27131c3403edfaaf4071016a9c76bb01ef4e961c8469cfe
- 20260921055410_rsg_authenticated_physical_api_v1.sql — SHA-256 3ea711bfcfd3b703961fdd41df937945951c8b425aea5abf28e32ed9e293a0b0
- 20260921055510_last_mile_assignment_materialization_order_fix_v1.sql — SHA-256 3094c00a9896eb0d132095a107c35b46f39d0e272b79867487df7cbce08f769d
- 20260921062135_active_profile_context_foundation_v1.sql — SHA-256 0bce17891fadd79b54ded75042c398c8398c149c5110bf2c0c103c03504aa380
- 20260921062218_active_profile_switcher_v1.sql — SHA-256 2db759091c046ccf0a1a20d7c0c2dcb261e2cb749fa9472f0fc0c6894ec46097
- 20260921062320_role_sensitive_active_profile_authorization_v1.sql — SHA-256 3399cc2f0b293b6d399a701710f7b2746f4fbe91280b9121701940f6ba2d51ba

## Explicit active profile model

One authenticated person may own multiple enabled subprofiles, but only one is operationally active per session context.

Model:
PER / account
-> active session profile
-> CLI / CON / RSG / TIE / PTC / other

Ownership of a subprofile is not sufficient for role-sensitive authorization.

Role-sensitive authorization now requires:
- authenticated auth.uid
- profile belongs to that person
- profile status is active
- requested profile equals active profile for current session

## Default and switching

On first profile-switcher bootstrap:
- CLI is selected by default when an active CLI exists
- otherwise the first eligible active profile is selected by deterministic role priority

Only status=active profiles are switchable.
Non-active/pending profiles are returned separately as locked profiles and cannot be selected.

Switching away from RSG:
- keeps existing accepted commitments alive
- pauses AVAILABLE RSG availability to stop new work
- does not cancel active assignments
- does not transfer custody

Switching back to RSG restores action authority, but paused availability remains paused until explicitly resumed.

Profile switcher returns active_commitment_count so UI can show background responsibility badges.

## CON role isolation

Verified:
- default CLI cannot use CON trip functions
- default CLI cannot open CON operational context
- explicit switch to CON enables CON functions
- switching to TIE blocks CON functions again

CON and RSG role guards now use tc_require_active_profile instead of account-wide profile ownership.

## RSG physical execution

Accepted last-mile assignment materializes one DELIVERY_TO_CUSTOMER MOV.

Custody phases:
- LAST_MILE_PICKUP: NODE/TIE owner -> RSG
- LAST_MILE_DELIVERY: RSG -> CLI

custody_events remains the single append-only custody transfer ledger.

Flow verified:
NODE/TIE RELEASE
-> RSG RECEIVE
-> custody NODE/TIE -> RSG
-> package OUT_FOR_DELIVERY
-> movement IN_TRANSIT

Arrival-candidate GPS/reference:
-> may set movement ARRIVED
-> never marks package DELIVERED
-> never transfers custody

Final delivery:
-> requires package-specific registered last-mile evidence
-> transfers custody RSG -> CLI
-> package DELIVERED
-> movement COMPLETED
-> assignment COMPLETED
-> RSG capacity reservation CONSUMED

## Private delivery evidence

Last-mile evidence is stored through existing private tc-evidence bucket and evidence ledger.

Evidence registration validates:
- assigned active RSG
- movement ownership
- package belongs to movement
- Storage object exists
- Storage object is owned by caller auth.uid
- object path uses caller auth.uid prefix

LAST_MILE evidence SELECT is now active-profile scoped:
- active RSG uploader can read it
- active CLI owner of order can read it
- active TIE on same account cannot read it
- inactive RSG on same account cannot use RSG actions

This fixes account-wide subprofile leakage from current_user_profile_ids for last-mile evidence.

## Explicit commitment semantics

Verified scenario:
RSG accepts delivery
-> switch to TIE
-> RSG commitment remains ACTIVE
-> RSG availability pauses
-> TIE cannot operate RSG assignment
-> TIE may perform its own origin-custody release
-> switch back to RSG
-> RSG can continue pickup/delivery

Same auth user can therefore move between personal/business/work profiles without inheriting the permissions of inactive profiles.

## Privacy

Pre-accept RSG opportunity remains PII-free.
Post-accept RSG digital view may expose PKG ID, recipient name, private address and phone.
Physical final-delivery label contains PKG ID, recipient name and address but no phone.

## Verification

Rollback tests passed:
- default CLI selection
- CLI cannot use CON
- explicit CON switch
- TIE cannot use CON
- CLI cannot use RSG
- explicit RSG ACCEPT
- commitment survives profile switch
- switching away pauses new RSG availability
- inactive RSG cannot operate
- active TIE can release own custody
- switching back restores RSG actions
- active RSG can read own last-mile evidence
- active TIE cannot read RSG last-mile evidence
- active CLI buyer can read own delivery evidence
- final delivery requires RSG profile active
- two custody events exactly
- final custody is CLI

All test profiles, active-profile contexts, last-mile tasks, evidence rows and storage objects rolled back.

## Security

active_profile_contexts and active_profile_context_events are fail-closed internal tables.

tc_require_active_profile, tc_require_my_con_profile and tc_require_my_rsg_profile are private helpers.

User switcher functions are authenticated-only.

Sensitive CON/RSG wrappers remain SECURITY DEFINER with explicit empty search_path and role-scoped guards.

Evidence anon SELECT was revoked earlier; LAST_MILE evidence policy now depends on active_profile_id.

## Deferred

- migrate additional legacy role-sensitive RLS policies from account-wide profile ownership to active-profile context
- profile switcher UI in FlutterFlow
- profile activation/onboarding requirements UI
- badges/notifications for background commitments
- RSG batching of multiple last-mile tasks
- Production / merge / deploy
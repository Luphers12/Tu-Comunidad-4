# TU COMUNIDAD — PROFILE AFFILIATION ELIGIBILITY PASS

Local date: 2026-09-21
Repository: Luphers12/Tu-Comunidad-4
Branch: tc/full-build-20260918
STAGING: tu-comunidad-staging / ckvwfeljoonwhzmtrmnw

## Gate

PROFILE_AFFILIATION_ELIGIBILITY: PASS
ACTIVE_REVIEWER_CONTEXT: PASS

Migration count moved from 171 to 173.

## Migrations

- 20260921064659_profile_switcher_affiliation_eligibility_v1.sql — SHA-256 b4847c534ffb663acd351d00451eebcc538f2f57ccf5ecbb839ef184217dbc6e
- 20260921064724_affiliation_reviewer_active_profile_v1.sql — SHA-256 9732d9d4565b5030131b453557a0e7fd7289733d85773dc3bdf98051916f9bb1

## Activation contract

A role may be visible to the account before activation, but it is not switchable until its operational profile exists with status=active.

The existing affiliation workflow remains the only public activation path for TIE, VEN, CON, RSG and PTC.

tc_profile_switcher now returns role_activation_options for:
- TIE
- VEN
- CON
- RSG
- PTC

Each option contains:
- role_code
- activation_state
- switchable
- can_start_affiliation
- application_public_id
- activated_profile_public_id
- required_total
- required_complete
- required_remaining
- requirements

Activation states may include:
- NOT_STARTED
- DRAFT
- SUBMITTED
- UNDER_REVIEW
- CHANGES_REQUESTED
- APPROVED
- REJECTED
- WITHDRAWN
- ACTIVE

ACTIVE is derived from a real active profile; an application in progress remains non-switchable.

## Requirement gate

tc_start_affiliation seeds common requirements and role-specific requirements.

RSG example:
- IDENTITY
- COMMUNITY
- TERMS
- SERVICE_AREA
- CONTACT_METHOD

Submission requires every required item to be at least PROVIDED / VERIFIED / WAIVED.
Final approval requires every required item to be VERIFIED / WAIVED.
Only final approval creates or activates the operational profile.

## Reviewer profile isolation

Affiliation review and approval no longer search every profile owned by auth.uid.

The following now use only tc_active_profile_id():
- tc_affiliation_review_queue
- tc_review_affiliation_requirement
- tc_review_affiliation_application
- tc_finalize_affiliation_application

A person may own a capable SOP/ADM profile, but while active as CLI/TIE/etc. they cannot review or approve affiliations.

## Verification — rollback

One account temporarily owned CLI + capable SOP. A new RSG application was processed entirely through public affiliation RPCs.

PASS:
- default CLI saw RSG as NOT_STARTED and non-switchable
- CLI started RSG affiliation
- DRAFT RSG remained locked
- SUBMITTED RSG remained locked
- CLI review queue stayed empty despite same account owning capable SOP
- CLI review action was forbidden
- explicit switch to SOP exposed review queue
- SOP verified every required item
- SOP approved application
- approval created active RSG profile
- switcher changed RSG activation_state to ACTIVE
- RSG appeared in switchable_profiles
- explicit switch to newly activated RSG succeeded

All temporary SOP/RSG profiles, applications, requirements and active-profile contexts rolled back.

## FlutterFlow integration contract

Profile UI should call tc_profile_switcher and render:
- current active profile
- switchable_profiles
- active_commitment_count badge
- role_activation_options for locked/in-progress roles

Role switch uses tc_switch_active_profile(profile_public_id).

Do not duplicate authorization in client AppState. Database active-profile context remains source of truth.

Current FlutterFlow export is UI-only and does not contain Supabase generated backend code or supabase_flutter dependency. Therefore no manual second Supabase client was added to generated Flutter code.

No Production, merge or deploy action was performed.
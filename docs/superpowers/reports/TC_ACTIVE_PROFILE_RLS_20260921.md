# TU COMUNIDAD — ACTIVE PROFILE RLS MIGRATION PASS

Local date: 2026-09-21
Repository: Luphers12/Tu-Comunidad-4
Branch: tc/full-build-20260918
STAGING: tu-comunidad-staging / ckvwfeljoonwhzmtrmnw

## Gate

ACTIVE_PROFILE_RLS_MIGRATION: PASS

Migration count moved from 167 to 171.

## Migrations

- 20260921063556_legacy_role_reads_active_profile_v1.sql — SHA-256 5c82df9d9616d92e9652b397ae535d6fd0b9b695835d41a8ad1b2418f94437f4
- 20260921063624_logistics_role_reads_active_profile_v1.sql — SHA-256 54b3886cfda627efa16f27f25c5c5fbefa077bafe2bef9cb4f6f821a83599d7c
- 20260921063908_movement_visibility_recursion_fix_v1.sql — SHA-256 845cd01be3a988e9a089a7e5b67ebdf7ee85ddbfc2fb23333a5520f834447966
- 20260921063948_movement_visibility_policy_execute_v1.sql — SHA-256 17ec171468dbfb6b3823bb7183090fdc872ca9b481a20a2a8413551f6cec2a01

## Scope

All public RLS policies that still used current_user_profile_ids() for role-sensitive reads were migrated to explicit active-profile context.

Covered domains:
- orders
- sub_orders
- order_items
- inventory
- inventory_reservations
- driver_vehicle_authorizations
- vehicles
- route_assignments
- route_opportunities
- packages
- movements
- movement_packages
- custody_events
- demand_requests
- event_inbox
- sync_conflicts
- evidence

## Authorization rule

Account ownership of many subprofiles no longer means simultaneous read authority.

Role-sensitive direct reads now evaluate tc_active_profile_id().

Examples:
- active CLI sees its client order/suborders/packages
- active TIE/VEN sees only the exact store profile slice
- another TIE profile on the same account does not inherit that store data
- active CON sees only its own driver authorizations/vehicles/route assignments
- inactive CON profile on the same account does not inherit the active CON slice

## Movement recursion correction

Testing exposed a real RLS recursion:
movements_read -> movement_packages -> movement_packages_read -> movements.

Forward fix introduced tc_active_profile_can_read_movement(uuid), a SECURITY DEFINER boolean RLS helper.

The helper evaluates:
- active from/to movement actor
- active CON route assignment
- movement package visible to active CLI/store/custodian

Both movements_read and movement_packages_read now use the same helper.

Authenticated EXECUTE is granted only because PostgreSQL must execute the function while evaluating RLS. It returns a boolean only and no row data.

## Verification — rollback

One real STAGING account owning CLI, several TIE profiles and two CON profiles was used.

PASS:
- CLI saw its order
- CLI saw both suborders and both packages from its order
- CLI saw movement/custody history for its package
- CLI did not see CON vehicle authorizations
- TIE A saw only TIE A suborder/package
- TIE B saw only TIE B suborder/package
- TIE A and TIE B both saw a movement/custody event where they were physical actors
- unrelated TIE C on the same account saw none of A/B suborders, packages, MOV or custody
- CON A saw no driver authorization belonging to another profile
- CON B saw no driver authorization belonging to another profile

All test rows rolled back.

## Post state

remaining RLS policies using current_user_profile_ids(): 0
active-profile RLS policies: 15
runtime cron: active
cron failures: 0

## Deferred

Some SECURITY DEFINER application functions outside logistics still use current_user_profile_ids() internally, especially affiliation and linguistic-role workflows.
They were not changed in this block because their role semantics require separate domain review rather than blind replacement.

Next UI integration:
- FlutterFlow profile switcher
- active role shell/home
- background commitment badges
- explicit switch before role-only actions
- no duplicate client-side authorization state

No Production, merge or deploy action was performed.
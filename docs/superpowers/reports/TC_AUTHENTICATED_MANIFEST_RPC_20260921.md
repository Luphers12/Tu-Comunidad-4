# TU COMUNIDAD — AUTHENTICATED MANIFEST RPC PASS

Local date: 2026-09-21
Repository: Luphers12/Tu-Comunidad-4
Branch: tc/full-build-20260918
STAGING: tu-comunidad-staging / ckvwfeljoonwhzmtrmnw

## Gate

AUTHENTICATED_MANIFEST_RPC: PASS
MANIFEST_PII_BOUNDARY: PASS
MANIFEST_ACTIVE_PROFILE_ISOLATION: PASS

Migration count moved from 182 to 185.

## Migrations

- 20260921121452_manifest_authenticated_read_foundation_v1.sql — SHA-256 73bc94ff29082baea052e5ae3c13e58235b068f927858baab8064c509b99c874
- 20260921121535_manifest_authenticated_rpc_v1.sql — SHA-256 38bb35e4049c81b1fadb75bdfb9c8e88f6813799cad449122eb614a96c4abade
- 20260921121727_manifest_segment_source_correction_v1.sql — SHA-256 6c59ca93f8ef02de4b5ddb13ea0059347211ef6298f2d6430df08ca57d2adf3e

## Internal manifest tables remain closed

Authenticated users still have no direct SELECT on:
- logistics_manifests
- logistics_manifest_segments
- logistics_execution_manifests

All remain RLS-enabled fail-closed internal tables.

## Canonical source correction

tc_rebuild_trip_manifest_snapshot writes the current canonical per-hop source to logistics_manifest_segments.

The authenticated renderer was therefore corrected forward to read logistics_manifest_segments rather than the legacy logistics_manifest_items table.

Full manifest responses aggregate package-level data while preserving the underlying per-hop segment list.

## tc_con_my_manifests

Authenticated active-CON only.

Rules:
- explicit CON subprofile must be the active profile
- only trips whose driver_profile_id equals that CON are visible
- optional trip filter
- latest manifest only by default
- optional manifest history
- PII-free safe renderer only

Exposes:
- MNF/TRP/VEH public IDs
- manifest type/version/time
- trip stops and operational node names
- PKG/LGD public IDs
- manifest segment public IDs
- match/reservation/MOV public IDs
- board/alight stop sequences
- physical package requirements and states

Does not expose:
- recipient name
- phone
- private address
- payment data
- order-private fields

## tc_node_my_manifest_view

Authenticated active exact NODE owner only.

Current allowed owner profile types:
- TIE
- PTC

The requested node must be active, network-enabled, and owned by the active profile.

The node receives only packages whose manifest segment physically touches one of that node's stop occurrences.

Per-package action is summarized as:
- SUBE
- BAJA
- CONTINUA
- BAJA_Y_SUBE when the underlying manifest proves separate transfer semantics

Underlying visible manifest segments are also returned so the summary remains auditable.

Another node owned by another subprofile on the same account remains forbidden until the user explicitly switches profiles.

## tc_support_manifest_view

Authenticated active SOP/ADM only.

Requires explicit GLOBAL capability:
logistics.manifest.support.read

The capability exists but has zero persistent LIVE grants after rollback testing.
Therefore support access is opt-in and currently unavailable until explicitly granted.

Support RPC accepts an exact MNF public ID and returns the same PII-free renderer used by CON.

## Active-profile verification

Rollback test used one account with CLI/TIE/CON plus temporary SOP profiles.

PASS:
- CLI could not call CON manifest RPC
- CLI could not call NODE manifest RPC
- CLI could not impersonate SOP manifest access
- active CON saw only its own trip manifest
- active CON latest view returned only latest manifest version
- active CON history view returned both manifest versions
- different CON subprofile could not enumerate the first CON trip
- active exact NODE owner received only its node-visible package view
- foreign NODE access was blocked
- SOP without capability was blocked
- SOP with explicit global capability viewed exact historical manifest
- direct manifest-table access remained denied
- all returned manifest surfaces were PII-free

## Verification fixture

A real rollback-only A -> B -> C trip was built using the canonical routing/matching/reservation/materialization flow.

Two manifest versions were produced:
- materialized LOAD_PLAN
- subsequent DEPARTURE snapshot

The manifest contained canonical per-hop segments and the middle NODE received the expected operational action view.

All orders, packages, trips, manifests, segments, support profiles and capability grants rolled back.

## Security

User RPCs:
- SECURITY DEFINER
- explicit empty search_path
- anon EXECUTE denied
- authenticated EXECUTE allowed
- service_role direct EXECUTE denied

Private tc_manifest_safe_payload:
- not executable by anon/authenticated/service_role
- SECURITY DEFINER
- does not reference orders
- does not reference persons
- does not reference customer_locations
- does not reference private_destination_snapshots

## Deferred

- grant logistics.manifest.support.read to real SOP/ADM only through authorized governance
- FlutterFlow manifest screens
- PTC employee/delegated-node access model
- notification badge when a new manifest version is published
- Production / merge / deploy
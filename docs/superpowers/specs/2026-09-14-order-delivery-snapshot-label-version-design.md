# Order Delivery Snapshot & Package Label Version Design

**Status:** Approved design, pending implementation plan  
**Date:** 2026-09-14  
**Project:** TU COMUNIDAD  
**Repository:** `Luphers12/Tu-Comunidad-4`  
**Target branch:** `debelop`

## 1. Goal

Make package labels historically correct and privacy-preserving by separating mutable profile/location data from the immutable delivery contract of an order and from the printable label version attached to a physical package.

The design must guarantee all of the following:

- The printed recipient name is the name chosen for that specific order, not whatever name the account/profile happens to have later.
- The printed destination is the destination approved for the package at that point in time, not a fresh lookup of mutable PTC/customer-location data.
- Reprinting an existing label does not silently change its contents.
- A true destination change creates a new immutable delivery snapshot and a new package-label version while keeping the same `PKG-XXXX` identity.
- Only one package-label version is current for a package at a time.
- Label payloads contain only the approved printable data and never expose private last-mile information.

## 2. Current State and Root Cause

The current schema has `orders.destination_type` and `orders.destination_id`, but no per-order recipient-name snapshot and no immutable delivery snapshot.

`public.tc_render_package_label(p_package_public_id text)` currently resolves the recipient from `persons.full_name` and resolves the destination from live `ptc_points` / `customer_locations` / territory tables. That means a reprint can change if a person renames their profile, a customer location is edited, a PTC public name changes, or territorial data is updated.

That behavior is incompatible with the approved TU COMUNIDAD rule that an order and package must preserve the exact delivery intent that existed when the package was created, and that a destination change must be explicit, auditable, chargeable when applicable, and represented as a new label version rather than as a silent data refresh.

`customer_locations.authorized_contact` is not treated as the recipient-name source. Its current semantics are contact/location metadata; it is not a guaranteed per-order recipient snapshot.

## 3. Canonical Model

Use two append-only concepts:

1. **Order delivery snapshot** — immutable record of the delivery identity and public printable destination for an order at a specific version.
2. **Package label version** — immutable record tying a package to exactly one order-delivery snapshot for a specific printable label version.

A package keeps the same `PKG-XXXX` for its whole life. Redirects create a new delivery snapshot and a new label version, not a new package.

### 3.1 Example

```text
ORDER
  ├── DELIVERY SNAPSHOT V1
  │     recipient: Lucas Hernández
  │     destination: Tienda Bulej
  │     community: Bulej
  │     municipality: San Mateo Ixtatán
  │     department: Huehuetenango
  │
  └── PKG-4821
        └── LABEL V1 -> DELIVERY SNAPSHOT V1
```

After a paid and authorized redirect:

```text
ORDER
  ├── DELIVERY SNAPSHOT V1
  │     destination: Tienda Bulej
  │
  ├── DELIVERY SNAPSHOT V2
  │     destination: Nuevo PTC
  │
  └── PKG-4821
        ├── LABEL V1 -> SNAPSHOT V1   [SUPERSEDED]
        └── LABEL V2 -> SNAPSHOT V2   [CURRENT]
```

A normal reprint of LABEL V2 does **not** create V3. It renders the same immutable V2 payload again.

## 4. Proposed Data Model

### 4.1 `order_delivery_snapshots`

Purpose: preserve the delivery identity and the public printable destination for an order at a specific historical version.

Proposed minimum fields:

```text
id uuid primary key
public_id text unique not null            -- e.g. ODS-XXXX
order_id uuid not null references orders(id)
version bigint not null
recipient_name text not null

destination_type text not null            -- PTC / STORE / HOME / other approved type
destination_reference text null            -- opaque/source reference, not public PII

destination_name text not null             -- printable PTC/store/destination label
community_name text not null
municipality_name text not null
department_name text not null

reason text not null                       -- INITIAL_ORDER / REDIRECT / SYSTEM_CORRECTION / LEGACY_MIGRATION
created_at timestamptz not null default now()
created_by_person_id uuid null
created_by_profile_id uuid null
source_event_id text null
```

Recommended constraints:

- `unique(order_id, version)`
- `version > 0`
- `recipient_name` nonblank
- destination/community/municipality/department names nonblank
- append-only semantics: no normal UPDATE/DELETE path

The snapshot intentionally does **not** contain by default:

- phone number
- email
- full residential address
- coordinates
- delivery instructions
- safe-location photos
- age-verification data
- payment data

Those remain in their private domain tables and are revealed only to authorized roles when operationally necessary.

### 4.2 `package_label_versions`

Purpose: preserve exactly which printable delivery snapshot a physical package label represents.

Proposed minimum fields:

```text
id uuid primary key
public_id text unique not null            -- e.g. LBL-XXXX
package_id uuid not null references packages(id)
version bigint not null
order_delivery_snapshot_id uuid not null references order_delivery_snapshots(id)
created_at timestamptz not null default now()
source_event_id text null
```

Recommended constraints:

- `unique(package_id, version)`
- `version > 0`
- rows are immutable after insert
- the current label version is the highest `version` for that package

Canonical historical model: append-only. There is no mutable `CURRENT/SUPERSEDED` flag in V1. The highest valid version is current; every earlier version is derived as superseded. Redirect creates a new row and never rewrites or deletes the old row.

## 5. Recipient Name Contract

Checkout/order creation must explicitly capture the **recipient name for that order**.

The account owner and the package recipient are not assumed to be the same person.

Example:

```text
Account owner: Lucas Hernández
Recipient chosen for this order: María Hernández
```

The printed package label must say `María Hernández`.

The following are not canonical recipient sources for historical label rendering:

- `persons.full_name`
- `users.display_name`
- `customer_locations.authorized_contact`

They may be defaults offered to the user during checkout, but the order must snapshot the final chosen recipient name.

## 6. Destination Snapshot Contract

Before a package label is issued, the system resolves the order's approved public logistics destination into the printable hierarchy and stores those values in the snapshot. The exact snapshot-creation moment may be checkout or later routing resolution, but package birth cannot issue Label V1 until a valid snapshot exists.

For a PTC/store destination, the snapshot contains the approved printable values such as:

```text
recipient_name: Lucas Hernández
destination_name: Tienda Bulej
community_name: Bulej
municipality_name: San Mateo Ixtatán
department_name: Huehuetenango
```

The snapshot may keep a non-public `destination_reference` so the system knows which domain object produced the snapshot, but rendering must not re-query mutable live names to replace historical values. For HOME delivery, the printable destination is the authorized final distribution PTC/store/node, never the residential street address. The private last-mile residential address remains outside the physical-label payload and is governed by the separate final-mile privacy contract.

Editing a `customer_locations` row or renaming a PTC later must not alter an already-issued label version.

## 7. Package Birth and Label Issuance

The package is born when physical preparation starts through the canonical preparation flow.

At package birth:

1. `PKG-XXXX` is created in state `CREATED`.
2. The order must have an applicable delivery snapshot.
3. Label version 1 is created for the package and linked to that snapshot.
4. `tc_render_package_label` renders from the package-label version and snapshot, not from live profile/location tables.

The package identity never changes because of reprint, movement, PTC transfer, CON assignment, RSG assignment, return, or redirect.

## 8. Physical Label Contract

The physical package label may contain only:

- `TU COMUNIDAD`
- recipient name chosen for the order
- `PTC/DESTINO` / final logistics destination name
- aldea/community
- municipality
- department
- `PKG-XXXX`
- QR/barcode value identifying the package or an opaque safe token

The label must not contain:

- phone number
- full residential address
- coordinates
- email
- delivery instructions
- safe-location photos
- payment details
- age/ID verification data

The QR/barcode must not encode those private fields either.

## 9. Render Contract

`tc_render_package_label` remains the label-rendering contract but changes its source of truth.

Future behavior:

```text
package_public_id
  -> current package_label_version
  -> order_delivery_snapshot
  -> sanitized printable JSON
```

The renderer must never re-derive historical values from `persons`, `customer_locations`, `ptc_points`, `communities`, `municipalities`, or `departments` except in a migration/backfill tool explicitly designed for legacy data.

A successful render is deterministic for a given label-version row.

## 10. Redirect and Reprint Semantics

### 10.1 Reprint

A reprint means: print the same label version again.

It does not:

- create a new package
- create a new delivery snapshot
- create a new label version
- change destination
- charge a redirect fee

### 10.2 Redirect

A redirect means the client requests a different final PTC/destination before the package reaches final distribution and the redirect is allowed by policy.

After validation and payment when applicable:

1. Create a new order-delivery snapshot with `reason = REDIRECT`.
2. Create the next package-label version linked to the new snapshot.
3. The old label version becomes historical/superseded by derivation because a higher version now exists; the old row is not modified.
4. The same `PKG-XXXX` remains.
5. The new label is printed.
6. Audit events record destination change, fee decision, old/new snapshot IDs, and old/new label versions.

A normal profile/location edit must never simulate this redirect flow.

## 11. Privacy and Access

### 11.1 Public/physical layer

Only printable label fields are exposed.

### 11.2 Intercommunity logistics

CON and intermediate PTCs use package identity, operational route/drop-off data, and custody records. They do not require the customer's residential address, phone, final-mile instructions, or safe-location photos.

### 11.3 Final mile

Private final-mile fields remain digital and role-scoped. Only the currently authorized RSG can access the necessary contact bridge, full delivery address, coordinates when applicable, delivery instructions, and safe-location evidence while the assignment/custody is active.

## 12. Legacy Data Strategy

Existing legacy orders/packages may not have a trustworthy per-order recipient snapshot or historical label version.

The system must not fabricate historical data where the original value is ambiguous.

Migration rules:

- If a legacy record can be reconstructed unambiguously from immutable evidence, create a migration snapshot marked `SYSTEM_CORRECTION` or `LEGACY_MIGRATION`.
- If recipient or destination history is ambiguous, mark the legacy package as needing explicit resolution before issuing a new historical label contract.
- Do not silently treat `persons.full_name` as authoritative historical recipient data.
- Do not silently treat the current PTC/customer-location name as proof of the original historical destination.

## 13. Audit Model

At minimum, future audit events should support:

```text
ORDER_DELIVERY_SNAPSHOT_CREATED
PACKAGE_LABEL_VERSION_ISSUED
PACKAGE_LABEL_REPRINTED
DESTINATION_CHANGE_REQUESTED
DESTINATION_CHANGE_APPROVED
DESTINATION_CHANGE_PAID
PACKAGE_LABEL_VERSION_SUPERSEDED  -- audit event; does not require mutating the old label row
```

Audit metadata should identify the relevant order, package, snapshot, label version, event ID, and reason without embedding unnecessary PII.

## 14. Failure Semantics

- If package creation fails, no label version may survive without its package.
- If label-version creation fails during package birth, the package-birth transaction should roll back unless the implementation plan explicitly separates physical package creation from printable label issuance with a recoverable state; default recommendation is atomic creation.
- If printing hardware fails after the database transaction commits, do not create another package or label version. Retry rendering/printing the same version.
- If redirect snapshot creation or new label-version creation fails, destination change must not become effective partially.

## 15. RLS and Security Direction

The implementation must not expose snapshot or label-version tables directly to broad app roles by default.

Preferred direction:

- RLS enabled.
- No direct `anon` DML.
- Minimal direct `authenticated` access, preferably none for raw immutable snapshot tables.
- Reads/writes happen through narrowly scoped RPCs / security-definer functions with explicit role checks.
- Service-role access remains backend-only.

Exact policies and grants are implementation-plan work and must be verified against the existing role/capability model before migration.

## 16. Compatibility with Existing Flows

### `tc_start_preparation`

Current function already creates/reuses `PKG` in `CREATED` and attaches `package_contents`. It must be extended or wrapped so package birth also has a valid delivery snapshot and label version, without reintroducing mutable lookups.

### `tc_render_package_label`

Current function must be changed from live lookup rendering to snapshot/version rendering.

### `execute_checkout`

Legacy checkout currently creates packages too early and still uses legacy inventory logic. This design does not cut over checkout. Any integration with the new delivery snapshot must be planned carefully so there are not two competing package-birth contracts.

### `tc_source_allocate_reserve`

Remains unchanged by this design.

## 17. Non-Goals for This Design

This design does not implement:

- redirect fees
- payment collection for redirect
- HOLD
- failed-delivery handling
- final-mile contact bridge
- delivery evidence/photo/signature
- age-restricted delivery
- return-to-sender
- refund logic
- UI/FlutterFlow changes

Those remain separate later blocks.

## 18. Implementation Order

The implementation plan should proceed in this order:

1. Add immutable order-delivery snapshot foundation.
2. Add package-label version foundation.
3. Add/adjust order recipient capture so every new order has a recipient name chosen for that order.
4. Update package-birth flow to bind new packages to a snapshot and label version.
5. Rewrite `tc_render_package_label` to render only from the immutable version/snapshot.
6. Add regression tests proving profile/location/PTC edits cannot alter an existing label version.
7. Only after that, design/implement destination redirect and label supersession.

## 19. Acceptance Criteria

The design is successfully implemented only when all of the following are true:

- A new order has an immutable recipient name chosen for that order.
- A new package has exactly one initial label version.
- Reprinting returns identical printable values for the same label version.
- Changing `persons.full_name` does not change an existing package label.
- Changing `customer_locations` does not change an existing package label.
- Renaming or editing a PTC does not change an existing package label.
- Redirect creates a new snapshot/version and preserves old history without mutating the previous label row.
- Reprint does not create a redirect/version.
- Same `PKG-XXXX` survives every label version.
- No prohibited PII is present in physical-label payloads or QR/barcode values.
- Existing sourcing/inventory/package-content invariants remain intact.

## 20. Decision Summary

**Selected architecture:** order delivery snapshot + package label versions.

**Source of truth for printed recipient:** immutable recipient name chosen for the order.

**Source of truth for printed destination:** immutable delivery snapshot, not live mutable destination records.

**Package identity:** permanent `PKG-XXXX`.

**Reprint:** same label version, no new business event.

**Redirect:** new delivery snapshot + new label version, same PKG.

**Privacy:** last-mile private data remains digital and role-scoped; physical label contains only approved public logistics data.

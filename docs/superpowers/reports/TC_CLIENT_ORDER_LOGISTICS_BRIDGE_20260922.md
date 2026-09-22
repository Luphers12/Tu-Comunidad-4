# TU COMUNIDAD — CLIENT ORDER → LOGISTICS DEMAND BRIDGE PASS

**Date:** 2026-09-22  
**Authority:** Lucas  
**Supabase STAGING:** `tu-comunidad-staging` / `ckvwfeljoonwhzmtrmnw`  
**Backend branch:** `tc/full-build-20260918`  
**Production / merge / deploy:** NOT TOUCHED

## Result

```text
SOURCE_READY_PACKAGE_TO_LGD:              PASS
LEGACY_CHECKOUT_PREPARATION_ADAPTER:      PASS
CANONICAL_SOURCING_PREPARATION_TO_LGD:    PASS
DOWNSTREAM_RUNTIME_HANDOFF:               PASS
NO_TRIP_NOW_NOT_DEAD_END:                 PASS
FAIL_CLOSED_SOURCE_PROFILE:               PASS
FAIL_CLOSED_SOURCE_NODE:                  PASS
HOME_LATE_RECONSTRUCTION_BLOCKED:         PASS
MIGRATION_REPO_PARITY:                    PASS
PERSISTENT_TEST_FIXTURES:                 0
```

The previously unproven commerce/package → canonical logistics handoff now has an explicit backend owner.

No new table was created.

## Source-of-truth finding

Before this block, STAGING had a complete downstream runtime beginning at an existing `logistics_demands` row:

```text
LGD
→ runtime outbox
→ routing
→ matching
→ capacity
→ plan / manifest / MOV
→ custody
→ continuation / recovery
→ last mile
```

But no PostgreSQL function, trigger, deployed Edge Function, or repository implementation was found that created the first `logistics_demands` row from a ready client-order package.

The deployed Edge Function `guardian-mcp` is a read-only affiliation audit surface and is not the commerce/logistics bridge.

## Canonical grain

The bridge uses:

```text
1 READY client-order PKG
→ 1 active CLIENT_ORDER logistics demand
```

This is compatible with the canonical relationship:

```text
1 source operation → 1..N logistics demands
1 logistics demand → 0..N PKG
many logistics demands → may share one MOV
```

No order, PKG, logistics demand, MOV, capacity reservation, or custody concept was merged into another grain.

## New backend primitives

### tc_inv_consume(...)

Internal/service-only.

Atomically:

```text
inventory reservation RESERVED
→ CONSUMED

inventory.quantity_reserved  -= quantity
inventory.quantity_consumed  += quantity
inventory.quantity_on_hand   -= quantity
inventory.version            += 1
```

History is preserved through `audit_logs`.

No second inventory-reservation engine was introduced.

### tc_ensure_operational_node_destination_version(...)

Internal/service-only.

Reuses the existing immutable `logistics_destination_versions` model for an operational NODE. A new destination version is appended only when the typed territorial snapshot changed.

No parallel NODE/destination table was created.

### tc_ensure_client_order_destination_contract(...)

Internal/service-only.

- Existing `orders.destination_contract_id`: reused.
- Legacy PTC destination: converted to the unique VERIFIED + active + network-enabled PTC operational NODE.
- HOME without an already frozen destination contract: fails closed with `TC_HOME_DESTINATION_CONTRACT_REQUIRED`.

The bridge deliberately does **not** reconstruct a private HOME address late.

### tc_materialize_client_order_logistics_demand(...)

Internal/service-only.

Requires:

- PKG state = READY;
- active source store profile TIE/VEN;
- PKG current custody = source store;
- exactly one VERIFIED + active + network-enabled STORE_PICKUP node owned by the source profile;
- canonical destination contract.

It creates:

```text
LGD state CREATED
↓
logistics_demand_packages link
↓
LGD state READY_FOR_ROUTING
↓
existing logistics_demands_runtime_outbox trigger
```

Therefore the runtime never observes a half-built LGD without its PKG membership.

### tc_complete_package_preparation(package_public_id, idempotency_key)

This is the **single authenticated client-facing RPC** added by this block.

Requires:

- authenticated user;
- explicit active profile;
- exact active TIE/VEN source profile;
- exact source custody.

For the canonical sourcing path it:

```text
inventory reservation
→ CONSUMED

order_sourcing_allocation
→ qty_fulfilled
→ FULFILLED when complete

order_demand_item
→ quantity_fulfilled
→ FULFILLED/PARTIALLY_FULFILLED

PKG
→ READY

PKG READY
→ CLIENT_ORDER LGD
→ READY_FOR_ROUTING
```

It does **not** require or create a new per-order store acceptance step.

### Legacy package adapter

The older `execute_checkout()` creates one package per sub-order before `package_contents` existed.

For this specific compatible shape:

```text
one legacy CREATED PKG in sub-order
+ order_items
+ inventory reservations
```

`tc_complete_package_preparation()` materializes the missing `package_contents` and continues through the same canonical READY → LGD boundary.

Ambiguous legacy package shapes fail closed.

## Runtime verification — ROLLBACK

### Legacy checkout compatibility

Verified inside a rolled-back transaction:

```text
CLI-STG-CLIENT
→ execute_checkout(PTC destination)
→ package CREATED
→ inventory RESERVED
→ no package_contents (legacy shape)

active profile → TIE-STG-BENDICION

tc_complete_package_preparation()
→ package_contents created
→ inventory reservation CONSUMED
→ PKG READY
→ PTC destination_contract materialized
→ LGD READY_FOR_ROUTING
→ logistics_demand_packages = 1
→ DEMAND_ROUTABLE outbox = 1
```

Existing runtime processed the event:

```text
result_code          = NO_TRIP_NOW
structural_reachable = true
current_executable   = false
no_trip_now          = true
hop_count            = 1
```

This verifies the canonical invariant:

```text
NO_TRIP_NOW != DEAD_END
```

### Canonical sourcing path

Verified independently inside a rolled-back transaction:

```text
order
→ order_demand_item OPEN
→ tc_source_allocate_reserve()
→ sourcing allocation ACTIVE
→ inventory reservation RESERVED
→ tc_start_preparation()
→ PKG CREATED + package_contents
→ tc_complete_package_preparation()
```

Post-completion:

```text
allocation.state               = FULFILLED
allocation.qty_fulfilled       = 1

order_demand_item.state         = FULFILLED
order_demand_item.qty_fulfilled= 1

inventory reservation           = CONSUMED
PKG                              = READY
LGD                              = READY_FOR_ROUTING
LGD↔PKG links                    = 1
DEMAND_ROUTABLE outbox           = 1
```

Runtime again produced structural reachability + `NO_TRIP_NOW` because no real TRIP currently exists.

### Negative/fail-closed verification

Verified inside rolled-back transactions:

```text
CLI active profile tries store publish
→ TC_ACTIVE_PROFILE_TYPE_MISMATCH

TIE without verified network STORE_PICKUP NODE
→ TC_SOURCE_OPERATIONAL_NODE_REQUIRED

legacy HOME order without frozen destination contract
→ TC_HOME_DESTINATION_CONTRACT_REQUIRED

LGDs created by those failed attempts
→ 0
```

## Persistent state after tests

All business test transactions were rolled back.

Persistent counts returned to:

```text
orders                    2
sub_orders                4
packages                  4
logistics_demands         0
logistics_demand_packages 0
logistics_trips           0
logistics_matches         0
logistics_manifests       0
movements                 0
custody_events            0
last_mile_tasks           0
active_profile_contexts   0
active_profile_events     0
```

## Security

Functions introduced by the bridge all use explicit empty `search_path`.

Authenticated surface:

```text
tc_complete_package_preparation
```

Internal/service-only:

```text
tc_inv_consume
tc_ensure_operational_node_destination_version
tc_ensure_client_order_destination_contract
tc_materialize_client_order_logistics_demand
tc_publish_ready_package_to_logistics
```

`anon` EXECUTE = false for all bridge functions.

The initially exposed READY-package publisher was removed from the authenticated surface because `tc_complete_package_preparation()` already handles READY idempotently.

Security Advisor after hardening:

```text
anon SECURITY DEFINER executable:          10 WARN  (unchanged existing allowlist)
authenticated SECURITY DEFINER executable: 138 WARN
leaked password protection disabled:        1 WARN
```

The authenticated count was 137 before this bridge. Net new user-executable SECURITY DEFINER surface = **1**.

No Security Advisor ERROR was introduced.

## Migrations

STAGING migration count: **195**

New canonical migrations:

- `20260922134743_client_order_logistics_bridge_v1.sql`
- `20260922134947_client_order_logistics_bridge_uuid_fix_v1.sql`
- `20260922135529_client_order_logistics_bridge_surface_hardening_v1.sql`

All three files were copied from `supabase_migrations.schema_migrations.statements` and verified **byte-for-byte equal** to STAGING.

## Important upstream gap — NOT silently solved

The bridge requested by this block is closed from **prepared/ready commercial cargo → logistics**.

A different upstream gap remains:

```text
client cart / checkout
→ order_demand_items
```

Current findings:

1. No PostgreSQL function/trigger creates `order_demand_items`.
2. The only checkout RPC found is legacy `execute_checkout()`.
3. `execute_checkout()` creates sub-orders, order-items, inventory reservations and packages directly.
4. The current Flutter page `ShoppingCartLogistics` button “Confirmar Pedido y Ruta” only navigates to `OrderTracking`; it does not call a checkout/order RPC in the repository snapshot.
5. The canonical payment bounded context is not yet present in `public`.

Therefore this report does **not** claim:

```text
FULL CLIENT CART → PAYMENT → SOURCING → DELIVERY E2E = PASS
```

Doing that next requires defining how a client checkout satisfies the payment requirement and whether the client selects a specific listing/source or creates a source-neutral product demand.

That is a separate product decision, not a missing logistics table.

## Final status

```text
STAGING_SCHEMA_MAP:                       PASS
LOGISTICS_FOUNDATION_PRESENT:            PASS
READY_PACKAGE_TO_LOGISTICS_BRIDGE:       PASS
LEGACY_PREPARATION_COMPATIBILITY:        PASS
CANONICAL_SOURCING_PREPARATION_BRIDGE:   PASS
DOWNSTREAM_RUNTIME_HANDOFF:              PASS
FAIL_CLOSED_NEGATIVE_TESTS:              PASS
MIGRATION_PARITY:                         PASS

FULL_CLIENT_CHECKOUT_E2E:                 NOT PROVEN
UPSTREAM_ORDER_DEMAND_CREATOR:            MISSING
PAYMENT_REQUIREMENT_CONTRACT:             NEEDS PRODUCT DECISION
```

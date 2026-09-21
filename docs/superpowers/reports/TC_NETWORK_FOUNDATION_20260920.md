# TU COMUNIDAD — NETWORK FOUNDATION PASS

**Local date:** 2026-09-20  
**Repository:** `Luphers12/Tu-Comunidad-4`  
**Branch:** `tc/full-build-20260918`  
**STAGING:** `tu-comunidad-staging` / `ckvwfeljoonwhzmtrmnw`

## Gate

```text
FORENSIC_SOT_104: PASS
VERIFIED_REPRODUCIBLE_BASELINE: PASS
NETWORK_FOUNDATION: PASS
```

## Migrations applied

- `20260921021336_destination_contract_foundation_v1.sql` — SHA-256 `68bcc714e5b1d544f3b82a818bc38d9ee1ec8958b59284e74c667681654b807d`
- `20260921021339_operational_location_network_node_v1.sql` — SHA-256 `6306a04746b989e47e6bffd71e0bf1dcf99cc664d37eb22cecd205459c6d94b3`
- `20260921021342_logistics_capability_foundation_v1.sql` — SHA-256 `a4c55ede0e40d51a98503da9d24a6307bc199c3e31cc8f1525ab038f496f85be`
- `20260921021344_directed_logistics_edge_foundation_v1.sql` — SHA-256 `b8b3467edd3edf5b20ceb42ac57e7e1f01b7414205d47b1166bcdc0cbadf3e33`
- `20260921021346_logistics_demand_foundation_v1.sql` — SHA-256 `c088b716bfefc8eacb629f7ba0b40e315d0dccd4e326e926e0afd72fa3fd9af3`

Migration count moved from 104 to **109**.

## HECHO VERIFICADO — DESTINATION CONTRACT

Created:

- `logistics_destinations` — stable DST identity.
- `private_destination_snapshots` — immutable private delivery snapshot.
- `logistics_destination_versions` — immutable DSV contract version.
- `orders.destination_contract_id` — nullable FK to an immutable DSV.

The existing two orders remain on the legacy adapter because `destination_contract_id IS NULL`. No legacy destination data was rewritten.

Private delivery fields (label, point, visual reference, access instructions, authorized contact, photo refs, safe-location reference) are stored separately from the routing-facing DSV.

## HECHO VERIFICADO — NODE

`operational_locations` was reused instead of creating `public.nodes`.

Added:

- `network_enabled`
- `network_enabled_at`
- `network_enabled_by_person_id`

The existing authenticated RPC `tc_save_operational_location` does not reference `network_enabled`, and `authenticated` has no direct UPDATE privilege on `operational_locations`. Ordinary users therefore cannot self-promote a location into the logistics network through the existing location contract.

## HECHO VERIFICADO — LOGISTICS CAPABILITIES

Created a logistics-specific catalog separate from authorization/RBAC `public.capabilities`.

The existing authorization catalog remains at **37** rows.

Seeded logistics capabilities:

- INVENTORY_COMMITMENT
- RECEIVE_CARGO
- HANDOFF_CARGO
- STAGE_CARGO
- SORT_CARGO
- LAST_MILE_ORIGIN
- BOX_HOST

Capability declaration is explicitly not inventory, custody, trip capacity, or a capacity reservation.

## HECHO VERIFICADO — DIRECTED EDGE

Created:

- `logistics_edges`
- `logistics_edge_state_events`

EDGE is structurally directed A→B. It contains no driver, TRIP, MOV, or runtime-capacity assignment.

Runtime state is append-only through OPEN / CLOSED / RESTRICTED events. No OPEN event is created automatically; absence of OPEN must not be treated as executable availability.

## HECHO VERIFICADO — LOGISTICS DEMAND

Created:

- `logistics_demands`
- `logistics_demand_packages`

Supported source types:

- CLIENT_ORDER
- STORE_RESTOCK
- STORE_TO_STORE
- SUPPLIER_DELIVERY
- PTC_TRANSFER
- RETURN
- AGRICULTURAL_CARGO

`ROUTING_EXCEPTION` exists as a demand state, but no candidate/dead-end resolver was implemented. **NO TRIP NOW != DEAD_END** remains reserved for the later routing block.

LGD/PKG linkage does not reserve inventory, trip capacity, custody, payment, or MOV.

## Security / privacy verification

All 9 new Foundation tables:

- have RLS enabled;
- have zero user-facing RLS policies;
- deny direct SELECT to anon and authenticated;
- allow service_role access according to table semantics.

The +9 `rls_enabled_no_policy` advisor findings are therefore intentional fail-closed surfaces.

Security advisor summary after Foundation:

```json
[
  {
    "name": "rls_enabled_no_policy",
    "level": "INFO",
    "count": 129
  },
  {
    "name": "anon_security_definer_function_executable",
    "level": "WARN",
    "count": 10
  },
  {
    "name": "authenticated_security_definer_function_executable",
    "level": "WARN",
    "count": 86
  },
  {
    "name": "auth_leaked_password_protection",
    "level": "WARN",
    "count": 1
  }
]
```

No new public SECURITY DEFINER Foundation API was introduced. `tc_guard_logistics_append_only` is not SECURITY DEFINER.

## Regression verification

After implementation and a transactionally rolled-back runtime test:

```text
orders:                 2
packages:               4
movements:              0
custody_events:         0
operational_locations:  0

logistics_destinations:          0
logistics_destination_versions:  0
private_destination_snapshots:   0
logistics_edges:                 0
logistics_edge_state_events:     0
logistics_demands:               0
logistics_demand_packages:       0
```

Runtime test PASS:

- DST/DSV creation
- immutable DSV guard
- directed A→B edge without implicit B→A
- edge OPEN event
- LGD creation
- LGD→PKG relationship
- authenticated NODE self-promotion denied
- full transaction rolled back

## Deferred by design

Not implemented in this block:

- canonical TRIP
- logistics capacity reservation
- MOV bridge
- manifest / reconciliation
- hop resolver
- loop detection / anti-oscillation runtime
- Promise Engine runtime
- sort/scan execution
- RSG redesign

Those belong to subsequent blocks.

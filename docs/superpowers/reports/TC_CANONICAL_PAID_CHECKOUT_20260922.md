# TU COMUNIDAD — CANONICAL PAID CHECKOUT FOUNDATION PASS

**Date:** 2026-09-22  
**Authority:** Lucas  
**Supabase STAGING:** `tu-comunidad-staging` / `ckvwfeljoonwhzmtrmnw`  
**Backend branch:** `tc/full-build-20260918`  
**Production / merge / deploy:** NOT TOUCHED

## Canonical decisions incorporated

### Source selection mode C

A client may:

- select a specific seller/offer; or
- omit seller and let TU COMUNIDAD select a compatible source automatically.

Seller independence is preserved.

Client-facing attribution is:

```text
Vendido por: <seller_display_name>
```

The source is never presented as inventory owned by TU COMUNIDAD.

### Payment gate

Canonical order:

```text
cart
→ quote / source plan
→ PAYMENT AUTHORIZED
→ commit order
→ commercial demand
→ sourcing
→ atomic inventory reservation
→ preparation
→ PKG
→ logistics demand
```

Without authorized payment:

```text
NO inventory reservation
NO PKG
NO logistics demand
```

Fiado is not a TU COMUNIDAD payment method.

## Provider-agnostic boundary

No provider was selected.

The backend therefore implements only a trusted authorization receipt boundary. It does not claim to charge cards or contact Stripe/Square/PayPal/etc.

`PAY-*` currently represents an external payment authorization receipt bound exactly to a quote.

This is **not** yet the full ledger / settlement / refund subsystem.

## New private tables

- `checkout_quotes`
- `checkout_quote_lines`
- `payment_authorizations`
- `payment_authorization_events`

All four:

- RLS enabled;
- no anon/authenticated direct CRUD;
- service-role backend only;
- quote lines and payment events are append-only.

## Quote

Authenticated RPC:

```text
tc_quote_checkout(
  p_client_profile_public_id text,
  p_destination_type text,
  p_destination_id text,
  p_items jsonb,
  p_idempotency_key text
)
```

Input item supports:

```json
{
  "variant_public_id": "VAR-...",
  "quantity": 1
}
```

for automatic sourcing, or:

```json
{
  "variant_public_id": "VAR-...",
  "seller_profile_public_id": "TIE-...",
  "quantity": 1
}
```

or an explicit `listing_public_id` for exact-offer choice.

Quote DOES NOT reserve inventory.

Automatic source policy V1:

1. eligible verified + active + network-enabled STORE_PICKUP source;
2. source must have structurally valid path to checkout destination network entry;
3. enough available committed inventory;
4. same community first;
5. same municipality;
6. same department;
7. outside territory;
8. lower price inside the same territorial tier;
9. stable listing ID tie-break.

Trip availability is deliberately excluded from quote eligibility:

```text
NO_TRIP_NOW != DEAD_END
```

Structural reachability is required; a currently published TRIP is not.

Quote output includes:

```text
source_mode
seller_display_name
sold_by_label = "Vendido por"
unit price
quantity
total
payment_required = true
inventory_reserved = false
```

## Payment authorization receipt

Service-only RPC:

```text
tc_record_checkout_payment_authorization(...)
```

It may be called only by a trusted payment-provider adapter.

It verifies:

- quote exists and is OPEN;
- amount = quote total;
- currency = quote currency;
- authorization has not already expired;
- provider authorization reference is not reused across a different quote.

It records:

```text
PAY-*
state = AUTHORIZED
payment_authorization_events.AUTHORIZED
```

It does not contact a provider.

## Checkout commit

Authenticated RPC:

```text
tc_commit_checkout(
  p_quote_public_id text,
  p_payment_public_id text,
  p_idempotency_key text
)
```

Before any inventory reservation it verifies:

- authenticated active CLI;
- quote belongs to active CLI;
- PAY belongs to exact quote/client;
- PAY amount/currency exact;
- PAY state usable;
- PAY unused and unexpired;
- listing still active;
- seller still active/open;
- price unchanged;
- variant still active;
- source NODE still verified/network-enabled;
- enough committed inventory;
- structural path still exists.

On stale quote:

```text
TC_QUOTE_STALE_REQUOTE_REQUIRED
```

and atomically:

```text
NO order
NO inventory reservation
PAY remains unconsumed
quote remains OPEN
```

On success:

```text
order
→ order_demand_items
→ tc_source_allocate_reserve()
→ sub_orders/order_items
→ inventory reservation
```

No PKG is created at checkout.

The payment authorization is linked to the committed order only after all source reservations succeed in the same transaction.

## Preparation / logistics handoff

Existing + newly completed path:

```text
tc_start_preparation()
→ PKG CREATED + package_contents

tc_complete_package_preparation()
→ inventory reservation CONSUMED
→ sourcing allocation FULFILLED
→ commercial demand FULFILLED/PARTIAL
→ PKG READY
→ logistics demand
→ READY_FOR_ROUTING
→ DEMAND_ROUTABLE outbox
→ existing runtime
```

## Full paid-checkout E2E verification — ROLLBACK

Verified:

```text
active CLI
→ quote AUTO_SELECTED
→ inventory_reserved = 0
→ PAY AUTHORIZED
→ inventory_reserved = 0
→ commit checkout
→ inventory_reserved = 1
→ order_demand_items = 1
→ sub_orders = 1
→ packages = 0
→ payment linked to order
→ quote COMMITTED
→ active TIE
→ start preparation
→ PKG CREATED
→ complete preparation
→ inventory CONSUMED
→ PKG READY
→ LGD READY_FOR_ROUTING
→ DEMAND_ROUTABLE outbox
→ runtime process
→ structural_reachable = true
→ NO_TRIP_NOW = true
```

## Negative verification — ROLLBACK

Verified:

```text
wrong payment amount
→ TC_PAYMENT_AMOUNT_MISMATCH

stale source after PAY authorization
→ TC_QUOTE_STALE_REQUOTE_REQUIRED

after stale failure:
PAY order_id = NULL
PAY committed_at = NULL
quote status = OPEN
persistent order count unchanged

wrong active profile for commit
→ TC_ACTIVE_PROFILE_TYPE_MISMATCH
```

## Persistent state after tests

```text
orders                       2
sub_orders                   4
packages                     4
checkout_quotes              0
checkout_quote_lines         0
payment_authorizations       0
payment_authorization_events 0
logistics_demands            0
logistics_trips              0
movements                    0
active_profile_contexts      0
active_profile_events        0
```

No test fixture persisted.

## Security surface

Authenticated bridge/checkout RPCs introduced:

- `tc_complete_package_preparation`
- `tc_quote_checkout`
- `tc_commit_checkout`

Provider / internal helpers remain service-only.

All new SECURITY DEFINER functions use explicit empty search_path.

Latest Advisor after checkout work:

```text
anon SECURITY DEFINER executable          10 WARN
authenticated SECURITY DEFINER executable 140 WARN
leaked password protection disabled        1 WARN
performance non-INFO                       0
```

The anon warning count did not increase.

## Migrations

STAGING migration count after this block: **198**

Checkout migrations:

- `20260922142423_checkout_payment_authorization_foundation_v1.sql`
- `20260922142552_checkout_quote_source_selection_v1.sql`
- `20260922142740_checkout_payment_commit_v1.sql`

All three were copied from STAGING migration history and verified byte-for-byte against GitHub.

Earlier commerce→logistics bridge migrations remain:

- `20260922134743_client_order_logistics_bridge_v1.sql`
- `20260922134947_client_order_logistics_bridge_uuid_fix_v1.sql`
- `20260922135529_client_order_logistics_bridge_surface_hardening_v1.sql`

## Remaining external dependency

A real checkout cannot capture/authorize actual money until a payment provider/rail is chosen.

The backend boundary is ready:

```text
Provider / trusted adapter
→ tc_record_checkout_payment_authorization()
→ PAY AUTHORIZED
→ client tc_commit_checkout()
```

No provider-specific assumption has been baked into the database.

## Final backend status

```text
SOURCE MODE C:                         PASS
SELLER INDEPENDENT ATTRIBUTION:        PASS
QUOTE WITHOUT INVENTORY RESERVATION:   PASS
PAYMENT-BEFORE-RESERVATION:            PASS
PAY AMOUNT/CURRENCY BINDING:           PASS
STALE QUOTE FAIL-CLOSED:               PASS
CANONICAL COMMERCIAL DEMAND CREATION:  PASS
ATOMIC INVENTORY RESERVATION:          PASS
PREPARATION→PKG:                       PASS
PKG→LOGISTICS_DEMAND:                  PASS
RUNTIME HANDOFF:                       PASS
TEST DATA ROLLBACK:                    PASS
MIGRATION PARITY:                      PASS

REAL PAYMENT PROVIDER INTEGRATION:     EXTERNAL DEPENDENCY / NOT SELECTED
FLUTTERFLOW CHECKOUT WIRING:           HANDOFF REQUIRED
```

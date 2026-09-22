# TU COMUNIDAD — PAYMENT / ORDER REQUIREMENTS CONTRACT AUDIT

**Date:** 2026-09-22  
**Mode:** audit after authorized compensation only  
**Supabase STAGING:** `ckvwfeljoonwhzmtrmnw`  
**Backend branch:** `tc/full-build-20260918`  
**Production / merge / deploy:** NOT TOUCHED

## 1. Canonical rules used by this audit

Current Lucas rules:

```text
FIADO does not exist in TU COMUNIDAD.

PAID / PAYMENT REQUIREMENT SATISFIED
→ service may proceed.

NOT PAID
→ no service.

Private agreements outside TC
→ no FIADO / sponsor / who-helped / who-advanced-money relationship inside TC.

Buyer provides:
- order/items
- payment method through the payment rail
- delivery/destination information
- required contact information

Order proceeds only after its requirements are satisfied.

All stores/vendors/providers/transport participants remain independent.

For a seller source shown to the client:
Vendido por: <independent seller name>
```

Existing project rules retained:

- commercial source commitment happens before the order;
- no normal ORDER → STORE ACCEPT/REJECT step;
- inventory reservation is atomic;
- ORDER DEMAND → SOURCING → ORDER ITEM → INVENTORY RESERVATION → PREPARATION → PKG;
- payment is a requirements gate when the source operation requires payment;
- LOGISTICS_DEMAND is not payment, order, PKG or custody;
- no financial history deletion; future refunds/adjustments must be compensating records.

## 2. Unauthorized implementation correction

The following STAGING migrations were applied without authorization:

```text
20260922155258_store_financial_methods_multi_payer_foundation_v1
20260922155428_store_payment_assumption_request_v1
```

They introduced concepts including:

```text
STORE_SPONSOR
payer_kind
payer_profile_id
store_funding_method_id
store_payment_assumption_requests
payment_authorization_coverages
store financial funding/settlement methods
physical payment acceptance methods
```

All introduced tables contained **0 rows**.

Compensating migration applied:

```text
20260922163405_revert_unauthorized_store_payment_extensions_v1
```

Verified final state:

```text
store_financial_methods                 ABSENT
store_payment_acceptance_methods        ABSENT
payment_authorization_coverages         ABSENT
store_payment_assumption_requests       ABSENT
public_store_payment_acceptance         ABSENT

tc_record_store_financial_method        ABSENT
tc_store_set_physical_payment_method    ABSENT
tc_store_assume_payment                 ABSENT

payment_authorizations.payer_profile_id ABSENT
payment_authorizations.payer_kind       ABSENT
payment_authorizations.store_funding_method_id ABSENT

payment_authorizations_order_id_key     RESTORED
```

The three historical migrations are stored byte-for-byte in GitHub so replay/audit history remains exact. The final schema does not retain the unauthorized model.

## 3. Current canonical checkout chain

LIVE canonical path:

```text
tc_quote_checkout
→ QTE + source plan
→ no inventory reservation

trusted provider adapter
→ tc_record_checkout_payment_authorization
→ PAY

tc_commit_checkout
→ revalidate price/source/network/payment
→ ORD
→ order_demand_items
→ tc_source_allocate_reserve
→ sub_orders / order_items
→ inventory RESERVED

tc_start_preparation
→ PKG CREATED

tc_complete_package_preparation
→ inventory CONSUMED
→ commercial demand fulfilled
→ PKG READY
→ LGD READY_FOR_ROUTING
→ runtime
```

## 4. Contract matrix

### A. FIADO / private credit relationship

```text
STATUS: PASS
```

Final LIVE model has no:

- FIADO;
- PAY_LATER;
- STORE_SPONSOR;
- who-advanced-money;
- store/client private debt relationship.

### B. Buyer remains order owner

```text
STATUS: PASS
```

`checkout_quotes.client_profile_id`, `orders.client_profile_id` and `payment_authorizations.client_profile_id` remain anchored to the client/buyer checkout contract.

No alternate payer role was retained.

### C. Payment before canonical sourcing/reservation

```text
STATUS: PASS, with payment-state caveat below
```

`tc_quote_checkout()` creates no reservation.

`tc_commit_checkout()` validates the PAY object before creating the order demand and calling `tc_source_allocate_reserve()`.

A stale source/price/network fails before source reservation.

### D. Multi-store order

```text
STATUS: PASS
```

One quote may contain multiple quote lines pointing to independent sources.

One order may create multiple commercial demand/source allocations/sub-orders.

Payment requirement is evaluated against the total quote, not separately as a private debt relationship per seller.

### E. Independent seller attribution

```text
STATUS: FUNCTIONALLY PASS / CLIENT PAYLOAD HARDENING RECOMMENDED
```

Quote output returns:

```text
sold_by_label = "Vendido por"
seller_display_name
```

Internal quote lines preserve source identity needed for sourcing.

However the authenticated quote JSON also currently returns internal/source fields such as:

```text
store_profile_id
store_profile_public_id
source_operational_location_id
listing_id
variant_id
source_mode
```

The UI can hide these, but if "solo aparecer como Vendido por" is intended as a minimum-data API rule, the response should later be sanitized so the client receives only fields actually needed for display/selection.

No change made in this audit.

### F. Delivery / contact

```text
STATUS: PARTIAL PASS
```

HOME orders use an owned active `customer_locations` record and freeze a private destination snapshot containing:

- typed territory;
- location data;
- access instructions;
- authorized contact;
- safe-location data;
- recipient name;
- recipient phone.

PTC checkout validates a real active PTC operational node.

Current checkout contract represents the delivery choice primarily as:

```text
destination_type = HOME | PTC
destination_id
```

There is not yet a separate general `delivery_method` / order-level contact preference object. This is not necessarily wrong, but it should not be claimed as a fully generalized delivery-method contract yet.

### G. No manual store confirmation

```text
STATUS: CANONICAL PATH PASS
LEGACY SURFACE CONTRADICTION PRESENT
```

The canonical paid checkout calls `tc_source_allocate_reserve()` directly and does not require store acceptance.

However LIVE still exposes authenticated:

```text
tc_accept_sub_order(...)
```

which performs:

```text
sub_order CREATED → ACCEPTED
operation = ACCEPT_SUB_ORDER
```

That conflicts with the current rule:

```text
committed/reservable stock
→ atomic reservation
→ preparation

NO normal ORDER → STORE ACCEPT/REJECT
```

It appears to be legacy compatibility debt, not part of the canonical checkout.

No change made in this audit.

### H. Universal payment gate

```text
STATUS: FAIL because legacy bypass remains
```

LIVE still contains service-role-only:

```text
execute_checkout(...)
```

That legacy RPC directly creates:

- order;
- sub-orders;
- packages;
- order items;
- inventory reservations;

without requiring a `PAY-*`.

It also creates PKG at checkout rather than during preparation.

Therefore the database still has a privileged path capable of violating:

```text
PAYMENT SATISFIED → SERVICE
NO PAYMENT        → NO SERVICE
```

and:

```text
... INVENTORY RESERVATION
→ PREPARATION
→ PKG BIRTH
```

The function is not executable by anon/authenticated, but service_role can execute it. It should therefore be treated as a legacy bypass that must be disabled/deprecated or explicitly fenced before production.

No change made in this audit.

### I. Meaning of "paid"

```text
STATUS: CONTRACT NOT FULLY CLOSED
```

`tc_commit_checkout()` currently accepts payment states:

```text
AUTHORIZED
CAPTURED
HELD
```

and `tc_record_checkout_payment_authorization()` creates:

```text
state = AUTHORIZED
```

The latest business rule says:

```text
se cobra el pedido antes de procesar
pago confirmado → servicio
```

The current generic state model does not yet define whether provider `AUTHORIZED` always means funds are sufficiently secured to satisfy that rule.

Before production, the financial contract should define one canonical predicate such as:

```text
PAYMENT_REQUIREMENT_SATISFIED
```

mapped per payment rail to the provider state that actually guarantees/securely commits the funds.

Do not assume every provider's AUTHORIZED/HELD/CAPTURED semantics are interchangeable.

### J. Physical-store accepted payment methods

```text
STATUS: VALID REQUIREMENT, NOT IMPLEMENTED
```

Lucas clarified that a client may see what an independent store accepts at the physical store.

This is informational and separate from TC checkout/payment processing.

The unauthorized implementation attempted to add this together with STORE_SPONSOR/funding concepts. It was reverted entirely.

If implemented later, it should be a narrow independent store capability/display contract and must not imply that TU COMUNIDAD owns, controls or can debit those methods.

### K. Settlement to independent sellers

```text
STATUS: NOT IMPLEMENTED
```

Current LIVE checkout records payment authorization but does not yet provide the complete canonical:

```text
SET-*
REF-*
BAL-*
sum-zero ledger
seller settlement
transport/PTC/RSG settlement
refund/reversal compensating entries
```

Therefore:

```text
CLIENT PAYMENT / ORDER GATE
```

is much further along than:

```text
POST-ORDER FINANCIAL SETTLEMENT
```

Do not claim complete financial E2E until this bounded context exists.

### L. FX / cross-currency

```text
STATUS: NOT IMPLEMENTED
```

Current quote/PAY commit expects payment currency to equal quote currency.

That is safe for same-currency rails, including a GTQ-native rail.

It does not yet support a formal:

```text
ORDER GTQ
→ FX quote
→ PAYMENT USD
```

contract.

### M. FlutterFlow checkout

```text
STATUS: NOT WIRED
```

The previously inspected exported `ShoppingCartLogistics` button still navigates to order tracking rather than proving a live:

```text
quote → provider payment → PAY → commit
```

flow.

Backend contract readiness is not equivalent to live client E2E.

## 5. Security state after compensation

Unauthorized objects removed.

New canonical checkout/payment tables have no direct anon/authenticated CRUD grants.

Advisor:

```text
anon SECURITY DEFINER executable          10 WARN
authenticated SECURITY DEFINER executable 140 WARN
leaked password protection disabled        1 WARN
performance non-INFO                       0
```

No new security ERROR was introduced by the compensating migration.

## 6. Priority findings

### P0 before production

1. Remove/fence legacy `execute_checkout()` as a payment-bypass path.
2. Retire/fence `tc_accept_sub_order()` from the canonical path.
3. Close exact semantics of `PAYMENT_REQUIREMENT_SATISFIED` per payment rail.

### P1

4. Sanitize client-facing quote payload if "Vendido por" is also a minimum-data API requirement.
5. Finish settlement/ledger/refund bounded context.
6. Define/store physical-store accepted methods as a separate informational capability if desired.
7. Add FX contract only when a cross-currency rail is actually selected.
8. Wire FlutterFlow checkout after payment provider selection.

## 7. Final audit verdict

```text
UNAUTHORIZED_STORE_PAYMENT_MODEL_REMOVED: PASS
MIGRATION_HISTORY_PRESERVED:              PASS
FIADO_ABSENT_FROM_FINAL_MODEL:             PASS
BUYER_ORDER_OWNERSHIP:                     PASS
MULTI_STORE_CHECKOUT:                      PASS
PAYMENT_BEFORE_CANONICAL_RESERVATION:      PASS
PREPARATION_BEFORE_CANONICAL_PKG_BIRTH:    PASS
SELLER_INDEPENDENCE:                       PASS
HOME_DESTINATION_PRIVATE_SNAPSHOT:         PASS

UNIVERSAL_PAYMENT_GATE:                    FAIL (legacy execute_checkout bypass)
NO_MANUAL_STORE_ACCEPTANCE:                PARTIAL (legacy tc_accept_sub_order remains)
PAYMENT_SATISFIED_SEMANTICS:               UNRESOLVED
CLIENT_QUOTE_MINIMUM_DATA:                 REVIEW/HARDEN
SELLER_SETTLEMENT_LEDGER:                  MISSING
PHYSICAL_STORE_PAYMENT_DISPLAY:            MISSING
FX CONTRACT:                               MISSING
FLUTTERFLOW_PAID_CHECKOUT_E2E:             NOT PROVEN
```

No additional product contract was modified during this audit beyond the explicitly authorized compensation of the two unauthorized migrations.

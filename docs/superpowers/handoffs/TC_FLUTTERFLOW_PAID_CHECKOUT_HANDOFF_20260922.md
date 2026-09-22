# TU COMUNIDAD — FLUTTERFLOW PAID CHECKOUT HANDOFF

**Date:** 2026-09-22  
**FlutterFlow project:** Tu Comunidad  
**Project ID:** `vkA5Csj2d0821I0SB15t`  
**Working branch:** `fix-issues-sep06`  
**Supabase STAGING:** `ckvwfeljoonwhzmtrmnw`

## Backend ready

After one FlutterFlow **Update Schema**, the app should discover:

### Authenticated client RPCs

```text
tc_quote_checkout(
  p_client_profile_public_id text,
  p_destination_type text,
  p_destination_id text,
  p_items jsonb,
  p_idempotency_key text
) → jsonb

tc_commit_checkout(
  p_quote_public_id text,
  p_payment_public_id text,
  p_idempotency_key text
) → jsonb
```

### Authenticated store/VEN preparation RPC

```text
tc_complete_package_preparation(
  p_package_public_id text,
  p_idempotency_key text
) → jsonb
```

## DO NOT expose to FlutterFlow client

```text
tc_record_checkout_payment_authorization
tc_inv_consume
tc_checkout_destination_context
tc_quote_structural_path_exists
tc_ensure_operational_node_destination_version
tc_ensure_client_order_destination_contract
tc_materialize_client_order_logistics_demand
tc_publish_ready_package_to_logistics
```

These are internal/service boundaries.

## ShoppingCartLogistics

Current exported snapshot has:

```text
Confirmar Pedido y Ruta
→ navigate OrderTracking
```

That must NOT remain the canonical checkout action.

Target flow:

```text
Cart
→ build item JSON
→ tc_quote_checkout
→ display quote
→ external payment flow
→ receive PAY-* from trusted adapter
→ tc_commit_checkout
→ on success navigate OrderTracking
```

Navigation must happen only after commit success.

## Item source mode C

Automatic:

```json
{
  "variant_public_id": "VAR-...",
  "quantity": 2
}
```

Specific seller:

```json
{
  "variant_public_id": "VAR-...",
  "seller_profile_public_id": "TIE-...",
  "quantity": 2
}
```

Specific exact offer:

```json
{
  "listing_public_id": "LST-...",
  "quantity": 2
}
```

## Seller UI contract

Do not represent source as TU COMUNIDAD-owned inventory.

Show:

```text
Vendido por: <seller_display_name>
```

The quote output already returns:

```text
sold_by_label
seller_display_name
source_mode
```

## Payment ordering

Do not call `tc_commit_checkout` before the external provider adapter has produced a valid `PAY-*`.

Expected:

```text
quote
→ pay authorization
→ PAY-*
→ commit
```

If payment fails:
- no commit;
- no inventory reservation;
- no PKG;
- no LGD.

If commit returns:

```text
TC_QUOTE_STALE_REQUOTE_REQUIRED
```

discard/reload the displayed quote and request a new quote. Do not retry the old amount against another source silently.

## Successful commit output

Contains:

```text
order_public_id
payment_public_id
quote_public_id
order_demand_count
sub_order_count
total_minor
currency
inventory_reserved = true
package_count = 0
```

The absence of PKG at checkout is intentional.

## Store preparation

When source begins work:

```text
tc_start_preparation(...)
→ PKG CREATED
```

When physically prepared:

```text
tc_complete_package_preparation(PKG,...)
→ PKG READY
→ inventory CONSUMED
→ LGD READY_FOR_ROUTING
```

No per-order manual store ACCEPT step should be added to the new canonical flow.

## Payment provider dependency

FlutterFlow must not fake PAY authorization.

A trusted provider integration must call service-only:

```text
tc_record_checkout_payment_authorization(...)
```

and return only the resulting `PAY-*`/safe status to the client.

Provider choice is not yet canonical.

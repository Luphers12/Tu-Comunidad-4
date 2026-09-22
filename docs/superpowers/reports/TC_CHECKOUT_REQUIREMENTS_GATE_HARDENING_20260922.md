# TU COMUNIDAD — CHECKOUT REQUIREMENTS GATE HARDENING

**Date:** 2026-09-22  
**Authorization:** Lucas approved decisions 1/2/3 explicitly.  
**Supabase:** STAGING `ckvwfeljoonwhzmtrmnw`  
**Backend branch:** `tc/full-build-20260918`  
**Production / merge / deploy:** NOT TOUCHED

## Canonical decisions implemented

### 1. Legacy checkout retired

`public.execute_checkout(text,text,text,jsonb,text)`

- replaced with a fail-closed stub;
- EXECUTE revoked from anon, authenticated and service_role;
- calling it raises:

```text
TC_LEGACY_CHECKOUT_RETIRED_USE_QUOTE_PAYMENT_COMMIT
```

Canonical path is now:

```text
tc_quote_checkout
→ trusted payment adapter
→ payment requirement satisfied
→ tc_commit_checkout
```

The legacy path can no longer create an order, reserve stock, or create PKG without the canonical payment gate.

### 2. Manual store acceptance retired

`public.tc_accept_sub_order(text,text)`

- replaced with a fail-closed stub;
- EXECUTE revoked from anon, authenticated and service_role;
- calling it raises:

```text
TC_MANUAL_SUB_ORDER_ACCEPTANCE_RETIRED
```

Canonical sourcing remains:

```text
pre-committed availability
→ atomic source allocation/reservation
→ preparation
```

There is no normal per-order store accept/reject step.

### 3. Provider-independent payment requirement

Added to `payment_authorizations`:

```text
payment_requirement_satisfied boolean NOT NULL DEFAULT false
payment_requirement_satisfied_at timestamptz
payment_requirement_basis text
payment_requirement_provider_event_ref text
```

A provider state name alone does not satisfy checkout.

`tc_commit_checkout()` now gates on:

```text
payment_requirement_satisfied = true
AND
payment_requirement_satisfied_at IS NOT NULL
```

and raises:

```text
TC_PAYMENT_REQUIREMENT_NOT_SATISFIED
```

otherwise.

The previous generic condition:

```text
state IN (AUTHORIZED, CAPTURED, HELD)
```

was removed from `tc_commit_checkout()`.

### Trusted adapter boundary

New service-role-only function:

```text
tc_mark_checkout_payment_requirement_satisfied(...)
```

It requires an explicit evidence/basis from the trusted payment adapter and appends:

```text
PAYMENT_REQUIREMENT_SATISFIED
```

to `payment_authorization_events`.

Anon/authenticated cannot call it.

A table trigger also prevents binding a PAY to an order when the payment requirement is not satisfied.

## Migration

```text
20260922171233_checkout_requirements_gate_hardening_v1
```

Migration count after application:

```text
202
```

GitHub migration is byte-for-byte equal to STAGING.

Commit:

```text
0f9c648f43bf58f0d22f2121b3f2f1a21bc21ac8
```

## Rollback-only verification

Test proved:

1. a newly recorded `AUTHORIZED` PAY has `payment_requirement_satisfied=false`;
2. `tc_commit_checkout()` rejects it with `TC_PAYMENT_REQUIREMENT_NOT_SATISFIED`;
3. the failed attempt creates no persistent order;
4. trusted payment evidence marks the requirement satisfied;
5. the second trusted mark is idempotent and creates no duplicate evidence event;
6. after payment satisfaction, checkout advances to the next independent requirement;
7. legacy `execute_checkout()` is fail-closed;
8. manual `tc_accept_sub_order()` is fail-closed.

Persistent counts after rollback:

```text
orders          2
checkout_quotes 0
payments        0
active_contexts 0
```

## Security advisor after change

```text
anon SECURITY DEFINER executable          10 WARN
authenticated SECURITY DEFINER executable 139 WARN
leaked password protection                1 WARN
performance non-INFO                      0
```

Authenticated SECURITY DEFINER count decreased from 140 to 139 because manual sub-order acceptance is no longer exposed.

## Canonical business rule

```text
BUYER
→ order requirements
→ payment method
→ payment rail verifies sufficient funds
→ PAYMENT_REQUIREMENT_SATISFIED
→ sourcing/reservation
→ preparation
→ PKG
→ logistics

NO PAYMENT REQUIREMENT SATISFIED
→ NO SERVICE
```

Private arrangements between a customer and any independent store remain outside TU COMUNIDAD and do not create FIADO, sponsor, lender, who-helped, or who-advanced-money records in the order model.

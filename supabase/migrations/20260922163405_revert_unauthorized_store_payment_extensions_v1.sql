
-- TU COMUNIDAD — REVERT UNAUTHORIZED STORE PAYMENT EXTENSIONS V1
-- Compensating forward migration for:
-- 20260922155258_store_financial_methods_multi_payer_foundation_v1
-- 20260922155428_store_payment_assumption_request_v1
--
-- Canonical correction:
-- no STORE_SPONSOR / payment assumption / fiado-related relationship is modeled
-- inside TU COMUNIDAD. Buyer/order/payment requirements remain the checkout contract.

drop function if exists public.tc_store_assume_payment(text,text,text);
drop function if exists public.tc_store_set_physical_payment_method(text,text,boolean);
drop function if exists public.tc_record_store_financial_method(
  text,text,text,text,text,text,text,boolean,bigint,bigint
);

drop view if exists public.public_store_payment_acceptance;

drop table if exists public.store_payment_assumption_requests;
drop table if exists public.payment_authorization_coverages;

alter table public.payment_authorizations
  drop constraint if exists payment_authorizations_payer_shape_check,
  drop constraint if exists payment_authorizations_payer_kind_check,
  drop constraint if exists payment_authorizations_payer_profile_id_fkey,
  drop constraint if exists payment_authorizations_store_funding_method_id_fkey;

alter table public.payment_authorizations
  drop column if exists store_funding_method_id,
  drop column if exists payer_kind,
  drop column if exists payer_profile_id;

drop table if exists public.store_payment_acceptance_methods;
drop table if exists public.store_financial_methods;

alter table public.payment_authorizations
  add constraint payment_authorizations_order_id_key unique(order_id);

comment on table public.payment_authorizations is
'Provider-agnostic trusted payment authorization receipt (PAY-*), bound to the client checkout quote/order contract. No fiado, store sponsor, private credit relationship, or who-advanced-money relationship is modeled in TU COMUNIDAD.';

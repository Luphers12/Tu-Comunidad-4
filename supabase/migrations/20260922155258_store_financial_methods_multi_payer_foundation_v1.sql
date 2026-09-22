
-- TU COMUNIDAD — STORE FINANCIAL METHODS + MULTI-PAYER CHECKOUT FOUNDATION V1
-- No FIADO state exists. Service requires authorized payment coverage.
-- A store may sponsor only its own quote lines, using an explicitly configured TC funding method.

create table public.store_financial_methods (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('FNM'),
  store_profile_id uuid not null references public.profiles(id) on delete restrict,
  purpose text not null check (purpose in ('TC_SETTLEMENT','TC_FUNDING')),
  provider_code text not null,
  provider_method_ref text not null,
  currency varchar(3) not null,
  display_label text not null,
  state text not null default 'ACTIVE'
    check (state in ('PENDING_VERIFICATION','ACTIVE','SUSPENDED','REVOKED')),
  debit_mandate_ref text,
  debit_authorized boolean not null default false,
  max_per_transaction_minor bigint check (max_per_transaction_minor is null or max_per_transaction_minor > 0),
  max_daily_minor bigint check (max_daily_minor is null or max_daily_minor > 0),
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (public_id like 'FNM-%'),
  check (currency ~ '^[A-Z]{3}$'),
  check (btrim(provider_code) <> ''),
  check (btrim(provider_method_ref) <> ''),
  check (btrim(display_label) <> ''),
  check (
    purpose<>'TC_FUNDING'
    or not debit_authorized
    or nullif(btrim(coalesce(debit_mandate_ref,'')),'') is not null
  ),
  unique(store_profile_id,purpose,provider_code,provider_method_ref)
);

create table public.store_payment_acceptance_methods (
  id uuid primary key default gen_random_uuid(),
  store_profile_id uuid not null references public.profiles(id) on delete cascade,
  method_code text not null,
  display_label text not null,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (btrim(method_code) <> ''),
  check (btrim(display_label) <> ''),
  unique(store_profile_id,method_code)
);

alter table public.payment_authorizations
  add column payer_profile_id uuid references public.profiles(id) on delete restrict,
  add column payer_kind text,
  add column store_funding_method_id uuid references public.store_financial_methods(id) on delete restrict;

alter table public.payment_authorizations
  add constraint payment_authorizations_payer_kind_check
  check (payer_kind in ('CLIENT','STORE_SPONSOR'));

alter table public.payment_authorizations
  add constraint payment_authorizations_payer_shape_check
  check (
    (payer_kind='CLIENT' and store_funding_method_id is null)
    or
    (payer_kind='STORE_SPONSOR' and store_funding_method_id is not null)
  );

alter table public.payment_authorizations
  drop constraint payment_authorizations_order_id_key;

alter table public.payment_authorizations
  alter column payer_profile_id set not null,
  alter column payer_kind set not null;

create table public.payment_authorization_coverages (
  id uuid primary key default gen_random_uuid(),
  authorization_id uuid not null references public.payment_authorizations(id) on delete restrict,
  quote_line_id uuid not null references public.checkout_quote_lines(id) on delete restrict,
  amount_minor bigint not null check (amount_minor > 0),
  created_at timestamptz not null default now(),
  unique(authorization_id,quote_line_id)
);

create index store_financial_methods_store_purpose_idx
  on public.store_financial_methods(store_profile_id,purpose,state);
create index store_payment_acceptance_store_idx
  on public.store_payment_acceptance_methods(store_profile_id,active);
create index payment_authorizations_payer_idx
  on public.payment_authorizations(payer_profile_id,payer_kind,state);
create index payment_authorization_coverages_line_idx
  on public.payment_authorization_coverages(quote_line_id);
create index payment_authorization_coverages_auth_idx
  on public.payment_authorization_coverages(authorization_id);

create trigger store_financial_methods_set_updated_at
before update on public.store_financial_methods
for each row execute function public.tc_set_updated_at();

create trigger store_payment_acceptance_methods_set_updated_at
before update on public.store_payment_acceptance_methods
for each row execute function public.tc_set_updated_at();

create trigger payment_authorization_coverages_append_only
before update or delete on public.payment_authorization_coverages
for each row execute function public.tc_guard_logistics_append_only();

alter table public.store_financial_methods enable row level security;
alter table public.store_payment_acceptance_methods enable row level security;
alter table public.payment_authorization_coverages enable row level security;

revoke all on public.store_financial_methods from public,anon,authenticated;
revoke all on public.store_payment_acceptance_methods from public,anon,authenticated;
revoke all on public.payment_authorization_coverages from public,anon,authenticated;

grant select,insert,update on public.store_financial_methods to service_role;
grant select,insert,update on public.store_payment_acceptance_methods to service_role;
grant select,insert on public.payment_authorization_coverages to service_role;

create or replace view public.public_store_payment_acceptance
with (security_invoker=true)
as
select
  sd.store_public_id,
  m.method_code,
  m.display_label
from public.store_payment_acceptance_methods m
join public.store_directory sd on sd.store_profile_id=m.store_profile_id
where m.active
  and sd.is_active;

revoke all on public.public_store_payment_acceptance from public;
grant select on public.public_store_payment_acceptance to anon,authenticated;

create policy store_payment_acceptance_public_read
on public.store_payment_acceptance_methods
for select
to anon,authenticated
using (
  active
  and exists(
    select 1
    from public.store_directory sd
    where sd.store_profile_id=store_payment_acceptance_methods.store_profile_id
      and sd.is_active
  )
);

comment on table public.store_payment_acceptance_methods is
'Public informational methods accepted by an independent store at its physical business (e.g. CASH, RAPIPOS, CARD). These do not authorize TU COMUNIDAD to charge or settle money.';

comment on table public.store_financial_methods is
'Private financial relationship between an independent store and TU COMUNIDAD. TC_SETTLEMENT = where TC may pay the store. TC_FUNDING = provider-tokenized method TC may debit only under an explicit mandate. Never store raw bank/card credentials here.';

comment on table public.payment_authorization_coverages is
'Append-only allocation of authorized PAY amount to exact checkout quote lines. CLIENT PAY may cover any line; STORE_SPONSOR PAY may cover only quote lines sold by that store. A checkout may commit only when every line is fully covered exactly once in aggregate.';

comment on column public.payment_authorizations.payer_kind is
'CLIENT or STORE_SPONSOR. There is no FIADO/CREDIT/PAY_LATER state in TU COMUNIDAD. STORE_SPONSOR means the independent store assumed payment responsibility and TC obtained authorized funds from the store funding method.';

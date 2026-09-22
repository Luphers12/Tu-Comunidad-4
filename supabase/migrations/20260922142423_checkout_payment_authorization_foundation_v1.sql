
-- TU COMUNIDAD — CHECKOUT QUOTE + PAYMENT AUTHORIZATION FOUNDATION V1
-- Provider-agnostic financial gate. This is NOT the ledger/settlement/refund subsystem.

create table public.checkout_quotes (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('QTE'),
  client_profile_id uuid not null references public.profiles(id) on delete restrict,
  destination_type text not null,
  destination_id text not null,
  currency varchar(3) not null,
  total_minor bigint not null check (total_minor >= 0),
  status text not null default 'OPEN'
    check (status in ('OPEN','COMMITTED','CANCELLED')),
  request_hash text not null,
  committed_order_id uuid unique references public.orders(id) on delete restrict,
  created_at timestamptz not null default now(),
  committed_at timestamptz,
  updated_at timestamptz not null default now(),
  check (public_id like 'QTE-%'),
  check (currency ~ '^[A-Z]{3}$'),
  check (destination_type in ('HOME','PTC')),
  check (
    (status='COMMITTED' and committed_order_id is not null and committed_at is not null)
    or
    (status<>'COMMITTED' and committed_order_id is null and committed_at is null)
  )
);

create table public.checkout_quote_lines (
  id uuid primary key default gen_random_uuid(),
  quote_id uuid not null references public.checkout_quotes(id) on delete restrict,
  line_no integer not null check (line_no > 0),
  variant_id uuid not null references public.product_variants(id) on delete restrict,
  listing_id uuid not null references public.store_listings(id) on delete restrict,
  store_profile_id uuid not null references public.profiles(id) on delete restrict,
  source_operational_location_id uuid not null references public.operational_locations(id) on delete restrict,
  quantity bigint not null check (quantity > 0),
  unit_price_minor bigint not null check (unit_price_minor >= 0),
  line_total_minor bigint not null check (line_total_minor >= 0),
  source_mode text not null check (source_mode in ('CLIENT_SELECTED','AUTO_SELECTED')),
  seller_display_name text not null,
  created_at timestamptz not null default now(),
  unique(quote_id,line_no)
);

create table public.payment_authorizations (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('PAY'),
  quote_id uuid not null references public.checkout_quotes(id) on delete restrict,
  client_profile_id uuid not null references public.profiles(id) on delete restrict,
  provider_code text not null,
  provider_authorization_ref text not null,
  amount_minor bigint not null check (amount_minor >= 0),
  currency varchar(3) not null,
  state text not null default 'AUTHORIZED'
    check (state in (
      'PENDING','AUTHORIZED','CAPTURED','HELD',
      'VOIDED','EXPIRED','FAILED','REFUNDED','DISPUTED','REVERSED'
    )),
  order_id uuid unique references public.orders(id) on delete restrict,
  authorized_at timestamptz,
  expires_at timestamptz,
  committed_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (public_id like 'PAY-%'),
  check (currency ~ '^[A-Z]{3}$'),
  check (btrim(provider_code) <> ''),
  check (btrim(provider_authorization_ref) <> ''),
  check (
    state<>'AUTHORIZED'
    or authorized_at is not null
  ),
  check (
    order_id is null
    or committed_at is not null
  ),
  unique(provider_code,provider_authorization_ref)
);

create table public.payment_authorization_events (
  id uuid primary key default gen_random_uuid(),
  authorization_id uuid not null references public.payment_authorizations(id) on delete restrict,
  event_type text not null,
  provider_event_ref text,
  payload jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  check (btrim(event_type) <> '')
);

create index checkout_quotes_client_status_idx
  on public.checkout_quotes(client_profile_id,status,created_at desc);
create index checkout_quote_lines_quote_idx
  on public.checkout_quote_lines(quote_id,line_no);
create index checkout_quote_lines_listing_idx
  on public.checkout_quote_lines(listing_id);
create index payment_authorizations_quote_idx
  on public.payment_authorizations(quote_id,state);
create index payment_authorizations_client_idx
  on public.payment_authorizations(client_profile_id,state,created_at desc);
create index payment_authorization_events_auth_idx
  on public.payment_authorization_events(authorization_id,occurred_at,created_at);

create trigger checkout_quotes_set_updated_at
before update on public.checkout_quotes
for each row execute function public.tc_set_updated_at();

create trigger payment_authorizations_set_updated_at
before update on public.payment_authorizations
for each row execute function public.tc_set_updated_at();

create trigger checkout_quote_lines_append_only
before update or delete on public.checkout_quote_lines
for each row execute function public.tc_guard_logistics_append_only();

create trigger payment_authorization_events_append_only
before update or delete on public.payment_authorization_events
for each row execute function public.tc_guard_logistics_append_only();

alter table public.checkout_quotes enable row level security;
alter table public.checkout_quote_lines enable row level security;
alter table public.payment_authorizations enable row level security;
alter table public.payment_authorization_events enable row level security;

revoke all on public.checkout_quotes from public,anon,authenticated;
revoke all on public.checkout_quote_lines from public,anon,authenticated;
revoke all on public.payment_authorizations from public,anon,authenticated;
revoke all on public.payment_authorization_events from public,anon,authenticated;

grant select,insert,update on public.checkout_quotes to service_role;
grant select,insert on public.checkout_quote_lines to service_role;
grant select,insert,update on public.payment_authorizations to service_role;
grant select,insert on public.payment_authorization_events to service_role;

comment on table public.checkout_quotes is
'Immutable-price/source checkout quote envelope. Quote creation does not reserve inventory. Commit must revalidate every selected source after a trusted payment authorization exists.';

comment on table public.checkout_quote_lines is
'Append-only quote source snapshot. source_mode CLIENT_SELECTED preserves explicit seller/offer choice; AUTO_SELECTED records deterministic TC sourcing. UI should present seller attribution as "Vendido por: <seller_display_name>".';

comment on table public.payment_authorizations is
'Provider-agnostic trusted payment authorization receipt (PAY-*). This table is not the ledger, settlement or refund subsystem. Checkout requires AUTHORIZED before any inventory reservation.';

comment on table public.payment_authorization_events is
'Append-only payment authorization lifecycle evidence. Financial corrections must be represented by subsequent events/state transitions, never destructive history edits.';


-- TU COMUNIDAD — STORE PAYMENT ASSUMPTION + MULTI-PAYER CHECKOUT V1
-- No FIADO. Store assumption is a payment responsibility request backed by its authorized TC_FUNDING method.

create table public.store_payment_assumption_requests (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('SPR'),
  quote_id uuid not null references public.checkout_quotes(id) on delete restrict,
  store_profile_id uuid not null references public.profiles(id) on delete restrict,
  funding_method_id uuid not null references public.store_financial_methods(id) on delete restrict,
  amount_minor bigint not null check (amount_minor > 0),
  currency varchar(3) not null,
  state text not null default 'REQUESTED'
    check (state in ('REQUESTED','AUTHORIZED','FAILED','CANCELLED','COMMITTED')),
  idempotency_key text not null,
  requested_at timestamptz not null default now(),
  authorized_at timestamptz,
  failed_at timestamptz,
  committed_at timestamptz,
  failure_code text,
  payment_authorization_id uuid unique references public.payment_authorizations(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (public_id like 'SPR-%'),
  check (currency ~ '^[A-Z]{3}$'),
  unique(store_profile_id,idempotency_key),
  check (
    (state in ('AUTHORIZED','COMMITTED') and authorized_at is not null and payment_authorization_id is not null)
    or
    (state='FAILED' and failed_at is not null)
    or
    (state in ('REQUESTED','CANCELLED'))
  )
);

create index store_payment_assumption_quote_idx
  on public.store_payment_assumption_requests(quote_id,store_profile_id,state);
create index store_payment_assumption_funding_idx
  on public.store_payment_assumption_requests(funding_method_id,state,created_at desc);

create trigger store_payment_assumption_requests_set_updated_at
before update on public.store_payment_assumption_requests
for each row execute function public.tc_set_updated_at();

alter table public.store_payment_assumption_requests enable row level security;
revoke all on public.store_payment_assumption_requests from public,anon,authenticated;
grant select,insert,update on public.store_payment_assumption_requests to service_role;

comment on table public.store_payment_assumption_requests is
'Explicit store instruction that the store will cover its own quote lines through a configured TC_FUNDING method. This is not FIADO. Service remains blocked until the funding rail actually authorizes and produces PAY.';


create or replace function public.tc_record_store_financial_method(
  p_store_profile_public_id text,
  p_purpose text,
  p_provider_code text,
  p_provider_method_ref text,
  p_currency text,
  p_display_label text,
  p_debit_mandate_ref text default null,
  p_debit_authorized boolean default false,
  p_max_per_transaction_minor bigint default null,
  p_max_daily_minor bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_store uuid;
  v_purpose text:=upper(btrim(coalesce(p_purpose,'')));
  v_provider text:=upper(btrim(coalesce(p_provider_code,'')));
  v_method text:=btrim(coalesce(p_provider_method_ref,''));
  v_currency varchar(3):=upper(btrim(coalesce(p_currency,'')));
  v_label text:=btrim(coalesce(p_display_label,''));
  v_mandate text:=nullif(btrim(coalesce(p_debit_mandate_ref,'')),'');
  v_row public.store_financial_methods%rowtype;
begin
  select p.id into v_store
  from public.profiles p
  where p.public_id=upper(btrim(coalesce(p_store_profile_public_id,'')))
    and p.status='active'
    and p.profile_type in ('TIE','VEN')
  limit 1;

  if v_store is null then
    raise exception using errcode='P0001', message='TC_STORE_PROFILE_INVALID';
  end if;

  if v_purpose not in ('TC_SETTLEMENT','TC_FUNDING')
     or v_provider=''
     or v_method=''
     or v_label=''
     or v_currency !~ '^[A-Z]{3}$' then
    raise exception using errcode='P0001', message='TC_FINANCIAL_METHOD_INVALID';
  end if;

  if v_purpose='TC_SETTLEMENT' and p_debit_authorized then
    raise exception using errcode='P0001', message='TC_SETTLEMENT_METHOD_CANNOT_DEBIT';
  end if;

  if v_purpose='TC_FUNDING' and p_debit_authorized and v_mandate is null then
    raise exception using errcode='P0001', message='TC_FUNDING_MANDATE_REQUIRED';
  end if;

  insert into public.store_financial_methods(
    store_profile_id,purpose,provider_code,provider_method_ref,
    currency,display_label,state,debit_mandate_ref,debit_authorized,
    max_per_transaction_minor,max_daily_minor,verified_at
  ) values(
    v_store,v_purpose,v_provider,v_method,
    v_currency,v_label,'ACTIVE',v_mandate,coalesce(p_debit_authorized,false),
    p_max_per_transaction_minor,p_max_daily_minor,now()
  )
  on conflict(store_profile_id,purpose,provider_code,provider_method_ref)
  do update set
    currency=excluded.currency,
    display_label=excluded.display_label,
    state='ACTIVE',
    debit_mandate_ref=excluded.debit_mandate_ref,
    debit_authorized=excluded.debit_authorized,
    max_per_transaction_minor=excluded.max_per_transaction_minor,
    max_daily_minor=excluded.max_daily_minor,
    verified_at=now(),
    updated_at=now()
  returning * into v_row;

  return jsonb_build_object(
    'success',true,
    'financial_method_public_id',v_row.public_id,
    'purpose',v_row.purpose,
    'provider_code',v_row.provider_code,
    'currency',v_row.currency,
    'display_label',v_row.display_label,
    'state',v_row.state,
    'debit_authorized',v_row.debit_authorized
  );
end;
$function$;

revoke all on function public.tc_record_store_financial_method(
  text,text,text,text,text,text,text,boolean,bigint,bigint
) from public,anon,authenticated;
grant execute on function public.tc_record_store_financial_method(
  text,text,text,text,text,text,text,boolean,bigint,bigint
) to service_role;


create or replace function public.tc_store_set_physical_payment_method(
  p_method_code text,
  p_display_label text,
  p_active boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_active uuid;
  v_method text:=upper(btrim(coalesce(p_method_code,'')));
  v_label text:=btrim(coalesce(p_display_label,''));
begin
  if auth.uid() is null then
    raise exception using errcode='P0001', message='TC_UNAUTHENTICATED';
  end if;

  v_active:=public.tc_active_profile_id();

  if v_active is null or not exists(
    select 1 from public.profiles p
    where p.id=v_active
      and p.status='active'
      and p.profile_type in ('TIE','VEN')
  ) then
    raise exception using errcode='P0001', message='TC_ACTIVE_PROFILE_TYPE_MISMATCH';
  end if;

  if v_method='' or v_label='' then
    raise exception using errcode='P0001', message='TC_PAYMENT_ACCEPTANCE_INVALID';
  end if;

  insert into public.store_payment_acceptance_methods(
    store_profile_id,method_code,display_label,active
  ) values(
    v_active,v_method,v_label,coalesce(p_active,true)
  )
  on conflict(store_profile_id,method_code)
  do update set
    display_label=excluded.display_label,
    active=excluded.active,
    updated_at=now();

  return jsonb_build_object(
    'success',true,
    'method_code',v_method,
    'display_label',v_label,
    'active',coalesce(p_active,true)
  );
end;
$function$;

revoke all on function public.tc_store_set_physical_payment_method(text,text,boolean)
  from public,anon;
grant execute on function public.tc_store_set_physical_payment_method(text,text,boolean)
  to authenticated,service_role;


create or replace function public.tc_store_assume_payment(
  p_quote_public_id text,
  p_funding_method_public_id text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_uid uuid:=auth.uid();
  v_person uuid;
  v_active uuid;
  v_quote public.checkout_quotes%rowtype;
  v_method public.store_financial_methods%rowtype;
  v_amount bigint;
  v_covered bigint;
  v_remaining bigint;
  v_key text:=btrim(coalesce(p_idempotency_key,''));
  v_existing public.store_payment_assumption_requests%rowtype;
  v_req public.store_payment_assumption_requests%rowtype;
begin
  if v_uid is null then
    raise exception using errcode='P0001', message='TC_UNAUTHENTICATED';
  end if;

  if nullif(btrim(coalesce(p_quote_public_id,'')),'') is null
     or nullif(btrim(coalesce(p_funding_method_public_id,'')),'') is null
     or v_key='' then
    raise exception using errcode='P0001', message='TC_INVALID_ARGUMENT';
  end if;

  select per.id into v_person
  from public.persons per
  where per.auth_user_id=v_uid;

  v_active:=public.tc_active_profile_id();

  if v_person is null or v_active is null or not exists(
    select 1 from public.profiles p
    where p.id=v_active
      and p.person_id=v_person
      and p.status='active'
      and p.profile_type in ('TIE','VEN')
  ) then
    raise exception using errcode='P0001', message='TC_ACTIVE_PROFILE_TYPE_MISMATCH';
  end if;

  select * into v_quote
  from public.checkout_quotes q
  where q.public_id=upper(btrim(p_quote_public_id))
  for update;

  if v_quote.id is null or v_quote.status<>'OPEN' then
    raise exception using errcode='P0001', message='TC_CHECKOUT_QUOTE_NOT_OPEN';
  end if;

  select * into v_method
  from public.store_financial_methods m
  where m.public_id=upper(btrim(p_funding_method_public_id))
    and m.store_profile_id=v_active
    and m.purpose='TC_FUNDING'
    and m.state='ACTIVE'
    and m.debit_authorized
    and m.verified_at is not null
    and m.currency=v_quote.currency
  for update;

  if v_method.id is null then
    raise exception using errcode='P0001', message='TC_STORE_FUNDING_METHOD_NOT_AUTHORIZED';
  end if;

  select coalesce(sum(ql.line_total_minor),0)::bigint
    into v_amount
  from public.checkout_quote_lines ql
  where ql.quote_id=v_quote.id
    and ql.store_profile_id=v_active;

  if v_amount<=0 then
    raise exception using errcode='P0001', message='TC_STORE_HAS_NO_QUOTE_LINES';
  end if;

  select coalesce(sum(c.amount_minor),0)::bigint
    into v_covered
  from public.payment_authorization_coverages c
  join public.payment_authorizations pa on pa.id=c.authorization_id
  join public.checkout_quote_lines ql on ql.id=c.quote_line_id
  where ql.quote_id=v_quote.id
    and ql.store_profile_id=v_active
    and pa.state in ('AUTHORIZED','CAPTURED','HELD')
    and pa.order_id is null;

  v_remaining:=v_amount-v_covered;

  if v_remaining<=0 then
    raise exception using errcode='P0001', message='TC_STORE_LINES_ALREADY_PAID';
  end if;

  if v_method.max_per_transaction_minor is not null
     and v_remaining>v_method.max_per_transaction_minor then
    raise exception using errcode='P0001', message='TC_STORE_FUNDING_TRANSACTION_LIMIT';
  end if;

  if v_method.max_daily_minor is not null
     and (
       select coalesce(sum(pa.amount_minor),0)
       from public.payment_authorizations pa
       where pa.store_funding_method_id=v_method.id
         and pa.payer_kind='STORE_SPONSOR'
         and pa.state in ('AUTHORIZED','CAPTURED','HELD')
         and pa.created_at>=date_trunc('day',now())
     ) + v_remaining > v_method.max_daily_minor then
    raise exception using errcode='P0001', message='TC_STORE_FUNDING_DAILY_LIMIT';
  end if;

  select * into v_existing
  from public.store_payment_assumption_requests r
  where r.store_profile_id=v_active
    and r.idempotency_key=v_key
  for update;

  if v_existing.id is not null then
    if v_existing.quote_id is distinct from v_quote.id
       or v_existing.funding_method_id is distinct from v_method.id
       or v_existing.amount_minor is distinct from v_remaining then
      raise exception using errcode='P0001', message='TC_IDEMPOTENCY_KEY_REUSED';
    end if;

    return jsonb_build_object(
      'success',true,
      'disposition','IDEMPOTENT',
      'request_public_id',v_existing.public_id,
      'state',v_existing.state,
      'amount_minor',v_existing.amount_minor,
      'currency',v_existing.currency,
      'funding_method_public_id',v_method.public_id
    );
  end if;

  insert into public.store_payment_assumption_requests(
    quote_id,store_profile_id,funding_method_id,
    amount_minor,currency,state,idempotency_key
  ) values(
    v_quote.id,v_active,v_method.id,
    v_remaining,v_quote.currency,'REQUESTED',v_key
  )
  returning * into v_req;

  insert into public.audit_logs(
    actor_person_id,actor_profile_id,operation,entity_type,
    entity_public_id,result,metadata
  ) values(
    v_person,v_active,
    'STORE_ASSUME_PAYMENT',
    'STORE_PAYMENT_ASSUMPTION',
    v_req.public_id,
    'REQUESTED',
    jsonb_build_object(
      'quote_public_id',v_quote.public_id,
      'funding_method_public_id',v_method.public_id,
      'amount_minor',v_remaining,
      'currency',v_quote.currency
    )
  );

  return jsonb_build_object(
    'success',true,
    'disposition','APPLIED',
    'request_public_id',v_req.public_id,
    'state','REQUESTED',
    'amount_minor',v_remaining,
    'currency',v_quote.currency,
    'funding_method_public_id',v_method.public_id,
    'service_available',false,
    'reason','AWAITING_FUNDING_AUTHORIZATION'
  );
end;
$function$;

revoke all on function public.tc_store_assume_payment(text,text,text)
  from public,anon;
grant execute on function public.tc_store_assume_payment(text,text,text)
  to authenticated,service_role;

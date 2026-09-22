
-- TU COMUNIDAD — CHECKOUT REQUIREMENTS GATE HARDENING V1
-- Authorized by Lucas 2026-09-22:
-- 1) retire legacy execute_checkout
-- 2) retire manual tc_accept_sub_order
-- 3) payment gate is provider-independent and explicit

alter table public.payment_authorizations
  add column payment_requirement_satisfied boolean not null default false,
  add column payment_requirement_satisfied_at timestamptz,
  add column payment_requirement_basis text,
  add column payment_requirement_provider_event_ref text;

alter table public.payment_authorizations
  add constraint payment_authorizations_requirement_shape_check
  check (
    (
      payment_requirement_satisfied
      and payment_requirement_satisfied_at is not null
      and nullif(btrim(coalesce(payment_requirement_basis,'')),'') is not null
    )
    or
    (
      not payment_requirement_satisfied
      and payment_requirement_satisfied_at is null
      and payment_requirement_basis is null
      and payment_requirement_provider_event_ref is null
    )
  );

comment on column public.payment_authorizations.payment_requirement_satisfied is
'Provider-independent checkout gate. TRUE only after a trusted payment adapter verifies that this payment rail has secured/confirmed the funds sufficiently for TU COMUNIDAD to process the order. Provider state names alone do not satisfy this requirement.';

comment on column public.payment_authorizations.payment_requirement_basis is
'Trusted adapter evidence/basis explaining why the payment requirement is satisfied for this provider/rail. No private credit or fiado semantics.';

create or replace function public.tc_mark_checkout_payment_requirement_satisfied(
  p_payment_public_id text,
  p_basis text,
  p_provider_event_ref text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_pay public.payment_authorizations%rowtype;
  v_basis text:=btrim(coalesce(p_basis,''));
  v_event_ref text:=nullif(btrim(coalesce(p_provider_event_ref,'')),'');
begin
  if nullif(btrim(coalesce(p_payment_public_id,'')),'') is null
     or v_basis='' then
    raise exception using errcode='P0001', message='TC_PAYMENT_REQUIREMENT_EVIDENCE_REQUIRED';
  end if;

  select * into v_pay
  from public.payment_authorizations pa
  where pa.public_id=upper(btrim(p_payment_public_id))
  for update;

  if v_pay.id is null then
    raise exception using errcode='P0001', message='TC_PAYMENT_AUTHORIZATION_NOT_FOUND';
  end if;

  if v_pay.order_id is not null then
    raise exception using errcode='P0001', message='TC_PAYMENT_AUTHORIZATION_ALREADY_USED';
  end if;

  if v_pay.expires_at is not null and v_pay.expires_at<=now() then
    raise exception using errcode='P0001', message='TC_PAYMENT_AUTHORIZATION_EXPIRED';
  end if;

  if v_pay.payment_requirement_satisfied then
    return jsonb_build_object(
      'success',true,
      'disposition','IDEMPOTENT',
      'payment_public_id',v_pay.public_id,
      'payment_requirement_satisfied',true,
      'payment_requirement_satisfied_at',v_pay.payment_requirement_satisfied_at,
      'payment_requirement_basis',v_pay.payment_requirement_basis
    );
  end if;

  update public.payment_authorizations
     set payment_requirement_satisfied=true,
         payment_requirement_satisfied_at=now(),
         payment_requirement_basis=v_basis,
         payment_requirement_provider_event_ref=v_event_ref,
         updated_at=now()
   where id=v_pay.id
   returning * into v_pay;

  insert into public.payment_authorization_events(
    authorization_id,event_type,provider_event_ref,payload,occurred_at
  ) values(
    v_pay.id,
    'PAYMENT_REQUIREMENT_SATISFIED',
    v_event_ref,
    jsonb_build_object(
      'payment_public_id',v_pay.public_id,
      'provider_code',v_pay.provider_code,
      'provider_state',v_pay.state,
      'basis',v_basis,
      'amount_minor',v_pay.amount_minor,
      'currency',v_pay.currency
    ) || coalesce(p_metadata,'{}'::jsonb),
    now()
  );

  return jsonb_build_object(
    'success',true,
    'disposition','APPLIED',
    'payment_public_id',v_pay.public_id,
    'payment_requirement_satisfied',true,
    'payment_requirement_satisfied_at',v_pay.payment_requirement_satisfied_at,
    'payment_requirement_basis',v_pay.payment_requirement_basis
  );
end;
$function$;

revoke all on function public.tc_mark_checkout_payment_requirement_satisfied(text,text,text,jsonb)
  from public,anon,authenticated;
grant execute on function public.tc_mark_checkout_payment_requirement_satisfied(text,text,text,jsonb)
  to service_role;

create or replace function public.tc_guard_payment_order_binding_requires_satisfaction()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if new.order_id is not null
     and old.order_id is null
     and not coalesce(new.payment_requirement_satisfied,false) then
    raise exception using errcode='P0001', message='TC_PAYMENT_REQUIREMENT_NOT_SATISFIED';
  end if;
  return new;
end;
$function$;

revoke all on function public.tc_guard_payment_order_binding_requires_satisfaction()
  from public,anon,authenticated;

drop trigger if exists payment_authorizations_order_binding_guard
  on public.payment_authorizations;

create trigger payment_authorizations_order_binding_guard
before update of order_id on public.payment_authorizations
for each row
execute function public.tc_guard_payment_order_binding_requires_satisfaction();

CREATE OR REPLACE FUNCTION public.tc_commit_checkout(p_quote_public_id text, p_payment_public_id text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid:=auth.uid();
  v_person uuid;
  v_active uuid;
  v_quote public.checkout_quotes%rowtype;
  v_pay public.payment_authorizations%rowtype;
  v_key text:=btrim(coalesce(p_idempotency_key,''));
  v_hash text;
  v_inserted integer:=0;
  v_idem public.idempotency_records%rowtype;
  v_dest_ctx jsonb;
  v_targets uuid[];
  v_rec record;
  v_sum_qty bigint;
  v_available bigint;
  v_weight numeric;
  v_volume numeric;
  v_order uuid;
  v_order_public text;
  v_demand public.order_demand_items%rowtype;
  v_source_result jsonb;
  v_demand_count integer:=0;
  v_sub_count integer;
  v_result jsonb;
begin
  if v_uid is null then
    raise exception using errcode='P0001', message='TC_UNAUTHENTICATED';
  end if;

  if nullif(btrim(coalesce(p_quote_public_id,'')),'') is null
     or nullif(btrim(coalesce(p_payment_public_id,'')),'') is null
     or v_key='' then
    raise exception using errcode='P0001', message='TC_INVALID_ARGUMENT';
  end if;

  select per.id into v_person
  from public.persons per
  where per.auth_user_id=v_uid
  limit 1;

  if v_person is null then
    raise exception using errcode='P0001', message='TC_UNAUTHENTICATED';
  end if;

  v_active:=public.tc_active_profile_id();

  if v_active is null or not exists(
    select 1
    from public.profiles p
    where p.id=v_active
      and p.person_id=v_person
      and p.profile_type='CLI'
      and p.status='active'
  ) then
    raise exception using errcode='P0001', message='TC_ACTIVE_PROFILE_TYPE_MISMATCH';
  end if;

  v_hash:=encode(
    extensions.digest(
      convert_to(
        'COMMIT_CHECKOUT|'||
        upper(btrim(p_quote_public_id))||'|'||
        upper(btrim(p_payment_public_id)),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  insert into public.idempotency_records(
    operation_type,idempotency_key,person_id,request_hash,status
  ) values(
    'COMMIT_CHECKOUT',v_key,v_person,v_hash,'PROCESSING'
  )
  on conflict(operation_type,idempotency_key) do nothing;
  get diagnostics v_inserted=row_count;

  if v_inserted=0 then
    select * into v_idem
    from public.idempotency_records
    where operation_type='COMMIT_CHECKOUT'
      and idempotency_key=v_key
    for update;

    if v_idem.person_id is distinct from v_person
       or v_idem.request_hash is distinct from v_hash then
      raise exception using errcode='P0001', message='TC_IDEMPOTENCY_KEY_REUSED';
    end if;

    if v_idem.status='COMPLETED' then
      return v_idem.response_payload;
    end if;

    raise exception using errcode='P0001', message='TC_IDEMPOTENCY_IN_PROGRESS';
  end if;

  select * into v_quote
  from public.checkout_quotes q
  where q.public_id=upper(btrim(p_quote_public_id))
  for update;

  if v_quote.id is null then
    raise exception using errcode='P0001', message='TC_CHECKOUT_QUOTE_NOT_FOUND';
  end if;

  if v_quote.client_profile_id is distinct from v_active then
    raise exception using errcode='P0001', message='TC_CHECKOUT_QUOTE_FORBIDDEN';
  end if;

  select * into v_pay
  from public.payment_authorizations pa
  where pa.public_id=upper(btrim(p_payment_public_id))
  for update;

  if v_pay.id is null then
    raise exception using errcode='P0001', message='TC_PAYMENT_AUTHORIZATION_NOT_FOUND';
  end if;

  if v_quote.status='COMMITTED' then
    if v_quote.committed_order_id is not null
       and v_pay.order_id=v_quote.committed_order_id then
      select public_id into v_order_public
      from public.orders where id=v_quote.committed_order_id;

      v_result:=jsonb_build_object(
        'success',true,
        'disposition','IDEMPOTENT',
        'quote_public_id',v_quote.public_id,
        'payment_public_id',v_pay.public_id,
        'order_public_id',v_order_public,
        'total_minor',v_quote.total_minor,
        'currency',v_quote.currency
      );

      update public.idempotency_records
         set status='COMPLETED',response_payload=v_result,completed_at=now()
       where operation_type='COMMIT_CHECKOUT'
         and idempotency_key=v_key
         and person_id=v_person
         and request_hash=v_hash;

      return v_result;
    end if;

    raise exception using errcode='P0001', message='TC_CHECKOUT_QUOTE_ALREADY_COMMITTED';
  end if;

  if v_quote.status<>'OPEN' then
    raise exception using errcode='P0001', message='TC_CHECKOUT_QUOTE_NOT_OPEN';
  end if;

  if v_pay.quote_id is distinct from v_quote.id
     or v_pay.client_profile_id is distinct from v_quote.client_profile_id
     or v_pay.amount_minor is distinct from v_quote.total_minor
     or v_pay.currency is distinct from v_quote.currency then
    raise exception using errcode='P0001', message='TC_PAYMENT_AUTHORIZATION_QUOTE_MISMATCH';
  end if;

  if not coalesce(v_pay.payment_requirement_satisfied,false) then
    raise exception using errcode='P0001', message='TC_PAYMENT_REQUIREMENT_NOT_SATISFIED';
  end if;

  if v_pay.payment_requirement_satisfied_at is null then
    raise exception using errcode='P0001', message='TC_PAYMENT_REQUIREMENT_NOT_SATISFIED';
  end if;

  if v_pay.order_id is not null then
    raise exception using errcode='P0001', message='TC_PAYMENT_AUTHORIZATION_ALREADY_USED';
  end if;

  if v_pay.expires_at is not null and v_pay.expires_at<=now() then
    raise exception using errcode='P0001', message='TC_PAYMENT_AUTHORIZATION_EXPIRED';
  end if;

  v_dest_ctx:=public.tc_checkout_destination_context(
    v_quote.client_profile_id,
    v_quote.destination_type,
    v_quote.destination_id
  );

  select array_agg(value::text::uuid)
    into v_targets
  from jsonb_array_elements_text(v_dest_ctx->'target_node_ids');

  -- Lock all inventory rows in deterministic order before stale-quote checks.
  for v_rec in
    select distinct i.id
    from public.checkout_quote_lines ql
    join public.inventory i on i.listing_id=ql.listing_id
    where ql.quote_id=v_quote.id
    order by i.id
  loop
    perform 1 from public.inventory i
    where i.id=v_rec.id
    for update;
  end loop;

  -- Revalidate the entire source plan. No reservation/payment consumption occurs on stale quote.
  for v_rec in
    select
      ql.listing_id,
      ql.store_profile_id,
      ql.source_operational_location_id,
      ql.unit_price_minor,
      ql.quantity,
      ql.variant_id,
      sl.currency,
      sl.price_minor as current_price,
      sl.is_active as listing_active,
      sp.status as profile_status,
      sp.profile_type,
      coalesce(sd.is_active,true) as seller_active,
      coalesce(sd.is_open,true) as seller_open,
      i.quantity_committed,
      i.quantity_reserved,
      i.quantity_consumed,
      pv.weight_kg,
      pv.volume_m3,
      pv.is_active as variant_active
    from public.checkout_quote_lines ql
    join public.store_listings sl on sl.id=ql.listing_id
    join public.profiles sp on sp.id=ql.store_profile_id
    join public.inventory i on i.listing_id=ql.listing_id
    join public.product_variants pv on pv.id=ql.variant_id
    left join public.store_directory sd on sd.store_profile_id=sp.id
    where ql.quote_id=v_quote.id
    order by ql.line_no
  loop
    if not v_rec.listing_active
       or not v_rec.variant_active
       or v_rec.profile_status<>'active'
       or v_rec.profile_type not in ('TIE','VEN')
       or not v_rec.seller_active
       or not v_rec.seller_open
       or v_rec.current_price<>v_rec.unit_price_minor
       or v_rec.currency<>v_quote.currency then
      raise exception using errcode='P0001', message='TC_QUOTE_STALE_REQUOTE_REQUIRED';
    end if;

    if not exists(
      select 1
      from public.operational_locations o
      where o.id=v_rec.source_operational_location_id
        and o.owner_profile_id=v_rec.store_profile_id
        and o.purpose='STORE_PICKUP'
        and o.active
        and o.network_enabled
        and o.verification_status='VERIFIED'
    ) then
      raise exception using errcode='P0001', message='TC_QUOTE_STALE_REQUOTE_REQUIRED';
    end if;

    select sum(ql.quantity)
      into v_sum_qty
    from public.checkout_quote_lines ql
    where ql.quote_id=v_quote.id
      and ql.listing_id=v_rec.listing_id;

    v_available:=v_rec.quantity_committed-v_rec.quantity_reserved-v_rec.quantity_consumed;
    if v_available<v_sum_qty then
      raise exception using errcode='P0001', message='TC_QUOTE_STALE_REQUOTE_REQUIRED';
    end if;

    v_weight:=coalesce(v_rec.weight_kg,0)*v_rec.quantity;
    v_volume:=coalesce(v_rec.volume_m3,0)*v_rec.quantity;

    if not exists(
      select 1
      from unnest(v_targets) t(node_id)
      where public.tc_quote_structural_path_exists(
        v_rec.source_operational_location_id,t.node_id,v_weight,v_volume,8
      )
    ) then
      raise exception using errcode='P0001', message='TC_QUOTE_STALE_REQUOTE_REQUIRED';
    end if;
  end loop;

  insert into public.orders(
    client_profile_id,total_minor,currency,
    destination_type,destination_id,idempotency_key,state
  ) values(
    v_quote.client_profile_id,
    v_quote.total_minor,
    v_quote.currency,
    v_quote.destination_type,
    v_quote.destination_id,
    v_key,
    'CREATED'
  )
  returning id,public_id into v_order,v_order_public;

  -- HOME freezes by BEFORE INSERT trigger; PTC is canonically bridged now.
  if v_quote.destination_type='PTC' then
    perform public.tc_ensure_client_order_destination_contract(v_order);
  end if;

  for v_rec in
    select *
    from public.checkout_quote_lines ql
    where ql.quote_id=v_quote.id
    order by ql.line_no
  loop
    insert into public.order_demand_items(
      order_id,variant_id,quantity_requested,quantity_fulfilled,
      unit_price_committed_minor,currency,state,version
    ) values(
      v_order,v_rec.variant_id,v_rec.quantity,0,
      v_rec.unit_price_minor,v_quote.currency,'OPEN',0
    )
    returning * into v_demand;

    v_source_result:=public.tc_source_allocate_reserve(
      v_demand.public_id,
      jsonb_build_array(jsonb_build_object(
        'store_profile_id',v_rec.store_profile_id,
        'listing_id',v_rec.listing_id,
        'quantity',v_rec.quantity
      )),
      'CHECKOUT:'||v_quote.public_id||':'||v_rec.line_no::text
    );

    if coalesce(v_source_result->>'success','false')<>'true' then
      raise exception using errcode='P0001', message='TC_CHECKOUT_SOURCE_RESERVATION_FAILED';
    end if;

    v_demand_count:=v_demand_count+1;
  end loop;

  -- Existing sourcing helper creates sub-order rows; compute their financial subtotal
  -- from the committed order items after all source allocations succeed.
  update public.sub_orders so
     set subtotal_minor=x.subtotal_minor,
         updated_at=now()
  from (
    select oi.sub_order_id,sum(oi.line_total_minor)::bigint as subtotal_minor
    from public.order_items oi
    join public.sub_orders s2 on s2.id=oi.sub_order_id
    where s2.order_id=v_order
    group by oi.sub_order_id
  ) x
  where so.id=x.sub_order_id;

  select count(*)::int into v_sub_count
  from public.sub_orders so
  where so.order_id=v_order;

  update public.checkout_quotes
     set status='COMMITTED',
         committed_order_id=v_order,
         committed_at=now(),
         updated_at=now()
   where id=v_quote.id
     and status='OPEN';

  if not found then
    raise exception using errcode='P0001', message='TC_CHECKOUT_COMMIT_RACE';
  end if;

  update public.payment_authorizations
     set order_id=v_order,
         committed_at=now(),
         updated_at=now()
   where id=v_pay.id
     and order_id is null;

  if not found then
    raise exception using errcode='P0001', message='TC_PAYMENT_AUTHORIZATION_COMMIT_RACE';
  end if;

  insert into public.payment_authorization_events(
    authorization_id,event_type,provider_event_ref,payload,occurred_at
  ) values(
    v_pay.id,'ORDER_COMMITTED',null,
    jsonb_build_object(
      'quote_public_id',v_quote.public_id,
      'order_public_id',v_order_public,
      'amount_minor',v_quote.total_minor,
      'currency',v_quote.currency
    ),
    now()
  );

  insert into public.audit_logs(
    actor_person_id,actor_profile_id,operation,entity_type,
    entity_public_id,event_id,result,metadata
  ) values(
    v_person,v_active,
    'COMMIT_CHECKOUT',
    'ORDER',
    v_order_public,
    null,
    'COMPLETED',
    jsonb_build_object(
      'quote_public_id',v_quote.public_id,
      'payment_public_id',v_pay.public_id,
      'order_demand_count',v_demand_count,
      'sub_order_count',v_sub_count,
      'total_minor',v_quote.total_minor,
      'currency',v_quote.currency
    )
  );

  v_result:=jsonb_build_object(
    'success',true,
    'disposition','APPLIED',
    'quote_public_id',v_quote.public_id,
    'payment_public_id',v_pay.public_id,
    'payment_state',v_pay.state,
    'order_public_id',v_order_public,
    'order_state','CREATED',
    'order_demand_count',v_demand_count,
    'sub_order_count',v_sub_count,
    'total_minor',v_quote.total_minor,
    'currency',v_quote.currency,
    'inventory_reserved',true,
    'package_count',0
  );

  update public.idempotency_records
     set status='COMPLETED',
         response_payload=v_result,
         completed_at=now()
   where operation_type='COMMIT_CHECKOUT'
     and idempotency_key=v_key
     and person_id=v_person
     and request_hash=v_hash;

  return v_result;
end;
$function$;


create or replace function public.execute_checkout(
  p_client_profile_public_id text,
  p_destination_type text,
  p_destination_id text,
  p_items jsonb,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  raise exception using
    errcode='P0001',
    message='TC_LEGACY_CHECKOUT_RETIRED_USE_QUOTE_PAYMENT_COMMIT';
end;
$function$;

revoke all on function public.execute_checkout(text,text,text,jsonb,text)
  from public,anon,authenticated,service_role;

comment on function public.execute_checkout(text,text,text,jsonb,text) is
'RETIRED. Legacy checkout bypassed the canonical payment requirement and created PKG before preparation. Use tc_quote_checkout -> trusted payment adapter -> payment requirement satisfied -> tc_commit_checkout.';

create or replace function public.tc_accept_sub_order(
  p_sub_order_public_id text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  raise exception using
    errcode='P0001',
    message='TC_MANUAL_SUB_ORDER_ACCEPTANCE_RETIRED';
end;
$function$;

revoke all on function public.tc_accept_sub_order(text,text)
  from public,anon,authenticated,service_role;

comment on function public.tc_accept_sub_order(text,text) is
'RETIRED. Normal store sourcing uses pre-committed availability and atomic reservation; no per-order store accept/reject step exists in the canonical flow.';

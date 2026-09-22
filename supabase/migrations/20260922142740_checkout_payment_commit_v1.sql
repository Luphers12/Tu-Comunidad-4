
-- TU COMUNIDAD — PAYMENT AUTHORIZATION RECEIPT + CANONICAL CHECKOUT COMMIT V1

create or replace function public.tc_record_checkout_payment_authorization(
  p_quote_public_id text,
  p_provider_code text,
  p_provider_authorization_ref text,
  p_amount_minor bigint,
  p_currency text,
  p_expires_at timestamptz default null,
  p_provider_event_ref text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_quote public.checkout_quotes%rowtype;
  v_provider text:=upper(btrim(coalesce(p_provider_code,'')));
  v_ref text:=btrim(coalesce(p_provider_authorization_ref,''));
  v_currency varchar(3):=upper(btrim(coalesce(p_currency,'')));
  v_existing public.payment_authorizations%rowtype;
  v_pay public.payment_authorizations%rowtype;
  v_disposition text:='APPLIED';
begin
  if nullif(btrim(coalesce(p_quote_public_id,'')),'') is null
     or v_provider=''
     or v_ref=''
     or p_amount_minor is null
     or p_amount_minor<0
     or v_currency !~ '^[A-Z]{3}$' then
    raise exception using errcode='P0001', message='TC_PAYMENT_AUTHORIZATION_INVALID';
  end if;

  select * into v_quote
  from public.checkout_quotes q
  where q.public_id=upper(btrim(p_quote_public_id))
  for update;

  if v_quote.id is null then
    raise exception using errcode='P0001', message='TC_CHECKOUT_QUOTE_NOT_FOUND';
  end if;

  if v_quote.status<>'OPEN' then
    raise exception using errcode='P0001', message='TC_CHECKOUT_QUOTE_NOT_OPEN';
  end if;

  if v_quote.total_minor<>p_amount_minor
     or v_quote.currency<>v_currency then
    raise exception using errcode='P0001', message='TC_PAYMENT_AMOUNT_MISMATCH';
  end if;

  if p_expires_at is not null and p_expires_at<=now() then
    raise exception using errcode='P0001', message='TC_PAYMENT_AUTHORIZATION_EXPIRED';
  end if;

  select * into v_existing
  from public.payment_authorizations pa
  where pa.provider_code=v_provider
    and pa.provider_authorization_ref=v_ref
  for update;

  if v_existing.id is not null then
    if v_existing.quote_id is distinct from v_quote.id
       or v_existing.client_profile_id is distinct from v_quote.client_profile_id
       or v_existing.amount_minor is distinct from p_amount_minor
       or v_existing.currency is distinct from v_currency then
      raise exception using errcode='P0001', message='TC_PAYMENT_AUTHORIZATION_REF_REUSED';
    end if;

    if v_existing.state not in ('AUTHORIZED','CAPTURED','HELD') then
      raise exception using errcode='P0001', message='TC_PAYMENT_AUTHORIZATION_NOT_USABLE';
    end if;

    v_pay:=v_existing;
    v_disposition:='IDEMPOTENT';
  else
    insert into public.payment_authorizations(
      quote_id,client_profile_id,provider_code,provider_authorization_ref,
      amount_minor,currency,state,authorized_at,expires_at,metadata
    ) values(
      v_quote.id,v_quote.client_profile_id,v_provider,v_ref,
      p_amount_minor,v_currency,'AUTHORIZED',now(),p_expires_at,coalesce(p_metadata,'{}'::jsonb)
    )
    returning * into v_pay;

    insert into public.payment_authorization_events(
      authorization_id,event_type,provider_event_ref,payload,occurred_at
    ) values(
      v_pay.id,'AUTHORIZED',nullif(btrim(coalesce(p_provider_event_ref,'')),''),
      jsonb_build_object(
        'provider_code',v_provider,
        'amount_minor',p_amount_minor,
        'currency',v_currency,
        'quote_public_id',v_quote.public_id
      ) || coalesce(p_metadata,'{}'::jsonb),
      now()
    );
  end if;

  return jsonb_build_object(
    'success',true,
    'disposition',v_disposition,
    'payment_public_id',v_pay.public_id,
    'state',v_pay.state,
    'quote_public_id',v_quote.public_id,
    'amount_minor',v_pay.amount_minor,
    'currency',v_pay.currency,
    'expires_at',v_pay.expires_at
  );
end;
$function$;

revoke all on function public.tc_record_checkout_payment_authorization(
  text,text,text,bigint,text,timestamptz,text,jsonb
) from public,anon,authenticated;
grant execute on function public.tc_record_checkout_payment_authorization(
  text,text,text,bigint,text,timestamptz,text,jsonb
) to service_role;

comment on function public.tc_record_checkout_payment_authorization(
  text,text,text,bigint,text,timestamptz,text,jsonb
) is
'Trusted provider-adapter boundary. Records only an already-authorized external payment receipt bound exactly to a checkout quote. It never contacts a provider and is intentionally service_role-only.';


create or replace function public.tc_commit_checkout(
  p_quote_public_id text,
  p_payment_public_id text,
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

  if v_pay.state not in ('AUTHORIZED','CAPTURED','HELD') then
    raise exception using errcode='P0001', message='TC_PAYMENT_AUTHORIZATION_NOT_USABLE';
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

revoke all on function public.tc_commit_checkout(text,text,text)
  from public,anon;
grant execute on function public.tc_commit_checkout(text,text,text)
  to authenticated,service_role;

comment on function public.tc_commit_checkout(text,text,text) is
'Canonical paid checkout commit. Requires a trusted PAY-* authorization bound to the exact quote before any inventory reservation. Revalidates source/price/network atomically, creates source-neutral commercial demand rows, materializes the quote sourcing plan through tc_source_allocate_reserve, and creates no PKG until preparation.';

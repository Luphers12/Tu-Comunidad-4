
alter table public.logistics_routing_commitments
  drop constraint logistics_routing_commitments_routing_attempt_id_routing_ho_key;

create index logistics_routing_commitments_attempt_hop_idx
  on public.logistics_routing_commitments(routing_attempt_id,routing_hop_id,committed_at);

create or replace function public.tc_validate_routing_commitment_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_reservation public.logistics_capacity_reservations%rowtype;
  v_hop public.logistics_routing_hops%rowtype;
begin
  select * into v_reservation
  from public.logistics_capacity_reservations r
  where r.id=new.capacity_reservation_id;

  if v_reservation.id is null
     or v_reservation.state not in ('HELD','CONFIRMED','CONSUMED') then
    raise exception using errcode='P0001', message='TC_ROUTING_COMMITMENT_RESERVATION_NOT_ACTIVE';
  end if;

  select * into v_hop
  from public.logistics_routing_hops h
  where h.id=new.routing_hop_id
    and h.routing_attempt_id=new.routing_attempt_id;

  if v_hop.id is null then
    raise exception using errcode='P0001', message='TC_ROUTING_COMMITMENT_HOP_MISMATCH';
  end if;

  if exists (
    select 1
    from public.logistics_routing_commitments c
    join public.logistics_capacity_reservations r
      on r.id=c.capacity_reservation_id
    where c.routing_attempt_id=new.routing_attempt_id
      and c.routing_hop_id=new.routing_hop_id
      and r.state in ('HELD','CONFIRMED','CONSUMED')
  ) then
    raise exception using errcode='P0001', message='TC_ROUTING_HOP_ALREADY_COMMITTED';
  end if;

  return new;
end;
$$;

create trigger logistics_routing_commitments_validate_insert
before insert on public.logistics_routing_commitments
for each row execute function public.tc_validate_routing_commitment_insert();

revoke all on function public.tc_validate_routing_commitment_insert()
  from public,anon,authenticated;
grant execute on function public.tc_validate_routing_commitment_insert()
  to service_role;

comment on table public.logistics_routing_commitments is
'Append-only routing commitment history. A HOP may have multiple historical commitments over time, but only one may reference an active HELD/CONFIRMED/CONSUMED capacity reservation at once. RELEASE enables local re-candidate without deleting history.';

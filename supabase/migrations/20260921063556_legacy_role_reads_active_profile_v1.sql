
drop policy if exists orders_client_read on public.orders;
create policy orders_client_read
on public.orders
for select
to authenticated
using (
  client_profile_id=public.tc_active_profile_id()
  and exists(
    select 1 from public.profiles p
    where p.id=public.tc_active_profile_id()
      and p.profile_type='CLI'
      and p.status='active'
  )
);

drop policy if exists sub_orders_read on public.sub_orders;
create policy sub_orders_read
on public.sub_orders
for select
to authenticated
using (
  (
    order_id in (
      select o.id
      from public.orders o
      where o.client_profile_id=public.tc_active_profile_id()
    )
    and exists(
      select 1 from public.profiles p
      where p.id=public.tc_active_profile_id()
        and p.profile_type='CLI'
        and p.status='active'
    )
  )
  or
  (
    store_profile_id=public.tc_active_profile_id()
    and exists(
      select 1 from public.profiles p
      where p.id=public.tc_active_profile_id()
        and p.profile_type in ('VEN','TIE')
        and p.status='active'
    )
  )
);

drop policy if exists order_items_actor_read on public.order_items;
create policy order_items_actor_read
on public.order_items
for select
to authenticated
using (
  exists(
    select 1
    from public.sub_orders so
    join public.orders o on o.id=so.order_id
    where so.id=order_items.sub_order_id
      and (
        (
          o.client_profile_id=public.tc_active_profile_id()
          and exists(
            select 1 from public.profiles p
            where p.id=public.tc_active_profile_id()
              and p.profile_type='CLI'
              and p.status='active'
          )
        )
        or
        (
          so.store_profile_id=public.tc_active_profile_id()
          and exists(
            select 1 from public.profiles p
            where p.id=public.tc_active_profile_id()
              and p.profile_type in ('VEN','TIE')
              and p.status='active'
          )
        )
      )
  )
);

drop policy if exists inventory_store_read on public.inventory;
create policy inventory_store_read
on public.inventory
for select
to authenticated
using (
  exists(
    select 1
    from public.store_listings sl
    where sl.id=inventory.listing_id
      and sl.store_profile_id=public.tc_active_profile_id()
      and exists(
        select 1 from public.profiles p
        where p.id=public.tc_active_profile_id()
          and p.profile_type in ('VEN','TIE')
          and p.status='active'
      )
  )
);

drop policy if exists inventory_reservations_store_read on public.inventory_reservations;
create policy inventory_reservations_store_read
on public.inventory_reservations
for select
to authenticated
using (
  exists(
    select 1
    from public.inventory i
    join public.store_listings sl on sl.id=i.listing_id
    where i.id=inventory_reservations.inventory_id
      and sl.store_profile_id=public.tc_active_profile_id()
      and exists(
        select 1 from public.profiles p
        where p.id=public.tc_active_profile_id()
          and p.profile_type in ('VEN','TIE')
          and p.status='active'
      )
  )
);

drop policy if exists driver_vehicle_authorizations_read on public.driver_vehicle_authorizations;
create policy driver_vehicle_authorizations_read
on public.driver_vehicle_authorizations
for select
to authenticated
using (
  driver_profile_id=public.tc_active_profile_id()
  and exists(
    select 1 from public.profiles p
    where p.id=public.tc_active_profile_id()
      and p.profile_type='CON'
      and p.status='active'
  )
);

drop policy if exists route_assignments_read on public.route_assignments;
create policy route_assignments_read
on public.route_assignments
for select
to authenticated
using (
  driver_profile_id=public.tc_active_profile_id()
  and exists(
    select 1 from public.profiles p
    where p.id=public.tc_active_profile_id()
      and p.profile_type='CON'
      and p.status='active'
  )
);

drop policy if exists vehicles_read on public.vehicles;
create policy vehicles_read
on public.vehicles
for select
to authenticated
using (
  (
    owner_profile_id=public.tc_active_profile_id()
  )
  or
  (
    exists(
      select 1
      from public.driver_vehicle_authorizations dva
      where dva.vehicle_id=vehicles.id
        and dva.driver_profile_id=public.tc_active_profile_id()
        and dva.is_active
        and dva.valid_from<=now()
        and (dva.valid_until is null or dva.valid_until>=now())
        and exists(
          select 1 from public.profiles p
          where p.id=public.tc_active_profile_id()
            and p.profile_type='CON'
            and p.status='active'
        )
    )
  )
);

drop policy if exists demand_requests_select_own on public.demand_requests;
create policy demand_requests_select_own
on public.demand_requests
for select
to authenticated
using (
  profile_id=public.tc_active_profile_id()
);

drop policy if exists event_inbox_self_read on public.event_inbox;
create policy event_inbox_self_read
on public.event_inbox
for select
to authenticated
using (
  profile_id=public.tc_active_profile_id()
);

drop policy if exists sync_conflicts_read on public.sync_conflicts;
create policy sync_conflicts_read
on public.sync_conflicts
for select
to authenticated
using (
  exists(
    select 1 from public.profiles p
    where p.id=public.tc_active_profile_id()
      and p.profile_type='ADM'
      and p.status='active'
  )
  or event_id in (
    select ei.event_id
    from public.event_inbox ei
    where ei.profile_id=public.tc_active_profile_id()
  )
);

comment on policy orders_client_read on public.orders is
'Role-context read: only the active CLI profile sees its orders.';
comment on policy sub_orders_read on public.sub_orders is
'Role-context read: active CLI sees its order suborders; active VEN/TIE sees only suborders for that exact store profile.';

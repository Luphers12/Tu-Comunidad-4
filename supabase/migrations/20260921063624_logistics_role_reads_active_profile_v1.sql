
drop policy if exists packages_read on public.packages;
create policy packages_read
on public.packages
for select
to authenticated
using (
  current_custodian_id=public.tc_active_profile_id()
  or exists(
    select 1
    from public.sub_orders so
    join public.orders o on o.id=so.order_id
    where so.id=packages.sub_order_id
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

drop policy if exists movements_read on public.movements;
create policy movements_read
on public.movements
for select
to authenticated
using (
  from_profile_id=public.tc_active_profile_id()
  or to_profile_id=public.tc_active_profile_id()
  or route_assignment_id in (
    select ra.id
    from public.route_assignments ra
    where ra.driver_profile_id=public.tc_active_profile_id()
      and exists(
        select 1 from public.profiles p
        where p.id=public.tc_active_profile_id()
          and p.profile_type='CON'
          and p.status='active'
      )
  )
  or exists(
    select 1
    from public.movement_packages mp
    join public.packages p on p.id=mp.package_id
    where mp.movement_id=movements.id
  )
);

drop policy if exists custody_events_read on public.custody_events;
create policy custody_events_read
on public.custody_events
for select
to authenticated
using (
  from_profile_id=public.tc_active_profile_id()
  or to_profile_id=public.tc_active_profile_id()
  or package_id in (
    select p.id
    from public.packages p
  )
);

drop policy if exists route_opportunities_read on public.route_opportunities;
create policy route_opportunities_read
on public.route_opportunities
for select
to authenticated
using (
  (
    state='OPEN'
    and territory_id=(
      select p.territory_id
      from public.profiles p
      where p.id=public.tc_active_profile_id()
        and p.profile_type in ('CON','RSG')
        and p.status='active'
    )
  )
  or id in (
    select ra.route_id
    from public.route_assignments ra
    where ra.driver_profile_id=public.tc_active_profile_id()
      and exists(
        select 1 from public.profiles p
        where p.id=public.tc_active_profile_id()
          and p.profile_type='CON'
          and p.status='active'
      )
  )
);

drop policy if exists evidence_read on public.evidence;
create policy evidence_read
on public.evidence
for select
to authenticated
using (
  (
    evidence_type like 'LAST_MILE_%'
    and (
      uploader_profile_id=public.tc_active_profile_id()
      or exists(
        select 1
        from public.packages p
        join public.sub_orders so on so.id=p.sub_order_id
        join public.orders o on o.id=so.order_id
        where p.id=evidence.package_id
          and o.client_profile_id=public.tc_active_profile_id()
          and exists(
            select 1 from public.profiles pr
            where pr.id=public.tc_active_profile_id()
              and pr.profile_type='CLI'
              and pr.status='active'
          )
      )
    )
  )
  or
  (
    evidence_type not like 'LAST_MILE_%'
    and (
      uploader_profile_id=public.tc_active_profile_id()
      or package_id in (
        select p.id
        from public.packages p
      )
    )
  )
);

comment on policy packages_read on public.packages is
'Role-context read: active custodian, active CLI order owner, or active exact VEN/TIE store profile.';
comment on policy movements_read on public.movements is
'Role-context read: active movement actor, active CON assignment, or movement containing a package visible to the active profile.';
comment on policy custody_events_read on public.custody_events is
'Role-context read: active custody actor or custody history for a package visible to the active profile.';
comment on policy route_opportunities_read on public.route_opportunities is
'Legacy route feed isolated to the active CON/RSG territory or exact active CON assignment.';
comment on policy evidence_read on public.evidence is
'All evidence now respects active profile context. LAST_MILE remains stricter: active uploader RSG or active CLI owner only.';

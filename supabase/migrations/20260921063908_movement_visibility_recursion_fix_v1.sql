
create or replace function public.tc_active_profile_can_read_movement(
  p_movement_id uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_active uuid;
  v_type text;
begin
  v_active:=public.tc_active_profile_id();

  if v_active is null then
    return false;
  end if;

  select p.profile_type into v_type
  from public.profiles p
  where p.id=v_active
    and p.status='active';

  if v_type is null then
    return false;
  end if;

  if exists(
    select 1
    from public.movements m
    where m.id=p_movement_id
      and (
        m.from_profile_id=v_active
        or m.to_profile_id=v_active
        or exists(
          select 1
          from public.route_assignments ra
          where ra.id=m.route_assignment_id
            and ra.driver_profile_id=v_active
            and v_type='CON'
        )
      )
  ) then
    return true;
  end if;

  if exists(
    select 1
    from public.movement_packages mp
    join public.packages p on p.id=mp.package_id
    join public.sub_orders so on so.id=p.sub_order_id
    join public.orders o on o.id=so.order_id
    where mp.movement_id=p_movement_id
      and (
        p.current_custodian_id=v_active
        or (v_type='CLI' and o.client_profile_id=v_active)
        or (v_type in ('VEN','TIE') and so.store_profile_id=v_active)
      )
  ) then
    return true;
  end if;

  return false;
end;
$$;

revoke all on function public.tc_active_profile_can_read_movement(uuid)
  from public,anon,authenticated,service_role;

drop policy if exists movements_read on public.movements;
create policy movements_read
on public.movements
for select
to authenticated
using (
  public.tc_active_profile_can_read_movement(id)
);

drop policy if exists movement_packages_read on public.movement_packages;
create policy movement_packages_read
on public.movement_packages
for select
to authenticated
using (
  public.tc_active_profile_can_read_movement(movement_id)
);

comment on function public.tc_active_profile_can_read_movement(uuid) is
'Private RLS helper that evaluates movement visibility for the explicit active profile while bypassing recursive movement/movement_packages RLS evaluation.';


drop policy if exists sync_conflicts_admin_read on public.sync_conflicts;
drop policy if exists sync_conflicts_self_read on public.sync_conflicts;

create policy sync_conflicts_read
on public.sync_conflicts
for select
to authenticated
using (
  exists (
    select 1
    from public.current_user_profile_ids() p(profile_id, profile_type, territory_id)
    where p.profile_type = 'ADM'
  )
  or event_id in (
    select ei.event_id
    from public.event_inbox ei
    where ei.profile_id in (
      select p.profile_id
      from public.current_user_profile_ids() p(profile_id, profile_type, territory_id)
    )
  )
);

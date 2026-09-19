create or replace function public.tc_revoke_linguistic_authorization(
  p_authorization_public_id text,
  p_reason text default null
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select public.tc_request_linguistic_content_withdrawal(p_authorization_public_id,'ALL_FUTURE_USE',p_reason);
$$;

create or replace function public.tc_list_my_linguistic_withdrawals()
returns table(
  withdrawal_public_id text,
  submission_public_id text,
  withdrawal_scope text,
  status text,
  compensation_effect text,
  reward_status_at_request text,
  replacement_status text,
  requested_at timestamptz,
  effective_at timestamptz
)
language sql
stable
security definer
set search_path=''
as $$
  select w.public_id,s.public_id,w.withdrawal_scope,w.status,w.compensation_effect,
         w.reward_status_at_request,w.replacement_status,w.requested_at,w.effective_at
  from public.linguistic_withdrawal_requests w
  join public.linguistic_contributors c on c.id=w.contributor_id
  join public.persons p on p.id=c.person_id
  join public.linguistic_task_submissions s on s.id=w.submission_id
  where p.auth_user_id=auth.uid()
  order by w.requested_at desc;
$$;

revoke all on function public.tc_revoke_linguistic_authorization(text,text) from public,anon;
grant execute on function public.tc_revoke_linguistic_authorization(text,text) to authenticated;
revoke all on function public.tc_list_my_linguistic_withdrawals() from public,anon;
grant execute on function public.tc_list_my_linguistic_withdrawals() to authenticated;
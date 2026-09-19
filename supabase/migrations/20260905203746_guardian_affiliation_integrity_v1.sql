create schema if not exists guardian_audit;

revoke all on schema guardian_audit from public;
revoke all on schema guardian_audit from anon;
revoke all on schema guardian_audit from authenticated;
revoke all on schema guardian_audit from service_role;

create or replace function guardian_audit.guardian_affiliation_integrity_v1()
returns table(
  anomaly_code text,
  severity text,
  affected_count bigint,
  invariant text
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    'AFF_ACTIVATED_WITHOUT_APPROVAL'::text,
    'CRITICAL'::text,
    count(*)::bigint,
    'An activated affiliation profile requires application state APPROVED.'::text
  from public.affiliation_applications a
  where a.activated_profile_id is not null
    and a.state <> 'APPROVED'

  union all

  select
    'AFF_APPROVED_WITHOUT_PROFILE',
    'CRITICAL',
    count(*)::bigint,
    'An APPROVED affiliation must reference the activated profile created or reactivated by final approval.'
  from public.affiliation_applications a
  where a.state = 'APPROVED'
    and a.activated_profile_id is null

  union all

  select
    'AFF_APPROVED_WITH_UNVERIFIED_REQUIRED',
    'CRITICAL',
    count(*)::bigint,
    'Before final approval, every required affiliation requirement must be VERIFIED or WAIVED.'
  from public.affiliation_applications a
  where a.state = 'APPROVED'
    and exists (
      select 1
      from public.affiliation_application_requirements r
      where r.application_id = a.id
        and r.required
        and r.status not in ('VERIFIED','WAIVED')
    )

  union all

  select
    'AFF_APPROVED_WITHOUT_APPROVAL_REVIEW',
    'CRITICAL',
    count(*)::bigint,
    'Final approval must have a corresponding human review decision APPROVE.'
  from public.affiliation_applications a
  where a.state = 'APPROVED'
    and not exists (
      select 1
      from public.affiliation_reviews rv
      where rv.application_id = a.id
        and rv.decision = 'APPROVE'
    )

  union all

  select
    'AFF_PROFILE_IDENTITY_OR_ROLE_MISMATCH',
    'CRITICAL',
    count(*)::bigint,
    'The activated profile must belong to the applicant person and match the requested role code.'
  from public.affiliation_applications a
  join public.profiles p on p.id = a.activated_profile_id
  where a.state = 'APPROVED'
    and (p.person_id <> a.person_id or p.profile_type <> a.requested_role_code)

  union all

  select
    'AFF_APPROVED_WITHOUT_APPROVAL_EVENT',
    'HIGH',
    count(*)::bigint,
    'Final approval must be represented by an APPLICATION_APPROVED audit event transitioning to APPROVED.'
  from public.affiliation_applications a
  where a.state = 'APPROVED'
    and not exists (
      select 1
      from public.affiliation_events e
      where e.application_id = a.id
        and e.event_type = 'APPLICATION_APPROVED'
        and e.to_state = 'APPROVED'
    )

  union all

  select
    'AFF_REJECTED_WITHOUT_REJECTION_REVIEW',
    'HIGH',
    count(*)::bigint,
    'Final rejection must have a corresponding human review decision REJECT.'
  from public.affiliation_applications a
  where a.state = 'REJECTED'
    and not exists (
      select 1
      from public.affiliation_reviews rv
      where rv.application_id = a.id
        and rv.decision = 'REJECT'
    )

  union all

  select
    'AFF_REJECTED_WITHOUT_REJECTION_EVENT',
    'HIGH',
    count(*)::bigint,
    'Final rejection must be represented by an APPLICATION_REJECTED audit event transitioning to REJECTED.'
  from public.affiliation_applications a
  where a.state = 'REJECTED'
    and not exists (
      select 1
      from public.affiliation_events e
      where e.application_id = a.id
        and e.event_type = 'APPLICATION_REJECTED'
        and e.to_state = 'REJECTED'
    )

  union all

  select
    'AFF_TERMINAL_STATE_WITHOUT_RESOLVED_AT',
    'MEDIUM',
    count(*)::bigint,
    'APPROVED and REJECTED applications must record resolved_at.'
  from public.affiliation_applications a
  where a.state in ('APPROVED','REJECTED')
    and a.resolved_at is null

  union all

  select
    'AFF_DUPLICATE_ACTIVE_APPLICATION',
    'HIGH',
    coalesce(sum(x.n - 1),0)::bigint,
    'At most one active affiliation application may exist per person and requested role.'
  from (
    select a.person_id, a.requested_role_code, count(*)::bigint as n
    from public.affiliation_applications a
    where a.state in ('DRAFT','SUBMITTED','UNDER_REVIEW','CHANGES_REQUESTED')
    group by a.person_id, a.requested_role_code
    having count(*) > 1
  ) x;
$$;

revoke all on function guardian_audit.guardian_affiliation_integrity_v1() from public;
revoke all on function guardian_audit.guardian_affiliation_integrity_v1() from anon;
revoke all on function guardian_audit.guardian_affiliation_integrity_v1() from authenticated;
revoke all on function guardian_audit.guardian_affiliation_integrity_v1() from service_role;

comment on schema guardian_audit is 'Private audit-only schema for GUARDIAN. Not exposed to application clients.';
comment on function guardian_audit.guardian_affiliation_integrity_v1() is 'READ ONLY aggregated affiliation integrity audit. No arguments and no person identifiers or private payloads are returned.';
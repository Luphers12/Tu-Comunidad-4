begin;

insert into public.tc_feature_gates (
  feature_key, domain, display_name,
  source_status, backend_status, safety_status, legal_status, cultural_status, approval_status,
  is_enabled, notes
)
values (
  'linguistics.workspace', 'LINGUISTICS', 'Espacio personal de trabajo lingüístico',
  'NOT_REQUIRED', 'VERIFIED', 'PENDING', 'PENDING', 'PENDING', 'PENDING',
  false,
  'Panel personal para tareas, roles, portafolio, disponibilidad y estado de compensación. Solo datos propios. No activa pagos ni asignación automática.'
)
on conflict (feature_key) do update
set display_name = excluded.display_name,
    notes = excluded.notes,
    source_status = 'NOT_REQUIRED',
    backend_status = 'VERIFIED',
    updated_at = now();

create or replace function public.tc_get_my_linguistic_workspace()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_contributor_id uuid;
  v_profile_id uuid;
  v_workspace_enabled boolean := false;
  v_comp_enabled boolean := false;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select coalesce(is_enabled,false)
    into v_workspace_enabled
  from public.tc_feature_gates
  where feature_key = 'linguistics.workspace';

  if not coalesce(v_workspace_enabled,false) then
    raise exception 'FEATURE_DISABLED';
  end if;

  select lp.contributor_id, lp.profile_id
    into v_contributor_id, v_profile_id
  from public.current_user_profile_ids() cup
  join public.linguistic_profiles lp on lp.profile_id = cup.profile_id
  limit 1;

  if v_contributor_id is null then
    raise exception 'LINGUISTIC_PROFILE_NOT_FOUND';
  end if;

  select coalesce(is_enabled,false)
    into v_comp_enabled
  from public.tc_feature_gates
  where feature_key = 'linguistics.compensation';

  select jsonb_build_object(
    'profile', jsonb_build_object(
      'profile_id', lp.profile_id,
      'contributor_id', lp.contributor_id,
      'onboarding_status', lp.onboarding_status,
      'availability_status', lp.availability_status,
      'can_receive_tasks', lp.can_receive_tasks,
      'max_active_assignments', lp.max_active_assignments,
      'language', case when l.id is null then null else jsonb_build_object(
        'public_id', l.public_id,
        'name', l.name,
        'iso_code', l.iso_code
      ) end,
      'variant', case when lv.id is null then null else jsonb_build_object(
        'public_id', lv.public_id,
        'name', lv.name
      ) end
    ),
    'summary', jsonb_build_object(
      'assigned', (select count(*) from public.linguistic_task_assignments a where a.contributor_id=v_contributor_id and a.status='ASSIGNED'),
      'accepted', (select count(*) from public.linguistic_task_assignments a where a.contributor_id=v_contributor_id and a.status='ACCEPTED'),
      'submitted_or_review', (select count(*) from public.linguistic_task_assignments a where a.contributor_id=v_contributor_id and a.status in ('SUBMITTED','CHANGES_REQUESTED')),
      'approved', (select count(*) from public.linguistic_task_assignments a where a.contributor_id=v_contributor_id and a.status='APPROVED'),
      'active_total', (select count(*) from public.linguistic_task_assignments a where a.contributor_id=v_contributor_id and a.status in ('ASSIGNED','ACCEPTED','SUBMITTED','CHANGES_REQUESTED'))
    ),
    'tasks', coalesce((
      select jsonb_agg(jsonb_build_object(
        'assignment_public_id', a.public_id,
        'assignment_role', a.assignment_role,
        'assignment_status', a.status,
        'assigned_at', a.assigned_at,
        'accepted_at', a.accepted_at,
        'due_at', a.due_at,
        'completed_at', a.completed_at,
        'task', jsonb_build_object(
          'public_id', t.public_id,
          'task_type', t.task_type,
          'status', t.status,
          'priority', t.priority,
          'sensitivity', t.sensitivity,
          'context_name', t.context_name,
          'source_language_tag', t.source_language_tag,
          'source_text', t.source_text,
          'context_note', t.context_note,
          'requires_audio', t.requires_audio,
          'allow_ai_assistance', t.allow_ai_assistance,
          'requires_ai_disclosure', t.requires_ai_disclosure
        ),
        'job', jsonb_build_object(
          'public_id', j.public_id,
          'title', j.title
        ),
        'latest_submission', (
          select jsonb_build_object(
            'public_id', s.public_id,
            'version', s.version,
            'status', s.status,
            'submitted_at', s.submitted_at,
            'reviewed_at', s.reviewed_at
          )
          from public.linguistic_task_submissions s
          where s.assignment_id=a.id
          order by s.version desc
          limit 1
        )
      ) order by coalesce(a.due_at,'infinity'::timestamptz), a.assigned_at desc)
      from public.linguistic_task_assignments a
      join public.linguistic_tasks t on t.id=a.task_id
      join public.linguistic_jobs j on j.id=t.job_id
      where a.contributor_id=v_contributor_id
        and a.status in ('ASSIGNED','ACCEPTED','SUBMITTED','CHANGES_REQUESTED','APPROVED')
    ), '[]'::jsonb),
    'roles', coalesce((
      select jsonb_agg(jsonb_build_object(
        'role_code', rc.role_code,
        'display_name', rc.display_name,
        'status', cr.status,
        'language_public_id', l2.public_id,
        'language_name', l2.name,
        'variant_public_id', lv2.public_id,
        'variant_name', lv2.name,
        'granted_at', cr.granted_at,
        'expires_at', cr.expires_at
      ) order by rc.role_code)
      from public.linguistic_contributor_roles cr
      join public.linguistic_role_catalog rc on rc.id=cr.role_id
      join public.languages l2 on l2.id=cr.language_id
      left join public.language_variants lv2 on lv2.id=cr.variant_id
      where cr.contributor_id=v_contributor_id
    ), '[]'::jsonb),
    'qualifications', coalesce((
      select jsonb_agg(jsonb_build_object(
        'public_id', q.public_id,
        'proficiency', q.proficiency,
        'verification_status', q.verification_status,
        'language_public_id', l3.public_id,
        'language_name', l3.name,
        'variant_public_id', lv3.public_id,
        'variant_name', lv3.name,
        'verified_at', q.verified_at
      ) order by q.created_at desc)
      from public.linguistic_contributor_qualifications q
      join public.languages l3 on l3.id=q.language_id
      left join public.language_variants lv3 on lv3.id=q.variant_id
      where q.contributor_id=v_contributor_id
    ), '[]'::jsonb),
    'portfolio', coalesce((
      select jsonb_agg(to_jsonb(p) - 'contributor_id' order by p.submitted_at desc)
      from public.v_linguistic_contributor_portfolio p
      where p.contributor_id=v_contributor_id
    ), '[]'::jsonb),
    'compensation', jsonb_build_object(
      'feature_enabled', coalesce(v_comp_enabled,false),
      'items', case when coalesce(v_comp_enabled,false) then coalesce((
        select jsonb_agg(jsonb_build_object(
          'public_id', ci.public_id,
          'work_kind', ci.work_kind,
          'compensation_mode', ci.compensation_mode,
          'amount', ci.amount,
          'currency', ci.currency,
          'tc_credit_amount', ci.tc_credit_amount,
          'status', ci.status,
          'created_at', ci.created_at,
          'approved_at', ci.approved_at,
          'issued_at', ci.issued_at
        ) order by ci.created_at desc)
        from public.linguistic_compensation_items ci
        where ci.contributor_id=v_contributor_id
      ), '[]'::jsonb) else '[]'::jsonb end,
      'message', case when coalesce(v_comp_enabled,false) then null else 'Compensación todavía no activada.' end
    )
  )
  into v_result
  from public.linguistic_profiles lp
  left join public.languages l on l.id=lp.selected_language_id
  left join public.language_variants lv on lv.id=lp.selected_variant_id
  where lp.profile_id=v_profile_id;

  return v_result;
end;
$$;

revoke all on function public.tc_get_my_linguistic_workspace() from public, anon;
grant execute on function public.tc_get_my_linguistic_workspace() to authenticated;

create or replace function public.tc_set_my_linguistic_availability(p_status text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_contributor_id uuid;
  v_profile_id uuid;
  v_workspace_enabled boolean := false;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if p_status not in ('AVAILABLE','PAUSED','BUSY','UNAVAILABLE') then
    raise exception 'INVALID_AVAILABILITY_STATUS';
  end if;

  select coalesce(is_enabled,false)
    into v_workspace_enabled
  from public.tc_feature_gates
  where feature_key='linguistics.workspace';

  if not coalesce(v_workspace_enabled,false) then
    raise exception 'FEATURE_DISABLED';
  end if;

  select lp.contributor_id, lp.profile_id
    into v_contributor_id, v_profile_id
  from public.current_user_profile_ids() cup
  join public.linguistic_profiles lp on lp.profile_id=cup.profile_id
  limit 1;

  if v_contributor_id is null then
    raise exception 'LINGUISTIC_PROFILE_NOT_FOUND';
  end if;

  update public.linguistic_profiles
  set availability_status=p_status,
      updated_at=now()
  where profile_id=v_profile_id;

  return jsonb_build_object(
    'success', true,
    'availability_status', p_status,
    'can_receive_tasks', (select can_receive_tasks from public.linguistic_profiles where profile_id=v_profile_id)
  );
end;
$$;

revoke all on function public.tc_set_my_linguistic_availability(text) from public, anon;
grant execute on function public.tc_set_my_linguistic_availability(text) to authenticated;

commit;
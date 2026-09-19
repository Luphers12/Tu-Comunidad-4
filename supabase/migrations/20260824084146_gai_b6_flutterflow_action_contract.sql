create or replace function public.gai_get_allowed_actions(
  p_active_profile_id uuid,
  p_incident_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_person_id uuid;
  v_inc public.gai_incidents%rowtype;
  v_ack boolean;
  v_assign boolean;
  v_resolve boolean;
  v_close boolean;
  v_override boolean;
  v_attach boolean;
begin
  select pe.id into v_person_id
  from public.persons pe
  join public.profiles pr on pr.person_id=pe.id
  where pe.auth_user_id=auth.uid() and pr.id=p_active_profile_id;

  if v_person_id is null then
    raise exception 'GAI_SECURITY_VIOLATION' using errcode='invalid_authorization_specification';
  end if;

  select * into v_inc from public.gai_incidents where id=p_incident_id;
  if not found then raise exception 'GAI_INCIDENT_NOT_FOUND' using errcode='no_data_found'; end if;

  if not public.internal_gai_profile_can_view_incident(p_active_profile_id,p_incident_id) then
    raise exception 'GAI_INCIDENT_NOT_VISIBLE' using errcode='insufficient_privilege';
  end if;

  v_ack := public.internal_has_capability(p_active_profile_id,'incident.acknowledge',v_inc.scope_type,v_inc.scope_target_id);
  v_assign := public.internal_has_capability(p_active_profile_id,'incident.assign',v_inc.scope_type,v_inc.scope_target_id);
  v_resolve := public.internal_has_capability(p_active_profile_id,'incident.resolve',v_inc.scope_type,v_inc.scope_target_id);
  v_close := public.internal_has_capability(p_active_profile_id,'incident.close',v_inc.scope_type,v_inc.scope_target_id);
  v_override := public.internal_has_capability(p_active_profile_id,'incident.override',v_inc.scope_type,v_inc.scope_target_id);

  v_attach := v_inc.state <> 'CLOSED'
    and (
      v_inc.created_by_profile_id=p_active_profile_id
      or v_inc.assigned_profile_id=p_active_profile_id
      or v_resolve
      or v_override
    );

  return jsonb_build_object(
    'incident_id',v_inc.id,
    'state',v_inc.state,
    'version',v_inc.version,
    'can_acknowledge',(v_inc.state='TRIGGERED' and v_ack),
    'can_start_investigation',(v_inc.state in ('TRIGGERED','ACKNOWLEDGED') and v_assign),
    'can_assign',(v_inc.state<>'CLOSED' and v_assign),
    'can_resolve',(v_inc.state in ('TRIGGERED','ACKNOWLEDGED','INVESTIGATING') and v_resolve),
    'can_close',(v_inc.state='RESOLVED' and v_close),
    'can_reopen',(v_inc.state='RESOLVED' and v_override),
    'can_escalate',(v_inc.state not in ('RESOLVED','CLOSED') and v_override),
    'can_policy_enforce',(v_inc.state<>'CLOSED' and v_override),
    'can_attach_evidence',v_attach,
    'reason_required',jsonb_build_object(
      'resolve',true,
      'close',true,
      'reopen',true,
      'policy_enforce',true,
      'acknowledge',false,
      'start_investigation',false,
      'assign',false,
      'escalate',false
    )
  );
end;
$$;

revoke all on function public.gai_get_allowed_actions(uuid,uuid) from public, anon;
grant execute on function public.gai_get_allowed_actions(uuid,uuid) to authenticated;
begin;

insert into public.capabilities(name)
values ('linguistic.role.verify')
on conflict (name) do nothing;

create table if not exists public.linguistic_role_activation_decisions (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default tc_generate_public_id('LRAD'),
  role_evaluation_id uuid not null references public.linguistic_assessment_role_evaluations(id) on delete restrict,
  contributor_id uuid not null references public.linguistic_contributors(id) on delete restrict,
  role_code text not null,
  language_id uuid not null references public.languages(id) on delete restrict,
  variant_id uuid null references public.language_variants(id) on delete restrict,
  decision text not null check (decision in ('APPROVED','REJECTED','SUSPENDED','REVOKED')),
  decision_reason text not null,
  decided_by_profile_id uuid not null references public.profiles(id) on delete restrict,
  decided_by_person_id uuid not null references public.persons(id) on delete restrict,
  decision_source text not null check (decision_source in ('FINAL_REVIEWER','EXPLICIT_CAPABILITY')),
  created_at timestamptz not null default now()
);

create unique index if not exists linguistic_role_activation_one_active_decision_uq
on public.linguistic_role_activation_decisions(role_evaluation_id, decision)
where decision='APPROVED';

alter table public.linguistic_role_activation_decisions enable row level security;
revoke all on public.linguistic_role_activation_decisions from anon, authenticated;

create or replace function public.tc_finalize_linguistic_role_activation(
  p_role_evaluation_id uuid,
  p_decision text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eval public.linguistic_assessment_role_evaluations%rowtype;
  v_attempt public.linguistic_assessment_attempts%rowtype;
  v_template public.linguistic_assessment_templates%rowtype;
  v_contributor public.linguistic_contributors%rowtype;
  v_role public.linguistic_role_catalog%rowtype;
  v_actor_profile uuid;
  v_actor_person uuid;
  v_actor_source text;
  v_target_role_id uuid;
  v_contributor_role_id uuid;
  v_has_final_reviewer boolean := false;
  v_has_explicit_cap boolean := false;
  v_gate_enabled boolean := false;
begin
  if p_decision not in ('APPROVED','REJECTED','SUSPENDED','REVOKED') then
    raise exception 'INVALID_DECISION';
  end if;
  if coalesce(length(trim(p_reason)),0) < 3 then
    raise exception 'DECISION_REASON_REQUIRED';
  end if;

  select * into v_eval from public.linguistic_assessment_role_evaluations where id=p_role_evaluation_id for update;
  if not found then raise exception 'ROLE_EVALUATION_NOT_FOUND'; end if;

  select * into v_attempt from public.linguistic_assessment_attempts where id=v_eval.attempt_id;
  select * into v_template from public.linguistic_assessment_templates where id=v_attempt.template_id;
  select * into v_contributor from public.linguistic_contributors where id=v_attempt.contributor_id;
  select * into v_role from public.linguistic_role_catalog where role_code=v_eval.role_code and is_active=true;
  if not found then raise exception 'ROLE_NOT_FOUND'; end if;

  select p.id, p.person_id
    into v_actor_profile, v_actor_person
  from public.current_user_profile_ids() cup
  join public.profiles p on p.id=cup.profile_id
  where public.internal_has_capability(p.id,'linguistic.role.verify','GLOBAL'::public.tc_scope_type,null)
  order by p.created_at
  limit 1;

  if v_actor_profile is not null then
    v_has_explicit_cap := true;
    v_actor_source := 'EXPLICIT_CAPABILITY';
  else
    select p.id, p.person_id
      into v_actor_profile, v_actor_person
    from public.current_user_profile_ids() cup
    join public.profiles p on p.id=cup.profile_id
    join public.linguistic_profiles lp on lp.profile_id=p.id
    join public.linguistic_contributor_roles lcr on lcr.contributor_id=lp.contributor_id
    join public.linguistic_role_catalog lrc on lrc.id=lcr.role_id and lrc.role_code='FINAL_REVIEWER'
    where lcr.status='VERIFIED'
      and lcr.language_id=v_template.language_id
      and lcr.variant_id is not distinct from v_template.variant_id
      and (lcr.expires_at is null or lcr.expires_at>=now())
    order by p.created_at
    limit 1;

    if v_actor_profile is not null then
      v_has_final_reviewer := true;
      v_actor_source := 'FINAL_REVIEWER';
    end if;
  end if;

  if not (v_has_explicit_cap or v_has_final_reviewer) then
    raise exception 'NOT_AUTHORIZED_TO_VERIFY_ROLE';
  end if;

  if v_actor_person = v_contributor.person_id then
    raise exception 'SELF_APPROVAL_BLOCKED';
  end if;

  if p_decision='APPROVED' then
    if v_eval.eligibility_status <> 'CALCULATED_ELIGIBLE' then
      raise exception 'ROLE_NOT_CALCULATED_ELIGIBLE';
    end if;

    select is_enabled into v_gate_enabled from public.tc_feature_gates where feature_key='linguistics.role_activation';
    if coalesce(v_gate_enabled,false)=false then
      raise exception 'ROLE_ACTIVATION_GATE_DISABLED';
    end if;
  end if;

  insert into public.linguistic_role_activation_decisions(
    role_evaluation_id,contributor_id,role_code,language_id,variant_id,decision,decision_reason,
    decided_by_profile_id,decided_by_person_id,decision_source
  ) values (
    v_eval.id,v_contributor.id,v_eval.role_code,v_template.language_id,v_template.variant_id,p_decision,trim(p_reason),
    v_actor_profile,v_actor_person,v_actor_source
  );

  select id into v_target_role_id from public.linguistic_role_catalog where role_code=v_eval.role_code;

  if p_decision='APPROVED' then
    insert into public.linguistic_contributor_roles(
      contributor_id,role_id,language_id,variant_id,status,granted_by_person_id,granted_at,evidence_note
    ) values (
      v_contributor.id,v_target_role_id,v_template.language_id,v_template.variant_id,'VERIFIED',v_actor_person,now(),
      'Activated from assessment role evaluation '||v_eval.id::text
    )
    on conflict (contributor_id,role_id,language_id,variant_id)
    do update set status='VERIFIED', granted_by_person_id=excluded.granted_by_person_id,
                  granted_at=excluded.granted_at, evidence_note=excluded.evidence_note, updated_at=now();
  elsif p_decision='REJECTED' then
    insert into public.linguistic_contributor_roles(
      contributor_id,role_id,language_id,variant_id,status,evidence_note
    ) values (
      v_contributor.id,v_target_role_id,v_template.language_id,v_template.variant_id,'REJECTED',trim(p_reason)
    )
    on conflict (contributor_id,role_id,language_id,variant_id)
    do update set status='REJECTED', evidence_note=excluded.evidence_note, updated_at=now();
  elsif p_decision='SUSPENDED' then
    update public.linguistic_contributor_roles
       set status='SUSPENDED', evidence_note=trim(p_reason), updated_at=now()
     where contributor_id=v_contributor.id and role_id=v_target_role_id
       and language_id=v_template.language_id and variant_id is not distinct from v_template.variant_id;
  elsif p_decision='REVOKED' then
    update public.linguistic_contributor_roles
       set status='REVOKED', evidence_note=trim(p_reason), updated_at=now()
     where contributor_id=v_contributor.id and role_id=v_target_role_id
       and language_id=v_template.language_id and variant_id is not distinct from v_template.variant_id;
  end if;

  return jsonb_build_object(
    'success',true,
    'decision',p_decision,
    'role_code',v_eval.role_code,
    'decision_source',v_actor_source,
    'role_activated',(p_decision='APPROVED')
  );
end;
$$;

revoke all on function public.tc_finalize_linguistic_role_activation(uuid,text,text) from public;
grant execute on function public.tc_finalize_linguistic_role_activation(uuid,text,text) to authenticated;

insert into public.tc_feature_gates(
 feature_key,domain,parent_feature_key,display_name,source_status,backend_status,safety_status,legal_status,cultural_status,approval_status,is_enabled,notes
)
values (
 'linguistics.role_activation','LINGUISTICS','linguistics.role_eligibility_engine','Activación humana de roles lingüísticos',
 'VERIFIED','VERIFIED','PENDING','PENDING','PENDING','PENDING',false,
 'Solo permite activar roles tras elegibilidad calculada y decisión humana autorizada. La autoaprobación está bloqueada.'
)
on conflict (feature_key) do update set
 backend_status='VERIFIED', is_enabled=false, updated_at=now(),
 notes=excluded.notes;

commit;
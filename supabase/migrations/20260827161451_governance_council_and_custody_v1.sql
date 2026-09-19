begin;

with current_cv as (
  select id
  from public.tc_constitution_versions
  where status = 'MASTER_APPROVED'
  order by version_no desc
  limit 1
)
insert into public.tc_governance_policies (
  constitution_version_id, protection_class,
  required_independent_approvals, required_independent_reviews,
  requires_legal_clearance, requires_community_consultation,
  execution_enabled, policy_status, notes
)
select current_cv.id, v.protection_class, v.approvals, v.reviews,
       v.legal_clearance, v.community_consultation,
       false, 'DESIGN_APPROVED', v.notes
from current_cv
cross join (values
  ('FOUNDATIONAL'::text, 3, 2, true,  true,
   'Mission-critical. Three distinct supporting approvers, two distinct reviewers, legal clearance, community consultation where applicable. Execution remains disabled until legal mechanisms are verified.'::text),
  ('RESERVED'::text,      2, 1, true,  false,
   'High-impact reserved matter. Two distinct supporting approvers and one independent review. Additional community/custodial requirements are action-sensitive.'::text),
  ('OPERATIONAL'::text,   1, 1, false, false,
   'Routine governance matter. Still subject to mission compatibility and conflict-of-interest rules.'::text)
) as v(protection_class, approvals, reviews, legal_clearance, community_consultation, notes)
on conflict (constitution_version_id, protection_class) do nothing;

create table if not exists public.tc_governance_seat_catalog (
  id uuid primary key default gen_random_uuid(),
  seat_code text not null unique,
  title text not null,
  purpose text not null,
  is_mission_guardian boolean not null default false,
  is_community_voice boolean not null default false,
  is_cultural_data_custodian boolean not null default false,
  is_independent boolean not null default false,
  expandable_by_territory boolean not null default false,
  status text not null default 'DESIGN_APPROVED'
    check (status in ('DRAFT','DESIGN_APPROVED','LEGAL_VERIFIED','RETIRED')),
  legal_status text not null default 'PENDING'
    check (legal_status in ('PENDING','APPROVED','REJECTED','NOT_REQUIRED')),
  created_at timestamptz not null default now()
);

insert into public.tc_governance_seat_catalog
(seat_code,title,purpose,is_mission_guardian,is_community_voice,is_cultural_data_custodian,is_independent,expandable_by_territory)
values
('MISSION_GUARDIAN','Guardián de la misión','Protege la finalidad comunitaria y la continuidad de la misión. El cargo debe sobrevivir a la persona que lo ocupa.',true,false,false,false,false),
('COMMUNITY_REPRESENTATIVE','Representación Comunitaria','Representa el impacto real sobre las comunidades y participa en decisiones que afecten acceso, dependencia, derechos o patrimonio comunitario.',false,true,false,false,true),
('CULTURAL_DATA_CUSTODIAN','Custodia Cultural, Lingüística y de Datos Comunitarios','Custodia idiomas, cultura, memoria, saberes, voces, traducciones, patrimonio comunitario y sus permisos de uso. Custodiar no significa apropiarse.',false,false,true,false,true),
('OPERATIONS_STEWARD','Custodia de Operaciones','Aporta criterio operativo sobre marketplace, logística, transporte, PTC, vendedores, conductores y continuidad práctica de la red.',false,false,false,false,false),
('INDEPENDENT_LEGAL_STEWARD','Custodia Independiente y Legal','Aporta revisión independiente y coordina evidencia de revisión legal/compliance cuando corresponda; no sustituye asesoría jurídica externa.',false,false,false,true,false)
on conflict (seat_code) do nothing;

create table if not exists public.tc_governance_council_terms (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('GCT'),
  title text not null,
  status text not null default 'DESIGN'
    check (status in ('DESIGN','ACTIVE','SUSPENDED','CLOSED')),
  starts_at timestamptz,
  ends_at timestamptz,
  legal_status text not null default 'PENDING'
    check (legal_status in ('PENDING','APPROVED','REJECTED','NOT_REQUIRED')),
  notes text,
  created_at timestamptz not null default now(),
  check (ends_at is null or starts_at is null or ends_at > starts_at)
);

insert into public.tc_governance_council_terms(title,status,legal_status,notes)
select 'Consejo de Gobernanza de TU COMUNIDAD — Diseño inicial','DESIGN','PENDING',
       'Estructura de producto/MASTER. No constituye por sí sola un órgano societario legal. Pendiente traducción a estatutos/acuerdos por asesor legal.'
where not exists (select 1 from public.tc_governance_council_terms);

create table if not exists public.tc_governance_council_memberships (
  id uuid primary key default gen_random_uuid(),
  council_term_id uuid not null references public.tc_governance_council_terms(id) on delete restrict,
  seat_id uuid not null references public.tc_governance_seat_catalog(id) on delete restrict,
  profile_id uuid not null references public.profiles(id) on delete restrict,
  status text not null default 'NOMINATED'
    check (status in ('NOMINATED','ACTIVE','RECUSED','SUSPENDED','ENDED','REJECTED')),
  appointed_at timestamptz,
  ended_at timestamptz,
  appointment_basis text,
  succession_of_membership_id uuid references public.tc_governance_council_memberships(id) on delete restrict,
  created_at timestamptz not null default now(),
  check (ended_at is null or appointed_at is null or ended_at >= appointed_at)
);

create unique index if not exists uq_tc_gov_active_profile_one_main_seat
  on public.tc_governance_council_memberships(council_term_id, profile_id)
  where status = 'ACTIVE';

create table if not exists public.tc_governance_conflicts (
  id uuid primary key default gen_random_uuid(),
  proposal_id uuid not null references public.tc_governance_proposals(id) on delete restrict,
  profile_id uuid not null references public.profiles(id) on delete restrict,
  conflict_type text not null
    check (conflict_type in ('FINANCIAL','FAMILY_OR_CLOSE_RELATION','EMPLOYMENT','VENDOR_OR_PARTNER','PERSONAL_BENEFIT','LEGAL','OTHER')),
  description text not null,
  status text not null default 'DISCLOSED'
    check (status in ('DISCLOSED','RECUSED','REVIEWED_NO_RECUSAL','RESOLVED')),
  reviewed_by_profile_id uuid references public.profiles(id) on delete restrict,
  resolution_notes text,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  unique (proposal_id, profile_id, conflict_type)
);

create table if not exists public.tc_governance_consultations (
  id uuid primary key default gen_random_uuid(),
  proposal_id uuid not null references public.tc_governance_proposals(id) on delete restrict,
  consultation_kind text not null
    check (consultation_kind in ('COMMUNITY','CULTURAL_LINGUISTIC_DATA','LEGAL','OPERATIONS','MISSION_COMPATIBILITY')),
  community_id uuid references public.communities(id) on delete restrict,
  recorded_by_profile_id uuid references public.profiles(id) on delete restrict,
  outcome text not null
    check (outcome in ('SUPPORT','CONCERNS','OPPOSE','APPROVED','REJECTED','INFORMATION_ONLY')),
  summary text not null,
  evidence_reference text,
  source_authority text,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create table if not exists public.tc_governance_action_seat_requirements (
  id uuid primary key default gen_random_uuid(),
  reserved_action_id uuid not null references public.tc_constitution_reserved_actions(id) on delete restrict,
  seat_id uuid not null references public.tc_governance_seat_catalog(id) on delete restrict,
  requirement_kind text not null default 'SUPPORT_REQUIRED'
    check (requirement_kind in ('REVIEW_REQUIRED','SUPPORT_REQUIRED','CONSULT_REQUIRED')),
  rationale text not null,
  created_at timestamptz not null default now(),
  unique (reserved_action_id, seat_id, requirement_kind)
);

with current_cv as (
  select id from public.tc_constitution_versions where status='MASTER_APPROVED' order by version_no desc limit 1
), actions as (
  select a.id, a.action_code
  from public.tc_constitution_reserved_actions a join current_cv c on c.id=a.constitution_version_id
), seats as (
  select id, seat_code from public.tc_governance_seat_catalog
)
insert into public.tc_governance_action_seat_requirements(reserved_action_id,seat_id,requirement_kind,rationale)
select a.id, s.id, x.requirement_kind, x.rationale
from (values
  ('CHANGE_CORE_MISSION','MISSION_GUARDIAN','SUPPORT_REQUIRED','A mission change requires mission-guardian participation.'),
  ('MISSION_COMPATIBILITY_REVIEW','MISSION_GUARDIAN','SUPPORT_REQUIRED','Mission compatibility requires the mission guardian.'),
  ('CHANGE_CONTROL','MISSION_GUARDIAN','SUPPORT_REQUIRED','A transfer of control must not bypass mission protection.'),
  ('SELL_CORE_BRAND','MISSION_GUARDIAN','SUPPORT_REQUIRED','The core brand cannot be detached from mission protection without mission-guardian participation.'),
  ('SELL_CORE_SOFTWARE','MISSION_GUARDIAN','SUPPORT_REQUIRED','Core technology transfer requires mission protection.'),
  ('MERGER_OR_DISSOLUTION','MISSION_GUARDIAN','SUPPORT_REQUIRED','Merger/dissolution requires continuity-of-mission review.'),
  ('NEW_COMMUNITY_DATA_USE','COMMUNITY_REPRESENTATIVE','SUPPORT_REQUIRED','New uses of community data require community representation.'),
  ('NEW_COMMUNITY_DATA_USE','CULTURAL_DATA_CUSTODIAN','SUPPORT_REQUIRED','New community-data uses require cultural/data custody.'),
  ('CULTURAL_OR_AI_RIGHTS_EXPANSION','COMMUNITY_REPRESENTATIVE','SUPPORT_REQUIRED','Expansion of cultural/AI rights requires community representation.'),
  ('CULTURAL_OR_AI_RIGHTS_EXPANSION','CULTURAL_DATA_CUSTODIAN','SUPPORT_REQUIRED','Expansion of cultural/AI rights requires cultural/data custody.'),
  ('DESTROY_COMMUNITY_HERITAGE','COMMUNITY_REPRESENTATIVE','SUPPORT_REQUIRED','Community heritage is designed for preservation and requires community representation for any exceptional disposition.'),
  ('DESTROY_COMMUNITY_HERITAGE','CULTURAL_DATA_CUSTODIAN','SUPPORT_REQUIRED','Community heritage is under special cultural/data custody.'),
  ('TRANSFER_COMMUNITY_HERITAGE_CUSTODY','COMMUNITY_REPRESENTATIVE','SUPPORT_REQUIRED','Custody transfer requires community representation.'),
  ('TRANSFER_COMMUNITY_HERITAGE_CUSTODY','CULTURAL_DATA_CUSTODIAN','SUPPORT_REQUIRED','Custody transfer requires cultural/data custody.'),
  ('HIGH_IMPACT_ECONOMIC_RULES','COMMUNITY_REPRESENTATIVE','SUPPORT_REQUIRED','High-impact economic rules require community-impact representation.'),
  ('COMMUNITY_EXCLUSION_RULES','COMMUNITY_REPRESENTATIVE','SUPPORT_REQUIRED','Exclusion rules require community representation.')
) as x(action_code,seat_code,requirement_kind,rationale)
join actions a on a.action_code=x.action_code
join seats s on s.seat_code=x.seat_code
on conflict do nothing;

create or replace function public.tc_governance_active_membership(p_profile_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select m.id
  from public.tc_governance_council_memberships m
  join public.tc_governance_council_terms t on t.id=m.council_term_id
  where m.profile_id=p_profile_id
    and m.status='ACTIVE'
    and t.status='ACTIVE'
    and (t.starts_at is null or t.starts_at <= now())
    and (t.ends_at is null or t.ends_at > now())
  order by m.created_at desc
  limit 1;
$$;

create or replace function public.tc_governance_evaluate_proposal(p_proposal_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_p record;
  v_policy record;
  v_reviews int := 0;
  v_approvals int := 0;
  v_oppositions int := 0;
  v_missing_required_seats int := 0;
  v_ready boolean := false;
  v_reason text;
begin
  select gp.*, ra.protection_class, ra.legal_mechanism_status
    into v_p
  from public.tc_governance_proposals gp
  join public.tc_constitution_reserved_actions ra on ra.id = gp.reserved_action_id
  where gp.id = p_proposal_id;

  if not found then
    return jsonb_build_object('exists',false,'ready',false,'reason','PROPOSAL_NOT_FOUND');
  end if;

  select * into v_policy
  from public.tc_governance_policies
  where constitution_version_id=v_p.constitution_version_id
    and protection_class=v_p.protection_class;

  if not found then
    return jsonb_build_object('exists',true,'ready',false,'reason','POLICY_NOT_FOUND');
  end if;

  select
    count(distinct reviewer_profile_id) filter (where review_kind='INDEPENDENT_REVIEW' and decision='SUPPORT'),
    count(distinct reviewer_profile_id) filter (where review_kind='APPROVAL' and decision='SUPPORT'),
    count(distinct reviewer_profile_id) filter (where decision='OPPOSE')
  into v_reviews,v_approvals,v_oppositions
  from public.tc_governance_reviews r
  where r.proposal_id=p_proposal_id
    and r.withdrawn_at is null
    and public.tc_governance_active_membership(r.reviewer_profile_id) is not null
    and not exists (
      select 1 from public.tc_governance_conflicts c
      where c.proposal_id=p_proposal_id and c.profile_id=r.reviewer_profile_id and c.status='RECUSED'
    );

  select count(*) into v_missing_required_seats
  from public.tc_governance_action_seat_requirements req
  where req.reserved_action_id=v_p.reserved_action_id
    and req.requirement_kind='SUPPORT_REQUIRED'
    and not exists (
      select 1
      from public.tc_governance_reviews r
      join public.tc_governance_council_memberships m
        on m.profile_id=r.reviewer_profile_id and m.status='ACTIVE'
      join public.tc_governance_council_terms t
        on t.id=m.council_term_id and t.status='ACTIVE'
      where r.proposal_id=p_proposal_id
        and r.review_kind='APPROVAL'
        and r.decision='SUPPORT'
        and r.withdrawn_at is null
        and m.seat_id=req.seat_id
        and not exists (
          select 1 from public.tc_governance_conflicts c
          where c.proposal_id=p_proposal_id and c.profile_id=r.reviewer_profile_id and c.status='RECUSED'
        )
    );

  if v_oppositions > 0 then
    v_reason := 'ACTIVE_OPPOSITION_REQUIRES_RESOLUTION';
  elsif v_reviews < v_policy.required_independent_reviews then
    v_reason := 'INSUFFICIENT_INDEPENDENT_REVIEWS';
  elsif v_approvals < v_policy.required_independent_approvals then
    v_reason := 'INSUFFICIENT_APPROVALS';
  elsif v_missing_required_seats > 0 then
    v_reason := 'REQUIRED_COUNCIL_SEAT_SUPPORT_MISSING';
  elsif v_policy.requires_legal_clearance and v_p.legal_clearance_status <> 'APPROVED' then
    v_reason := 'LEGAL_CLEARANCE_REQUIRED';
  elsif v_policy.requires_community_consultation and v_p.community_consultation_status <> 'COMPLETED' then
    v_reason := 'COMMUNITY_CONSULTATION_REQUIRED';
  elsif not v_policy.execution_enabled then
    v_reason := 'EXECUTION_DISABLED';
  elsif v_p.protection_class in ('FOUNDATIONAL','RESERVED') and v_p.legal_mechanism_status <> 'APPROVED' then
    v_reason := 'LEGAL_MECHANISM_NOT_APPROVED';
  else
    v_ready := true;
    v_reason := 'READY';
  end if;

  return jsonb_build_object(
    'exists',true,
    'proposal_id',v_p.public_id,
    'status',v_p.status,
    'protection_class',v_p.protection_class,
    'independent_reviews',v_reviews,
    'required_independent_reviews',v_policy.required_independent_reviews,
    'approvals',v_approvals,
    'required_approvals',v_policy.required_independent_approvals,
    'oppositions',v_oppositions,
    'missing_required_seats',v_missing_required_seats,
    'legal_clearance_status',v_p.legal_clearance_status,
    'community_consultation_status',v_p.community_consultation_status,
    'execution_enabled',v_policy.execution_enabled,
    'ready',v_ready,
    'reason',v_reason
  );
end;
$$;

create or replace function public.tc_review_governance_proposal(
  p_proposal_id uuid,
  p_decision text,
  p_rationale text,
  p_review_kind text default 'INDEPENDENT_REVIEW'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cap varchar;
  v_profile uuid;
  v_proposer uuid;
  v_status text;
begin
  if p_decision not in ('SUPPORT','OPPOSE','ABSTAIN') then raise exception 'INVALID_GOVERNANCE_DECISION'; end if;
  if p_review_kind not in ('INDEPENDENT_REVIEW','APPROVAL') then raise exception 'INVALID_GOVERNANCE_REVIEW_KIND'; end if;
  if nullif(btrim(p_rationale),'') is null then raise exception 'GOVERNANCE_RATIONALE_REQUIRED'; end if;

  v_cap := case when p_review_kind='APPROVAL' then 'governance.approve' else 'governance.review' end;
  v_profile := public.tc_governance_current_profile(v_cap);
  if v_profile is null then raise exception 'GOVERNANCE_REVIEW_NOT_AUTHORIZED'; end if;
  if public.tc_governance_active_membership(v_profile) is null then raise exception 'GOVERNANCE_ACTIVE_COUNCIL_MEMBERSHIP_REQUIRED'; end if;

  select proposer_profile_id,status into v_proposer,v_status
  from public.tc_governance_proposals where id=p_proposal_id;
  if v_proposer is null then raise exception 'GOVERNANCE_PROPOSAL_NOT_FOUND'; end if;
  if v_status <> 'UNDER_REVIEW' then raise exception 'GOVERNANCE_PROPOSAL_NOT_UNDER_REVIEW'; end if;
  if v_profile=v_proposer then raise exception 'GOVERNANCE_SELF_REVIEW_FORBIDDEN'; end if;
  if exists (
    select 1 from public.tc_governance_conflicts c
    where c.proposal_id=p_proposal_id and c.profile_id=v_profile and c.status='RECUSED'
  ) then raise exception 'GOVERNANCE_MEMBER_RECUSED'; end if;

  insert into public.tc_governance_reviews(proposal_id,reviewer_profile_id,decision,review_kind,rationale)
  values(p_proposal_id,v_profile,p_decision,p_review_kind,btrim(p_rationale));

  insert into public.tc_governance_events(proposal_id,actor_profile_id,event_type,event_payload)
  values(p_proposal_id,v_profile,'REVIEW_RECORDED',jsonb_build_object('kind',p_review_kind,'decision',p_decision));

  return public.tc_governance_evaluate_proposal(p_proposal_id);
end;
$$;

alter table public.tc_governance_seat_catalog enable row level security;
alter table public.tc_governance_council_terms enable row level security;
alter table public.tc_governance_council_memberships enable row level security;
alter table public.tc_governance_conflicts enable row level security;
alter table public.tc_governance_consultations enable row level security;
alter table public.tc_governance_action_seat_requirements enable row level security;

revoke all on public.tc_governance_seat_catalog from anon, authenticated;
revoke all on public.tc_governance_council_terms from anon, authenticated;
revoke all on public.tc_governance_council_memberships from anon, authenticated;
revoke all on public.tc_governance_conflicts from anon, authenticated;
revoke all on public.tc_governance_consultations from anon, authenticated;
revoke all on public.tc_governance_action_seat_requirements from anon, authenticated;

create or replace function public.tc_get_governance_council_design()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'seats', coalesce((
      select jsonb_agg(jsonb_build_object(
        'seat_code',s.seat_code,
        'title',s.title,
        'purpose',s.purpose,
        'expandable_by_territory',s.expandable_by_territory,
        'status',s.status,
        'legal_status',s.legal_status
      ) order by s.created_at)
      from public.tc_governance_seat_catalog s
      where s.status <> 'RETIRED'
    ),'[]'::jsonb),
    'council', coalesce((
      select jsonb_build_object(
        'public_id',t.public_id,
        'title',t.title,
        'status',t.status,
        'legal_status',t.legal_status,
        'active_member_count',(select count(*) from public.tc_governance_council_memberships m where m.council_term_id=t.id and m.status='ACTIVE')
      )
      from public.tc_governance_council_terms t
      order by t.created_at desc limit 1
    ),'{}'::jsonb)
  );
$$;

grant execute on function public.tc_get_governance_council_design() to authenticated;

commit;
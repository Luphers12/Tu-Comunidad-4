begin;

-- -----------------------------------------------------------------------------
-- TU COMUNIDAD - Governance Engine v1
-- Builds an auditable, fail-closed governance workflow on top of TCCONST.
-- Does NOT make pending constitutional rules legally effective by itself.
-- -----------------------------------------------------------------------------

insert into public.capabilities(name)
values
  ('governance.propose'),
  ('governance.review'),
  ('governance.approve'),
  ('governance.execute')
on conflict (name) do nothing;

create table if not exists public.tc_governance_policies (
  id uuid primary key default gen_random_uuid(),
  constitution_version_id uuid not null references public.tc_constitution_versions(id) on delete restrict,
  protection_class text not null check (protection_class in ('FOUNDATIONAL','RESERVED','OPERATIONAL')),
  required_independent_approvals integer not null check (required_independent_approvals >= 1),
  required_independent_reviews integer not null check (required_independent_reviews >= 1),
  requires_legal_clearance boolean not null default false,
  requires_community_consultation boolean not null default false,
  execution_enabled boolean not null default false,
  policy_status text not null default 'DESIGN_APPROVED' check (policy_status in ('DRAFT','DESIGN_APPROVED','LEGAL_VERIFIED','RETIRED')),
  notes text,
  created_at timestamptz not null default now(),
  unique (constitution_version_id, protection_class)
);

create table if not exists public.tc_governance_proposals (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('GOV'),
  constitution_version_id uuid not null references public.tc_constitution_versions(id) on delete restrict,
  reserved_action_id uuid not null references public.tc_constitution_reserved_actions(id) on delete restrict,
  proposer_profile_id uuid not null references public.profiles(id) on delete restrict,
  title text not null,
  rationale text not null,
  requested_change jsonb not null default '{}'::jsonb,
  impact_summary text,
  community_impact_summary text,
  status text not null default 'DRAFT' check (status in ('DRAFT','SUBMITTED','UNDER_REVIEW','APPROVED','REJECTED','BLOCKED','EXECUTED','CANCELLED')),
  legal_clearance_status text not null default 'PENDING' check (legal_clearance_status in ('PENDING','NOT_REQUIRED','APPROVED','REJECTED')),
  community_consultation_status text not null default 'PENDING' check (community_consultation_status in ('PENDING','NOT_REQUIRED','COMPLETED','REJECTED')),
  blocked_reason text,
  submitted_at timestamptz,
  decided_at timestamptz,
  executed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_tc_governance_proposals_status
  on public.tc_governance_proposals(status, created_at desc);
create index if not exists idx_tc_governance_proposals_action
  on public.tc_governance_proposals(reserved_action_id, status);

create table if not exists public.tc_governance_reviews (
  id uuid primary key default gen_random_uuid(),
  proposal_id uuid not null references public.tc_governance_proposals(id) on delete restrict,
  reviewer_profile_id uuid not null references public.profiles(id) on delete restrict,
  decision text not null check (decision in ('SUPPORT','OPPOSE','ABSTAIN')),
  review_kind text not null default 'INDEPENDENT_REVIEW' check (review_kind in ('INDEPENDENT_REVIEW','APPROVAL')),
  rationale text not null,
  created_at timestamptz not null default now(),
  withdrawn_at timestamptz,
  unique (proposal_id, reviewer_profile_id, review_kind)
);

create index if not exists idx_tc_governance_reviews_proposal
  on public.tc_governance_reviews(proposal_id, review_kind, decision)
  where withdrawn_at is null;

create table if not exists public.tc_governance_events (
  id uuid primary key default gen_random_uuid(),
  proposal_id uuid not null references public.tc_governance_proposals(id) on delete restrict,
  actor_profile_id uuid references public.profiles(id) on delete restrict,
  event_type text not null,
  event_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_tc_governance_events_proposal
  on public.tc_governance_events(proposal_id, created_at);

-- Immutability of historical governance reviews/events.
create or replace function public.tc_block_governance_history_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'GOVERNANCE_HISTORY_IMMUTABLE';
end;
$$;

drop trigger if exists trg_tc_governance_events_immutable on public.tc_governance_events;
create trigger trg_tc_governance_events_immutable
before update or delete on public.tc_governance_events
for each row execute function public.tc_block_governance_history_mutation();

-- Review rows can only be withdrawn through RPC; material review content is immutable.
create or replace function public.tc_guard_governance_review_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.proposal_id is distinct from new.proposal_id
     or old.reviewer_profile_id is distinct from new.reviewer_profile_id
     or old.decision is distinct from new.decision
     or old.review_kind is distinct from new.review_kind
     or old.rationale is distinct from new.rationale
     or old.created_at is distinct from new.created_at then
    raise exception 'GOVERNANCE_REVIEW_IMMUTABLE';
  end if;
  if old.withdrawn_at is not null and new.withdrawn_at is distinct from old.withdrawn_at then
    raise exception 'GOVERNANCE_REVIEW_WITHDRAWAL_IMMUTABLE';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_tc_governance_review_guard on public.tc_governance_reviews;
create trigger trg_tc_governance_review_guard
before update on public.tc_governance_reviews
for each row execute function public.tc_guard_governance_review_update();

drop trigger if exists trg_tc_governance_reviews_no_delete on public.tc_governance_reviews;
create trigger trg_tc_governance_reviews_no_delete
before delete on public.tc_governance_reviews
for each row execute function public.tc_block_governance_history_mutation();

-- Approved constitution versions remain immutable; proposals never edit them in place.
-- A constitutional change must ultimately produce a NEW constitution version.

-- Seed design policy for current MASTER-approved constitution. Sensitive execution stays off.
insert into public.tc_governance_policies (
  constitution_version_id, protection_class,
  required_independent_approvals, required_independent_reviews,
  requires_legal_clearance, requires_community_consultation,
  execution_enabled, policy_status, notes
)
select v.id, x.protection_class, x.approvals, x.reviews,
       x.legal_required, x.community_required, false, 'DESIGN_APPROVED', x.notes
from public.tc_constitution_versions v
cross join (values
  ('FOUNDATIONAL', 3, 3, true,  true,  'Fail-closed until legal governance mechanism is verified.'),
  ('RESERVED',      2, 2, true,  false, 'Fail-closed until legal governance mechanism is verified.'),
  ('OPERATIONAL',   1, 1, false, false, 'Execution still requires governance.execute capability and explicit enablement.')
) as x(protection_class, approvals, reviews, legal_required, community_required, notes)
where v.status = 'MASTER_APPROVED'
on conflict (constitution_version_id, protection_class) do nothing;

-- Helper: resolve an authenticated active profile with a GLOBAL capability.
create or replace function public.tc_governance_current_profile(p_capability varchar)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile_id uuid;
begin
  if auth.uid() is null then
    return null;
  end if;

  select pr.id
    into v_profile_id
  from public.persons pe
  join public.profiles pr on pr.person_id = pe.id
  where pe.auth_user_id = auth.uid()
    and pr.status::text = 'active'
    and public.internal_has_capability(pr.id, p_capability, 'GLOBAL', null)
  order by pr.created_at
  limit 1;

  return v_profile_id;
end;
$$;

create or replace function public.tc_governance_evaluate_proposal(p_proposal_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_p record;
  v_policy record;
  v_reviews int;
  v_approvals int;
  v_oppositions int;
  v_ready boolean := false;
  v_reason text;
begin
  select gp.*, ra.protection_class, ra.legal_mechanism_status
    into v_p
  from public.tc_governance_proposals gp
  join public.tc_constitution_reserved_actions ra on ra.id = gp.reserved_action_id
  where gp.id = p_proposal_id;

  if not found then
    return jsonb_build_object('exists', false, 'ready', false, 'reason', 'PROPOSAL_NOT_FOUND');
  end if;

  select * into v_policy
  from public.tc_governance_policies
  where constitution_version_id = v_p.constitution_version_id
    and protection_class = v_p.protection_class;

  if not found then
    return jsonb_build_object('exists', true, 'ready', false, 'reason', 'POLICY_NOT_FOUND');
  end if;

  select
    count(*) filter (where review_kind='INDEPENDENT_REVIEW' and decision='SUPPORT'),
    count(*) filter (where review_kind='APPROVAL' and decision='SUPPORT'),
    count(*) filter (where decision='OPPOSE')
  into v_reviews, v_approvals, v_oppositions
  from public.tc_governance_reviews
  where proposal_id = p_proposal_id and withdrawn_at is null;

  if v_oppositions > 0 then
    v_reason := 'ACTIVE_OPPOSITION_REQUIRES_RESOLUTION';
  elsif v_reviews < v_policy.required_independent_reviews then
    v_reason := 'INSUFFICIENT_INDEPENDENT_REVIEWS';
  elsif v_approvals < v_policy.required_independent_approvals then
    v_reason := 'INSUFFICIENT_APPROVALS';
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
    'exists', true,
    'proposal_id', v_p.public_id,
    'status', v_p.status,
    'protection_class', v_p.protection_class,
    'independent_reviews', v_reviews,
    'required_independent_reviews', v_policy.required_independent_reviews,
    'approvals', v_approvals,
    'required_approvals', v_policy.required_independent_approvals,
    'oppositions', v_oppositions,
    'legal_clearance_status', v_p.legal_clearance_status,
    'community_consultation_status', v_p.community_consultation_status,
    'execution_enabled', v_policy.execution_enabled,
    'ready', v_ready,
    'reason', v_reason
  );
end;
$$;

create or replace function public.tc_create_governance_proposal(
  p_action_code text,
  p_title text,
  p_rationale text,
  p_requested_change jsonb default '{}'::jsonb,
  p_impact_summary text default null,
  p_community_impact_summary text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile uuid;
  v_version uuid;
  v_action uuid;
  v_protection text;
  v_id uuid;
  v_public_id text;
  v_legal_status text;
  v_community_status text;
begin
  v_profile := public.tc_governance_current_profile('governance.propose');
  if v_profile is null then
    raise exception 'GOVERNANCE_PROPOSE_NOT_AUTHORIZED';
  end if;

  select id into v_version
  from public.tc_constitution_versions
  where status='MASTER_APPROVED'
  order by version_no desc
  limit 1;

  select id, protection_class into v_action, v_protection
  from public.tc_constitution_reserved_actions
  where constitution_version_id=v_version and action_code=p_action_code;

  if v_action is null then
    raise exception 'GOVERNANCE_ACTION_NOT_FOUND';
  end if;

  select case when requires_legal_clearance then 'PENDING' else 'NOT_REQUIRED' end,
         case when requires_community_consultation then 'PENDING' else 'NOT_REQUIRED' end
    into v_legal_status, v_community_status
  from public.tc_governance_policies
  where constitution_version_id=v_version and protection_class=v_protection;

  insert into public.tc_governance_proposals(
    constitution_version_id,reserved_action_id,proposer_profile_id,title,rationale,
    requested_change,impact_summary,community_impact_summary,
    legal_clearance_status,community_consultation_status
  ) values (
    v_version,v_action,v_profile,btrim(p_title),btrim(p_rationale),
    coalesce(p_requested_change,'{}'::jsonb),p_impact_summary,p_community_impact_summary,
    v_legal_status,v_community_status
  ) returning id, public_id into v_id, v_public_id;

  insert into public.tc_governance_events(proposal_id,actor_profile_id,event_type,event_payload)
  values(v_id,v_profile,'PROPOSAL_CREATED',jsonb_build_object('action_code',p_action_code));

  return jsonb_build_object('success',true,'proposal_id',v_public_id,'status','DRAFT','protection_class',v_protection);
end;
$$;

create or replace function public.tc_submit_governance_proposal(p_proposal_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile uuid;
  v_public text;
begin
  v_profile := public.tc_governance_current_profile('governance.propose');
  if v_profile is null then raise exception 'GOVERNANCE_PROPOSE_NOT_AUTHORIZED'; end if;

  update public.tc_governance_proposals
  set status='UNDER_REVIEW', submitted_at=now(), updated_at=now()
  where id=p_proposal_id and proposer_profile_id=v_profile and status='DRAFT'
  returning public_id into v_public;

  if v_public is null then raise exception 'GOVERNANCE_PROPOSAL_NOT_SUBMITTABLE'; end if;

  insert into public.tc_governance_events(proposal_id,actor_profile_id,event_type)
  values(p_proposal_id,v_profile,'PROPOSAL_SUBMITTED');

  return jsonb_build_object('success',true,'proposal_id',v_public,'status','UNDER_REVIEW');
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
set search_path = ''
as $$
declare
  v_cap varchar;
  v_profile uuid;
  v_proposer uuid;
  v_status text;
begin
  if p_decision not in ('SUPPORT','OPPOSE','ABSTAIN') then raise exception 'INVALID_GOVERNANCE_DECISION'; end if;
  if p_review_kind not in ('INDEPENDENT_REVIEW','APPROVAL') then raise exception 'INVALID_GOVERNANCE_REVIEW_KIND'; end if;
  v_cap := case when p_review_kind='APPROVAL' then 'governance.approve' else 'governance.review' end;
  v_profile := public.tc_governance_current_profile(v_cap);
  if v_profile is null then raise exception 'GOVERNANCE_REVIEW_NOT_AUTHORIZED'; end if;

  select proposer_profile_id,status into v_proposer,v_status
  from public.tc_governance_proposals where id=p_proposal_id;
  if v_proposer is null then raise exception 'GOVERNANCE_PROPOSAL_NOT_FOUND'; end if;
  if v_status <> 'UNDER_REVIEW' then raise exception 'GOVERNANCE_PROPOSAL_NOT_UNDER_REVIEW'; end if;
  if v_profile=v_proposer then raise exception 'GOVERNANCE_SELF_REVIEW_FORBIDDEN'; end if;

  insert into public.tc_governance_reviews(proposal_id,reviewer_profile_id,decision,review_kind,rationale)
  values(p_proposal_id,v_profile,p_decision,p_review_kind,btrim(p_rationale));

  insert into public.tc_governance_events(proposal_id,actor_profile_id,event_type,event_payload)
  values(p_proposal_id,v_profile,'REVIEW_RECORDED',jsonb_build_object('kind',p_review_kind,'decision',p_decision));

  return public.tc_governance_evaluate_proposal(p_proposal_id);
end;
$$;

create or replace function public.tc_withdraw_my_governance_review(p_proposal_id uuid, p_review_kind text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile uuid;
  v_cap varchar;
  v_count int;
begin
  v_cap := case when p_review_kind='APPROVAL' then 'governance.approve' else 'governance.review' end;
  v_profile := public.tc_governance_current_profile(v_cap);
  if v_profile is null then raise exception 'GOVERNANCE_REVIEW_NOT_AUTHORIZED'; end if;

  update public.tc_governance_reviews
  set withdrawn_at=now()
  where proposal_id=p_proposal_id and reviewer_profile_id=v_profile
    and review_kind=p_review_kind and withdrawn_at is null;
  get diagnostics v_count = row_count;
  if v_count=0 then raise exception 'ACTIVE_GOVERNANCE_REVIEW_NOT_FOUND'; end if;

  insert into public.tc_governance_events(proposal_id,actor_profile_id,event_type,event_payload)
  values(p_proposal_id,v_profile,'REVIEW_WITHDRAWN',jsonb_build_object('kind',p_review_kind));

  return public.tc_governance_evaluate_proposal(p_proposal_id);
end;
$$;

-- Execution gate. This v1 does NOT apply arbitrary requested_change payloads.
-- It only marks a proposal executable after all safeguards have passed.
create or replace function public.tc_mark_governance_proposal_approved(p_proposal_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile uuid;
  v_eval jsonb;
  v_public text;
begin
  v_profile := public.tc_governance_current_profile('governance.execute');
  if v_profile is null then raise exception 'GOVERNANCE_EXECUTE_NOT_AUTHORIZED'; end if;

  v_eval := public.tc_governance_evaluate_proposal(p_proposal_id);
  if coalesce((v_eval->>'ready')::boolean,false) is not true then
    raise exception 'GOVERNANCE_PROPOSAL_NOT_READY: %', coalesce(v_eval->>'reason','UNKNOWN');
  end if;

  update public.tc_governance_proposals
  set status='APPROVED', decided_at=now(), updated_at=now()
  where id=p_proposal_id and status='UNDER_REVIEW'
  returning public_id into v_public;
  if v_public is null then raise exception 'GOVERNANCE_PROPOSAL_STATE_CHANGED'; end if;

  insert into public.tc_governance_events(proposal_id,actor_profile_id,event_type)
  values(p_proposal_id,v_profile,'PROPOSAL_APPROVED');

  return jsonb_build_object('success',true,'proposal_id',v_public,'status','APPROVED');
end;
$$;

-- RLS / direct-access fail closed. Governance changes happen through reviewed RPCs.
alter table public.tc_governance_policies enable row level security;
alter table public.tc_governance_proposals enable row level security;
alter table public.tc_governance_reviews enable row level security;
alter table public.tc_governance_events enable row level security;

revoke all on public.tc_governance_policies from anon, authenticated;
revoke all on public.tc_governance_proposals from anon, authenticated;
revoke all on public.tc_governance_reviews from anon, authenticated;
revoke all on public.tc_governance_events from anon, authenticated;

grant execute on function public.tc_create_governance_proposal(text,text,text,jsonb,text,text) to authenticated;
grant execute on function public.tc_submit_governance_proposal(uuid) to authenticated;
grant execute on function public.tc_review_governance_proposal(uuid,text,text,text) to authenticated;
grant execute on function public.tc_withdraw_my_governance_review(uuid,text) to authenticated;
grant execute on function public.tc_mark_governance_proposal_approved(uuid) to authenticated;
grant execute on function public.tc_governance_evaluate_proposal(uuid) to authenticated;

commit;
begin;

create sequence if not exists public.leng_seq start 1;
create sequence if not exists public.lrate_seq start 1;
create sequence if not exists public.learn_seq start 1;

create table if not exists public.linguistic_engagement_assessments (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default ('LENG-' || lpad(nextval('public.leng_seq')::text,5,'0')),
  job_id uuid not null references public.linguistic_jobs(id) on delete restrict,
  proposed_model text not null check (proposed_model in ('COMMUNITY_CONTRIBUTION','PAID_TASK','INDEPENDENT_CONTRACTOR','EMPLOYEE')),
  determination_status text not null default 'PENDING' check (determination_status in ('PENDING','IN_REVIEW','APPROVED','BLOCKED','SUPERSEDED')),
  legal_status text not null default 'PENDING' check (legal_status in ('PENDING','IN_REVIEW','APPROVED','BLOCKED')),
  jurisdiction text not null default 'GTM',
  factors jsonb not null default '{}'::jsonb,
  rationale text,
  reviewed_by_person_id uuid references public.persons(id) on delete set null,
  reviewed_at timestamptz,
  effective_at timestamptz,
  supersedes_id uuid references public.linguistic_engagement_assessments(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (reviewed_by_person_id is distinct from null or determination_status not in ('APPROVED','BLOCKED'))
);

create unique index if not exists linguistic_engagement_one_current_idx
on public.linguistic_engagement_assessments(job_id)
where determination_status in ('PENDING','IN_REVIEW','APPROVED');

create table if not exists public.linguistic_compensation_schedules (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default ('LRATE-' || lpad(nextval('public.lrate_seq')::text,5,'0')),
  job_id uuid not null references public.linguistic_jobs(id) on delete restrict,
  version integer not null default 1 check (version >= 1),
  task_type text not null,
  assignment_role text not null,
  compensation_mode text not null check (compensation_mode in ('NONE','MONEY','TC_CREDITS')),
  unit_type text not null default 'TASK' check (unit_type in ('TASK','APPROVED_SUBMISSION','APPROVED_REVIEW','MINUTE_AUDIO','WORD','HOUR')),
  unit_amount numeric(18,4) check (unit_amount is null or unit_amount >= 0),
  currency text,
  tc_credit_amount numeric(18,4) check (tc_credit_amount is null or tc_credit_amount >= 0),
  status text not null default 'DRAFT' check (status in ('DRAFT','PENDING_LEGAL','PENDING_APPROVAL','APPROVED','RETIRED')),
  legal_status text not null default 'PENDING' check (legal_status in ('PENDING','IN_REVIEW','APPROVED','BLOCKED')),
  effective_at timestamptz,
  retired_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(job_id,version,task_type,assignment_role),
  check ((compensation_mode='MONEY' and unit_amount is not null and currency is not null and tc_credit_amount is null)
      or (compensation_mode='TC_CREDITS' and tc_credit_amount is not null and unit_amount is null and currency is null)
      or (compensation_mode='NONE' and unit_amount is null and currency is null and tc_credit_amount is null)),
  check (status <> 'APPROVED' or legal_status='APPROVED')
);

create table if not exists public.linguistic_compensation_items (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default ('LEARN-' || lpad(nextval('public.learn_seq')::text,6,'0')),
  contributor_id uuid not null references public.linguistic_contributors(id) on delete restrict,
  schedule_id uuid not null references public.linguistic_compensation_schedules(id) on delete restrict,
  submission_id uuid references public.linguistic_task_submissions(id) on delete restrict,
  review_id uuid references public.linguistic_submission_reviews(id) on delete restrict,
  work_kind text not null check (work_kind in ('SUBMISSION','REVIEW')),
  quantity numeric(18,4) not null default 1 check (quantity > 0),
  compensation_mode text not null check (compensation_mode in ('MONEY','TC_CREDITS')),
  amount numeric(18,4),
  currency text,
  tc_credit_amount numeric(18,4),
  status text not null default 'PENDING_REVIEW' check (status in ('PENDING_REVIEW','PENDING_LEGAL','PENDING_APPROVAL','APPROVED','ISSUED','CANCELED','DISPUTED')),
  approved_by_person_id uuid references public.persons(id) on delete set null,
  approved_at timestamptz,
  issued_at timestamptz,
  external_reference text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((work_kind='SUBMISSION' and submission_id is not null and review_id is null)
      or (work_kind='REVIEW' and review_id is not null and submission_id is null)),
  check ((compensation_mode='MONEY' and amount is not null and amount >= 0 and currency is not null and tc_credit_amount is null)
      or (compensation_mode='TC_CREDITS' and tc_credit_amount is not null and tc_credit_amount >= 0 and amount is null and currency is null)),
  check (status not in ('APPROVED','ISSUED') or approved_by_person_id is not null),
  check (status <> 'ISSUED' or issued_at is not null)
);

create unique index if not exists linguistic_comp_item_submission_uidx
on public.linguistic_compensation_items(submission_id)
where submission_id is not null and status <> 'CANCELED';

create unique index if not exists linguistic_comp_item_review_uidx
on public.linguistic_compensation_items(review_id)
where review_id is not null and status <> 'CANCELED';

create or replace function public.tc_linguistic_block_unapproved_compensation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status in ('APPROVED','ISSUED') then
    if not public.tc_is_feature_enabled('linguistics.compensation') then
      raise exception 'LINGUISTIC_COMPENSATION_DISABLED' using errcode='42501';
    end if;
  end if;
  return new;
end;
$$;

revoke all on function public.tc_linguistic_block_unapproved_compensation() from public, anon, authenticated;

create trigger trg_linguistic_compensation_items_gate
before insert or update of status on public.linguistic_compensation_items
for each row execute function public.tc_linguistic_block_unapproved_compensation();

create trigger trg_linguistic_work_rewards_gate
before insert or update of status on public.linguistic_work_rewards
for each row execute function public.tc_linguistic_block_unapproved_compensation();

create or replace function public.tc_linguistic_comp_item_consistency()
returns trigger
language plpgsql
set search_path=public
as $$
declare
  v_contributor uuid;
  v_schedule public.linguistic_compensation_schedules%rowtype;
begin
  select * into v_schedule from public.linguistic_compensation_schedules where id=new.schedule_id;
  if not found or v_schedule.status <> 'APPROVED' then
    raise exception 'COMPENSATION_SCHEDULE_NOT_APPROVED';
  end if;

  if new.work_kind='SUBMISSION' then
    select a.contributor_id into v_contributor
    from public.linguistic_task_submissions s
    join public.linguistic_task_assignments a on a.id=s.assignment_id
    where s.id=new.submission_id and s.status='APPROVED';
  else
    select r.reviewer_contributor_id into v_contributor
    from public.linguistic_submission_reviews r
    where r.id=new.review_id and r.verdict in ('APPROVE','APPROVE_VARIANT') and not r.is_withdrawn;
  end if;

  if v_contributor is null then
    raise exception 'WORK_NOT_APPROVED_FOR_COMPENSATION';
  end if;
  if v_contributor <> new.contributor_id then
    raise exception 'COMPENSATION_CONTRIBUTOR_MISMATCH';
  end if;

  new.compensation_mode := v_schedule.compensation_mode;
  if v_schedule.compensation_mode='MONEY' then
    new.amount := round(v_schedule.unit_amount * new.quantity,4);
    new.currency := v_schedule.currency;
    new.tc_credit_amount := null;
  elsif v_schedule.compensation_mode='TC_CREDITS' then
    new.tc_credit_amount := round(v_schedule.tc_credit_amount * new.quantity,4);
    new.amount := null;
    new.currency := null;
  else
    raise exception 'NON_COMPENSATED_SCHEDULE';
  end if;
  return new;
end;
$$;

revoke all on function public.tc_linguistic_comp_item_consistency() from public, anon, authenticated;

create trigger trg_linguistic_comp_item_consistency
before insert or update of schedule_id,contributor_id,submission_id,review_id,quantity on public.linguistic_compensation_items
for each row execute function public.tc_linguistic_comp_item_consistency();

create or replace view public.v_linguistic_contributor_portfolio
with (security_invoker=true)
as
select
  c.id as contributor_id,
  c.public_id as contributor_public_id,
  j.public_id as job_public_id,
  j.title as job_title,
  t.public_id as task_public_id,
  t.task_type,
  a.assignment_role,
  s.public_id as submission_public_id,
  s.status as submission_status,
  s.submitted_at,
  s.reviewed_at,
  count(distinct r.id) filter (where r.verdict in ('APPROVE','APPROVE_VARIANT') and not r.is_withdrawn) as approving_reviews
from public.linguistic_contributors c
join public.linguistic_task_assignments a on a.contributor_id=c.id
join public.linguistic_tasks t on t.id=a.task_id
join public.linguistic_jobs j on j.id=t.job_id
join public.linguistic_task_submissions s on s.assignment_id=a.id and s.status='APPROVED'
left join public.linguistic_submission_reviews r on r.submission_id=s.id
group by c.id,c.public_id,j.public_id,j.title,t.public_id,t.task_type,a.assignment_role,s.public_id,s.status,s.submitted_at,s.reviewed_at;

alter table public.linguistic_engagement_assessments enable row level security;
alter table public.linguistic_compensation_schedules enable row level security;
alter table public.linguistic_compensation_items enable row level security;

revoke all on public.linguistic_engagement_assessments from anon, authenticated;
revoke all on public.linguistic_compensation_schedules from anon, authenticated;
revoke all on public.linguistic_compensation_items from anon, authenticated;
revoke all on public.v_linguistic_contributor_portfolio from anon, authenticated;

insert into public.tc_feature_gates(feature_key,domain,parent_feature_key,display_name,source_status,backend_status,safety_status,legal_status,cultural_status,approval_status,is_enabled,notes)
values
 ('linguistics.engagement_classification','LINGUISTICS','linguistics.work_program','Clasificación de vínculo laboral lingüístico','VERIFIED','VERIFIED','PENDING','PENDING','PENDING','PENDING',false,'La clasificación EMPLOYEE/CONTRACTOR/PAID_TASK/COMMUNITY no es automática y requiere revisión legal antes de uso operativo.'),
 ('linguistics.compensation_schedules','LINGUISTICS','linguistics.compensation','Tarifas y devengo de trabajo lingüístico','VERIFIED','VERIFIED','PENDING','PENDING','PENDING','PENDING',false,'Permite definir tarifas y calcular devengos; no autoriza emitir dinero ni Créditos TC.')
on conflict(feature_key) do update set
 backend_status='VERIFIED',
 is_enabled=false,
 updated_at=now();

commit;
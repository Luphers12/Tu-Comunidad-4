begin;

create table if not exists public.linguistic_assessment_review_item_scores (
  id uuid primary key default gen_random_uuid(),
  assessment_review_id uuid not null references public.linguistic_assessment_reviews(id) on delete cascade,
  template_item_id uuid not null references public.linguistic_assessment_template_items(id) on delete restrict,
  score numeric(8,2) not null check (score >= 0),
  max_score_snapshot numeric(8,2) not null check (max_score_snapshot > 0),
  reviewer_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (assessment_review_id, template_item_id),
  check (score <= max_score_snapshot)
);

alter table public.linguistic_assessment_review_item_scores enable row level security;
revoke all on public.linguistic_assessment_review_item_scores from anon, authenticated;

create or replace function public.tc_validate_assessment_item_score()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_template_id uuid;
  v_item_template_id uuid;
  v_max numeric(8,2);
begin
  select a.template_id
    into v_template_id
  from public.linguistic_assessment_reviews r
  join public.linguistic_assessment_attempts a on a.id = r.attempt_id
  where r.id = new.assessment_review_id;

  if v_template_id is null then
    raise exception 'ASSESSMENT_REVIEW_NOT_FOUND';
  end if;

  select i.template_id, i.max_score
    into v_item_template_id, v_max
  from public.linguistic_assessment_template_items i
  where i.id = new.template_item_id;

  if v_item_template_id is null or v_item_template_id <> v_template_id then
    raise exception 'ITEM_NOT_IN_ASSESSMENT_TEMPLATE';
  end if;

  new.max_score_snapshot := v_max;
  if new.score > v_max then
    raise exception 'SCORE_EXCEEDS_ITEM_MAX';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_validate_assessment_item_score on public.linguistic_assessment_review_item_scores;
create trigger trg_validate_assessment_item_score
before insert or update on public.linguistic_assessment_review_item_scores
for each row execute function public.tc_validate_assessment_item_score();

create table if not exists public.linguistic_assessment_role_evaluations (
  id uuid primary key default gen_random_uuid(),
  attempt_id uuid not null references public.linguistic_assessment_attempts(id) on delete cascade,
  role_code text not null,
  rubric_id uuid not null references public.linguistic_assessment_role_rubrics(id) on delete restrict,
  total_percent numeric(6,2),
  minimum_required_item_percent_observed numeric(6,2),
  independent_pass_reviewers integer not null default 0,
  critical_error_count integer not null default 0,
  required_competencies_met boolean not null default false,
  total_threshold_met boolean not null default false,
  item_threshold_met boolean not null default false,
  review_threshold_met boolean not null default false,
  critical_error_free boolean not null default false,
  eligibility_status text not null default 'PENDING_EVIDENCE'
    check (eligibility_status in ('PENDING_EVIDENCE','CALCULATED_ELIGIBLE','NOT_ELIGIBLE','BLOCKED_CRITICAL_ERROR')),
  calculation_details jsonb not null default '{}'::jsonb,
  calculated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (attempt_id, role_code)
);

alter table public.linguistic_assessment_role_evaluations enable row level security;
revoke all on public.linguistic_assessment_role_evaluations from anon, authenticated;

create or replace function public.tc_recalculate_linguistic_role_eligibility(p_attempt_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_template_id uuid;
  v_r record;
  v_total_percent numeric(6,2);
  v_min_required numeric(6,2);
  v_reviewers integer;
  v_critical integer;
  v_competencies_met boolean;
  v_status text;
  v_has_scores boolean;
begin
  select template_id into v_template_id
  from public.linguistic_assessment_attempts
  where id = p_attempt_id;

  if v_template_id is null then
    raise exception 'ASSESSMENT_ATTEMPT_NOT_FOUND';
  end if;

  for v_r in
    select *
    from public.linguistic_assessment_role_rubrics
    where template_id = v_template_id
      and status in ('DRAFT','APPROVED')
  loop
    select exists(
      select 1
      from public.linguistic_assessment_review_item_scores s
      join public.linguistic_assessment_reviews rv on rv.id = s.assessment_review_id
      where rv.attempt_id = p_attempt_id
        and rv.independent_attested = true
        and rv.conflict_of_interest_declared = false
        and rv.verdict = 'PASS'
    ) into v_has_scores;

    select round(
      case when sum(s.max_score_snapshot) > 0
        then 100.0 * sum(s.score) / sum(s.max_score_snapshot)
        else null end, 2)
      into v_total_percent
    from public.linguistic_assessment_review_item_scores s
    join public.linguistic_assessment_reviews rv on rv.id = s.assessment_review_id
    where rv.attempt_id = p_attempt_id
      and rv.independent_attested = true
      and rv.conflict_of_interest_declared = false
      and rv.verdict = 'PASS';

    select min(item_pct)::numeric(6,2)
      into v_min_required
    from (
      select i.id,
             round(100.0 * avg(s.score / nullif(s.max_score_snapshot,0)), 2) as item_pct
      from public.linguistic_assessment_template_items i
      join public.linguistic_assessment_review_item_scores s on s.template_item_id = i.id
      join public.linguistic_assessment_reviews rv on rv.id = s.assessment_review_id
      where i.template_id = v_template_id
        and i.is_required = true
        and rv.attempt_id = p_attempt_id
        and rv.independent_attested = true
        and rv.conflict_of_interest_declared = false
        and rv.verdict = 'PASS'
      group by i.id
    ) q;

    select count(distinct rv.reviewer_contributor_id)
      into v_reviewers
    from public.linguistic_assessment_reviews rv
    where rv.attempt_id = p_attempt_id
      and rv.independent_attested = true
      and rv.conflict_of_interest_declared = false
      and rv.verdict = 'PASS';

    select count(*)
      into v_critical
    from public.linguistic_assessment_review_errors e
    join public.linguistic_assessment_reviews rv on rv.id = e.assessment_review_id
    join public.linguistic_assessment_critical_error_catalog c on c.id = e.error_catalog_id
    where rv.attempt_id = p_attempt_id
      and c.is_active = true
      and c.blocks_role_verification = true;

    select not exists (
      select 1
      from unnest(v_r.required_competencies) rc(comp)
      where not exists (
        select 1
        from (
          select i.competency,
                 100.0 * sum(s.score) / nullif(sum(s.max_score_snapshot),0) as pct
          from public.linguistic_assessment_template_items i
          join public.linguistic_assessment_review_item_scores s on s.template_item_id = i.id
          join public.linguistic_assessment_reviews rv on rv.id = s.assessment_review_id
          where i.template_id = v_template_id
            and rv.attempt_id = p_attempt_id
            and rv.independent_attested = true
            and rv.conflict_of_interest_declared = false
            and rv.verdict = 'PASS'
          group by i.competency
        ) cs
        where cs.competency = rc.comp
          and cs.pct >= coalesce((v_r.competency_minimums ->> rc.comp)::numeric, v_r.minimum_required_item_percent)
      )
    ) into v_competencies_met;

    if v_critical > 0 and v_r.zero_critical_errors_required then
      v_status := 'BLOCKED_CRITICAL_ERROR';
    elsif not v_has_scores or v_reviewers < v_r.minimum_independent_reviews then
      v_status := 'PENDING_EVIDENCE';
    elsif coalesce(v_total_percent,0) >= v_r.minimum_total_percent
      and coalesce(v_min_required,0) >= v_r.minimum_required_item_percent
      and v_competencies_met then
      v_status := 'CALCULATED_ELIGIBLE';
    else
      v_status := 'NOT_ELIGIBLE';
    end if;

    insert into public.linguistic_assessment_role_evaluations (
      attempt_id, role_code, rubric_id, total_percent,
      minimum_required_item_percent_observed, independent_pass_reviewers,
      critical_error_count, required_competencies_met, total_threshold_met,
      item_threshold_met, review_threshold_met, critical_error_free,
      eligibility_status, calculation_details, calculated_at, updated_at
    ) values (
      p_attempt_id, v_r.role_code, v_r.id, v_total_percent,
      v_min_required, v_reviewers, v_critical, v_competencies_met,
      coalesce(v_total_percent,0) >= v_r.minimum_total_percent,
      coalesce(v_min_required,0) >= v_r.minimum_required_item_percent,
      v_reviewers >= v_r.minimum_independent_reviews,
      v_critical = 0,
      v_status,
      jsonb_build_object(
        'minimum_total_percent', v_r.minimum_total_percent,
        'minimum_required_item_percent', v_r.minimum_required_item_percent,
        'minimum_independent_reviews', v_r.minimum_independent_reviews,
        'required_competencies', v_r.required_competencies,
        'automatic_role_grant', false
      ),
      now(), now()
    )
    on conflict (attempt_id, role_code) do update set
      rubric_id = excluded.rubric_id,
      total_percent = excluded.total_percent,
      minimum_required_item_percent_observed = excluded.minimum_required_item_percent_observed,
      independent_pass_reviewers = excluded.independent_pass_reviewers,
      critical_error_count = excluded.critical_error_count,
      required_competencies_met = excluded.required_competencies_met,
      total_threshold_met = excluded.total_threshold_met,
      item_threshold_met = excluded.item_threshold_met,
      review_threshold_met = excluded.review_threshold_met,
      critical_error_free = excluded.critical_error_free,
      eligibility_status = excluded.eligibility_status,
      calculation_details = excluded.calculation_details,
      calculated_at = excluded.calculated_at,
      updated_at = now();
  end loop;
end;
$$;

revoke all on function public.tc_recalculate_linguistic_role_eligibility(uuid) from public, anon, authenticated;

insert into public.tc_feature_gates (
  feature_key, domain, parent_feature_key, display_name,
  source_status, backend_status, safety_status, legal_status, cultural_status,
  approval_status, is_enabled, notes
)
values (
  'linguistics.role_eligibility_engine','LINGUISTICS','linguistics.assessment',
  'Motor de elegibilidad de roles lingüísticos',
  'VERIFIED','VERIFIED','PENDING','PENDING','PENDING','PENDING',false,
  'Calcula elegibilidad a partir de puntajes por reactivo, revisiones independientes y errores críticos. Nunca otorga roles automáticamente.'
)
on conflict (feature_key) do update set
  backend_status='VERIFIED', is_enabled=false,
  notes=excluded.notes, updated_at=now();

commit;
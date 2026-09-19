begin;
create sequence if not exists public.lwdr_seq;
create table if not exists public.linguistic_withdrawal_requests (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default ('LWDR-' || lpad(nextval('public.lwdr_seq')::text,5,'0')),
  submission_id uuid not null references public.linguistic_task_submissions(id) on delete restrict,
  contributor_id uuid not null references public.linguistic_contributors(id) on delete restrict,
  prior_authorization_id uuid not null references public.linguistic_contribution_authorizations(id) on delete restrict,
  replacement_authorization_id uuid references public.linguistic_contribution_authorizations(id) on delete restrict,
  withdrawal_scope text not null check (withdrawal_scope in ('APP_UI_PUBLICATION','PUBLIC_AUDIO','MARKETING','RESEARCH_SHARING','THIRD_PARTY_SHARING','AI_TRAINING','VOICE_MODELING','CULTURAL_ARCHIVE','PUBLIC_ATTRIBUTION','ALL_FUTURE_USE')),
  reason text,
  reward_id uuid references public.linguistic_work_rewards(id) on delete restrict,
  reward_status_at_request text,
  compensation_effect text not null check (compensation_effect in ('NOT_APPLICABLE','NO_AUTOMATIC_REFUND','REVIEW_BEFORE_ISSUE')),
  replacement_status text not null default 'NOT_REQUIRED' check (replacement_status in ('NOT_REQUIRED','REQUIRED','IN_PROGRESS','READY','REPLACED')),
  replacement_translation_id uuid references public.translation_proposals(id) on delete restrict,
  status text not null default 'EFFECTIVE' check (status in ('REQUESTED','EFFECTIVE','PARTIALLY_EFFECTIVE','DENIED','CANCELED')),
  requested_at timestamptz not null default now(),
  effective_at timestamptz,
  resolved_at timestamptz,
  resolved_by_person_id uuid references public.persons(id) on delete restrict,
  resolution_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_linguistic_withdrawal_submission on public.linguistic_withdrawal_requests(submission_id, requested_at desc);
create index if not exists idx_linguistic_withdrawal_contributor on public.linguistic_withdrawal_requests(contributor_id, requested_at desc);
create index if not exists idx_linguistic_withdrawal_replacement on public.linguistic_withdrawal_requests(replacement_status) where replacement_status <> 'NOT_REQUIRED';
alter table public.linguistic_withdrawal_requests enable row level security;
revoke all on table public.linguistic_withdrawal_requests from anon, authenticated;
revoke all on sequence public.lwdr_seq from anon, authenticated;
alter table public.translation_proposals add column if not exists publication_status text not null default 'CANDIDATE';
alter table public.translation_proposals add column if not exists retired_at timestamptz;
alter table public.translation_proposals add column if not exists retirement_reason text;
alter table public.translation_proposals add column if not exists superseded_by_translation_id uuid references public.translation_proposals(id) on delete restrict;
do $$ begin alter table public.translation_proposals add constraint translation_proposals_publication_status_check check (publication_status in ('CANDIDATE','PUBLISHED','WITHDRAWAL_PENDING','RETIRED','SUPERSEDED')); exception when duplicate_object then null; end $$;
commit;
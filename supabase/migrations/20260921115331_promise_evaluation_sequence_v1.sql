
alter table public.logistics_promise_evaluations
  add column evaluation_seq bigint generated always as identity;

alter table public.logistics_promise_evaluations
  add constraint logistics_promise_evaluations_evaluation_seq_key
  unique (evaluation_seq);

drop index if exists public.logistics_promise_evaluations_demand_idx;

create index logistics_promise_evaluations_demand_idx
  on public.logistics_promise_evaluations(demand_id,evaluation_seq desc);

comment on column public.logistics_promise_evaluations.evaluation_seq is
'Monotonic append order for Promise evaluations. Use instead of transaction-stable timestamps when selecting the latest evaluation.';

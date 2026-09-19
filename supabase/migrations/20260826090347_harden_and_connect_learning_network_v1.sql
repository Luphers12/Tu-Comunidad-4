begin;

-- 1) Central fail-closed feature registry.
create table if not exists public.tc_feature_gates (
  id uuid primary key default gen_random_uuid(),
  feature_key text not null unique,
  domain text not null,
  parent_feature_key text null references public.tc_feature_gates(feature_key),
  display_name text not null,
  source_status text not null default 'PENDING' check (source_status in ('PENDING','VERIFIED','NOT_REQUIRED','REJECTED')),
  backend_status text not null default 'PENDING' check (backend_status in ('PENDING','VERIFIED','NOT_REQUIRED','REJECTED')),
  safety_status text not null default 'PENDING' check (safety_status in ('PENDING','APPROVED','NOT_REQUIRED','REJECTED')),
  legal_status text not null default 'PENDING' check (legal_status in ('PENDING','APPROVED','NOT_REQUIRED','REJECTED')),
  cultural_status text not null default 'PENDING' check (cultural_status in ('PENDING','APPROVED','NOT_REQUIRED','REJECTED')),
  approval_status text not null default 'PENDING' check (approval_status in ('PENDING','APPROVED','REJECTED')),
  is_enabled boolean not null default false,
  source_reference text null,
  notes text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tc_feature_gates_enable_guard check (
    not is_enabled or (
      source_status in ('VERIFIED','NOT_REQUIRED') and
      backend_status in ('VERIFIED','NOT_REQUIRED') and
      safety_status in ('APPROVED','NOT_REQUIRED') and
      legal_status in ('APPROVED','NOT_REQUIRED') and
      cultural_status in ('APPROVED','NOT_REQUIRED') and
      approval_status = 'APPROVED'
    )
  )
);

alter table public.tc_feature_gates enable row level security;
revoke all on table public.tc_feature_gates from public, anon, authenticated;

create or replace function public.tc_feature_gates_set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
revoke all on function public.tc_feature_gates_set_updated_at() from public, anon, authenticated;
drop trigger if exists trg_tc_feature_gates_updated_at on public.tc_feature_gates;
create trigger trg_tc_feature_gates_updated_at
before update on public.tc_feature_gates
for each row execute function public.tc_feature_gates_set_updated_at();

-- Register discussed modules. New/safety-sensitive capabilities remain disabled.
insert into public.tc_feature_gates(feature_key,domain,parent_feature_key,display_name,source_status,backend_status,safety_status,legal_status,cultural_status,approval_status,is_enabled,notes)
values
 ('learning.core','LEARNING',null,'Saberes de TU COMUNIDAD','PENDING','VERIFIED','PENDING','PENDING','PENDING','PENDING',false,'Architecture exists; keep disabled until contracts, RLS and approvals are complete.'),
 ('learning.microlearning','LEARNING','learning.core','Aula interactiva / microaprendizaje','PENDING','VERIFIED','PENDING','PENDING','PENDING','PENDING',false,'Short lesson/video/activity flow; not active yet.'),
 ('learning.media','LEARNING','learning.core','Videos y medios educativos','PENDING','VERIFIED','PENDING','PENDING','PENDING','PENDING',false,'Provider/media schema exists; child-safe publication requires review.'),
 ('learning.media_feedback','LEARNING','learning.media','Evaluación y sugerencias de videos','PENDING','VERIFIED','PENDING','PENDING','PENDING','PENDING',false,'Feedback storage exists but no public policy or UI activation yet.'),
 ('learning.parental_control','SAFETY','learning.core','Parental Control educativo','PENDING','VERIFIED','PENDING','PENDING','NOT_REQUIRED','PENDING',false,'Guardian relationships and media policy schema exist; disabled until approved workflows.'),
 ('learning.child_safeguarding','SAFETY','learning.core','Protección infantil y gestión de incidentes','PENDING','VERIFIED','PENDING','PENDING','NOT_REQUIRED','PENDING',false,'Human-review only. No autonomous abuse determination.'),
 ('learning.community_memory','CULTURE','learning.core','Memoria de la Comunidad / Voces de los Mayores','PENDING','VERIFIED','PENDING','PENDING','PENDING','PENDING',false,'Community knowledge can link to media; publication remains gated.'),
 ('learning.languages','LANGUAGE','learning.core','Idiomas y dialectos en aprendizaje','PENDING','VERIFIED','PENDING','PENDING','PENDING','PENDING',false,'Language schema exists; cultural/linguistic validation required.'),
 ('learning.credits_tc','ECONOMY','learning.core','Créditos TC por contribución','PENDING','PENDING','PENDING','PENDING','PENDING','PENDING',false,'No economic contract approved; never equate to money.'),
 ('learning.voice_assistant','AI','learning.core','Asistente de voz accesible','PENDING','PENDING','PENDING','PENDING','PENDING','PENDING',false,'For children, elders and accessibility; no active voice contract yet.'),
 ('learning.learn_work_sell','LEARNING','learning.core','Aprender → Trabajar → Vender','PENDING','VERIFIED','PENDING','PENDING','PENDING','PENDING',false,'Skills and certifications exist; marketplace bridge not activated.'),
 ('demand.service_interest','DEMAND',null,'Solicitudes DEM de servicio','VERIFIED','VERIFIED','NOT_REQUIRED','PENDING','NOT_REQUIRED','PENDING',false,'Backend RPCs exist; frontend activation pending final approval.')
on conflict (feature_key) do nothing;

-- 2) Connect media review to the actual educational video/media asset domain.
alter table public.learning_content_reviews
  add column if not exists media_asset_id uuid null;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname='learning_content_reviews_media_asset_id_fkey'
  ) then
    alter table public.learning_content_reviews
      add constraint learning_content_reviews_media_asset_id_fkey
      foreign key (media_asset_id) references public.learning_media_assets(id);
  end if;
end $$;
create index if not exists idx_lreview_media_asset on public.learning_content_reviews(media_asset_id);

-- Existing table is empty today; enforce exactly one review target.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname='learning_content_reviews_one_target_check'
  ) then
    alter table public.learning_content_reviews
      add constraint learning_content_reviews_one_target_check
      check (num_nonnulls(course_id, community_knowledge_id, media_asset_id) = 1);
  end if;
end $$;

-- 3) Connect educational providers to a real person/profile when provider is internal.
alter table public.learning_media_providers
  add column if not exists provider_person_id uuid null,
  add column if not exists provider_profile_id uuid null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname='learning_media_providers_provider_person_id_fkey') then
    alter table public.learning_media_providers
      add constraint learning_media_providers_provider_person_id_fkey
      foreign key (provider_person_id) references public.persons(id);
  end if;
  if not exists (select 1 from pg_constraint where conname='learning_media_providers_provider_profile_id_fkey') then
    alter table public.learning_media_providers
      add constraint learning_media_providers_provider_profile_id_fkey
      foreign key (provider_profile_id) references public.profiles(id);
  end if;
end $$;
create index if not exists idx_lmp_provider_person on public.learning_media_providers(provider_person_id);
create index if not exists idx_lmp_provider_profile on public.learning_media_providers(provider_profile_id);

-- 4) Feedback is separate from moderation/reviewer approval.
create table if not exists public.learning_media_feedback (
  id uuid primary key default gen_random_uuid(),
  media_asset_id uuid not null references public.learning_media_assets(id),
  person_id uuid not null references public.persons(id),
  rating smallint null check (rating between 1 and 5),
  feedback_type text not null default 'GENERAL' check (feedback_type in ('GENERAL','CLARITY','HELPFULNESS','CULTURAL','ACCESSIBILITY','AGE_APPROPRIATENESS')),
  feedback_text text null check (feedback_text is null or char_length(feedback_text) <= 1000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(media_asset_id, person_id, feedback_type)
);
alter table public.learning_media_feedback enable row level security;
revoke all on table public.learning_media_feedback from public, anon, authenticated;
create index if not exists idx_lmf_asset on public.learning_media_feedback(media_asset_id);
create index if not exists idx_lmf_person on public.learning_media_feedback(person_id);

-- 5) Security hardening: internal identity helpers and DEM writes must not be callable anonymously.
revoke execute on function public.current_user_person_id() from public, anon;
revoke execute on function public.current_user_profile_ids() from public, anon;
revoke execute on function public.tc_handle_new_auth_user() from public, anon, authenticated;
revoke execute on function public.tc_request_service_interest(uuid,text,text,text) from public, anon;
revoke execute on function public.tc_cancel_service_interest(text) from public, anon;
revoke execute on function public.tc_list_my_service_interests(uuid) from public, anon;
revoke execute on function public.tc_resolve_cli_profile_id() from public, anon, authenticated;

-- 6) Small scale/performance fixes identified by the database advisor.
drop policy if exists persons_self_read on public.persons;
create policy persons_self_read on public.persons for select to authenticated
using (auth_user_id = (select auth.uid()));

drop policy if exists users_self_read on public.users;
create policy users_self_read on public.users for select to authenticated
using (id = (select auth.uid()));

create index if not exists idx_audit_logs_actor_person on public.audit_logs(actor_person_id);
create index if not exists idx_audit_logs_actor_profile on public.audit_logs(actor_profile_id);
create index if not exists idx_child_actions_actor_person on public.child_safeguarding_actions(actor_person_id);
create index if not exists idx_child_cases_source_checkin on public.child_safeguarding_cases(source_checkin_id);
create index if not exists idx_child_checkins_learning_session on public.child_wellbeing_checkins(learning_session_id);

commit;
begin;

create table if not exists public.learning_media_providers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  provider_type text not null check (provider_type in ('INTERNAL','EDUCATIONAL_PARTNER','PUBLIC_INSTITUTION','APPROVED_EXTERNAL')),
  base_domain text,
  status text not null default 'PENDING' check (status in ('PENDING','APPROVED','SUSPENDED','BLOCKED')),
  child_safe_verified boolean not null default false,
  reviewed_by_person_id uuid references public.persons(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (name, base_domain)
);

create table if not exists public.learning_media_assets (
  id uuid primary key default gen_random_uuid(),
  public_id text unique,
  course_id uuid references public.learning_courses(id) on delete set null,
  lesson_id uuid references public.learning_lessons(id) on delete set null,
  community_knowledge_id uuid references public.community_knowledge(id) on delete set null,
  provider_id uuid references public.learning_media_providers(id),
  media_type text not null check (media_type in ('VIDEO','AUDIO','ANIMATION','INTERACTIVE')),
  source_type text not null check (source_type in ('INTERNAL_STORAGE','APPROVED_EXTERNAL')),
  source_url text,
  storage_path text,
  title text not null,
  description text,
  duration_seconds integer check (duration_seconds is null or duration_seconds >= 0),
  min_age integer check (min_age is null or min_age >= 0),
  max_age integer check (max_age is null or max_age >= 0),
  primary_language_id uuid references public.languages(id),
  primary_language_variant_id uuid references public.language_variants(id),
  community_id uuid references public.communities(id),
  topics text[] not null default '{}',
  learning_objectives text[] not null default '{}',
  moderation_status text not null default 'PENDING' check (moderation_status in ('PENDING','APPROVED','REJECTED','SUSPENDED')),
  child_safe boolean not null default false,
  ads_allowed boolean not null default false,
  external_links_allowed boolean not null default false,
  comments_allowed boolean not null default false,
  direct_messages_allowed boolean not null default false,
  autoplay_next boolean not null default false,
  downloadable boolean not null default false,
  requires_followup_activity boolean not null default true,
  created_by_person_id uuid references public.persons(id),
  reviewed_by_person_id uuid references public.persons(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (max_age is null or min_age is null or max_age >= min_age),
  check ((source_type = 'INTERNAL_STORAGE' and storage_path is not null) or (source_type = 'APPROVED_EXTERNAL' and source_url is not null))
);

create table if not exists public.learning_media_localizations (
  id uuid primary key default gen_random_uuid(),
  media_asset_id uuid not null references public.learning_media_assets(id) on delete cascade,
  language_id uuid not null references public.languages(id),
  language_variant_id uuid references public.language_variants(id),
  community_id uuid references public.communities(id),
  localized_title text,
  localized_description text,
  transcript text,
  subtitle_path text,
  dubbed_audio_path text,
  status text not null default 'PENDING' check (status in ('PENDING','APPROVED','REJECTED','SUSPENDED')),
  reviewed_by_person_id uuid references public.persons(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.parental_media_policies (
  id uuid primary key default gen_random_uuid(),
  guardian_relationship_id uuid not null unique references public.guardian_relationships(id) on delete cascade,
  educational_only boolean not null default true,
  approved_content_only boolean not null default true,
  max_daily_minutes integer check (max_daily_minutes is null or max_daily_minutes >= 0),
  max_session_minutes integer check (max_session_minutes is null or max_session_minutes >= 0),
  break_after_minutes integer check (break_after_minutes is null or break_after_minutes > 0),
  break_duration_minutes integer check (break_duration_minutes is null or break_duration_minutes > 0),
  allowed_start time,
  allowed_end time,
  quiet_hours_enabled boolean not null default false,
  quiet_start time,
  quiet_end time,
  autoplay_allowed boolean not null default false,
  external_links_allowed boolean not null default false,
  comments_allowed boolean not null default false,
  direct_messages_allowed boolean not null default false,
  purchases_allowed boolean not null default false,
  camera_allowed boolean not null default false,
  microphone_allowed boolean not null default false,
  location_allowed boolean not null default false,
  require_followup_activity boolean not null default true,
  guardian_pin_required boolean not null default true,
  updated_by_person_id uuid references public.persons(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.learning_playlists (
  id uuid primary key default gen_random_uuid(),
  public_id text unique,
  title text not null,
  description text,
  curator_person_id uuid references public.persons(id),
  community_id uuid references public.communities(id),
  min_age integer check (min_age is null or min_age >= 0),
  max_age integer check (max_age is null or max_age >= 0),
  moderation_status text not null default 'PENDING' check (moderation_status in ('PENDING','APPROVED','REJECTED','SUSPENDED')),
  child_safe boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (max_age is null or min_age is null or max_age >= min_age)
);

create table if not exists public.learning_playlist_items (
  id uuid primary key default gen_random_uuid(),
  playlist_id uuid not null references public.learning_playlists(id) on delete cascade,
  media_asset_id uuid not null references public.learning_media_assets(id) on delete cascade,
  position integer not null check (position > 0),
  created_at timestamptz not null default now(),
  unique (playlist_id, position),
  unique (playlist_id, media_asset_id)
);

create table if not exists public.learning_media_sessions (
  id uuid primary key default gen_random_uuid(),
  student_person_id uuid not null references public.persons(id) on delete cascade,
  media_asset_id uuid not null references public.learning_media_assets(id),
  guardian_relationship_id uuid references public.guardian_relationships(id),
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  watched_seconds integer not null default 0 check (watched_seconds >= 0),
  completion_percent numeric(5,2) not null default 0 check (completion_percent >= 0 and completion_percent <= 100),
  stop_reason text check (stop_reason is null or stop_reason in ('COMPLETE','LIMIT_REACHED','BREAK_REQUIRED','QUIET_HOURS','MANUAL','CONTENT_BLOCKED')),
  followup_completed boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.learning_content_reports (
  id uuid primary key default gen_random_uuid(),
  media_asset_id uuid not null references public.learning_media_assets(id) on delete cascade,
  reporter_person_id uuid references public.persons(id),
  reason text not null check (reason in ('NOT_EDUCATIONAL','AGE_INAPPROPRIATE','HARMFUL','PRIVACY','ADS','EXTERNAL_LINK','CULTURAL_ERROR','LANGUAGE_ERROR','OTHER')),
  details text,
  status text not null default 'OPEN' check (status in ('OPEN','UNDER_REVIEW','RESOLVED','DISMISSED')),
  reviewed_by_person_id uuid references public.persons(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Fail closed: all child/media tables require explicit policies before client access.
alter table public.learning_media_providers enable row level security;
alter table public.learning_media_assets enable row level security;
alter table public.learning_media_localizations enable row level security;
alter table public.parental_media_policies enable row level security;
alter table public.learning_playlists enable row level security;
alter table public.learning_playlist_items enable row level security;
alter table public.learning_media_sessions enable row level security;
alter table public.learning_content_reports enable row level security;

-- New module indexes.
create index if not exists idx_lmp_reviewed_by on public.learning_media_providers(reviewed_by_person_id);
create index if not exists idx_lma_course on public.learning_media_assets(course_id);
create index if not exists idx_lma_lesson on public.learning_media_assets(lesson_id);
create index if not exists idx_lma_knowledge on public.learning_media_assets(community_knowledge_id);
create index if not exists idx_lma_provider on public.learning_media_assets(provider_id);
create index if not exists idx_lma_language on public.learning_media_assets(primary_language_id);
create index if not exists idx_lma_variant on public.learning_media_assets(primary_language_variant_id);
create index if not exists idx_lma_community on public.learning_media_assets(community_id);
create index if not exists idx_lma_creator on public.learning_media_assets(created_by_person_id);
create index if not exists idx_lma_reviewer on public.learning_media_assets(reviewed_by_person_id);
create index if not exists idx_lma_child_approved on public.learning_media_assets(child_safe, moderation_status, min_age, max_age);
create index if not exists idx_lml_asset on public.learning_media_localizations(media_asset_id);
create index if not exists idx_lml_language on public.learning_media_localizations(language_id);
create index if not exists idx_lml_variant on public.learning_media_localizations(language_variant_id);
create index if not exists idx_lml_community on public.learning_media_localizations(community_id);
create index if not exists idx_lml_reviewer on public.learning_media_localizations(reviewed_by_person_id);
create index if not exists idx_pmp_updated_by on public.parental_media_policies(updated_by_person_id);
create index if not exists idx_lp_curator on public.learning_playlists(curator_person_id);
create index if not exists idx_lp_community on public.learning_playlists(community_id);
create index if not exists idx_lpi_asset on public.learning_playlist_items(media_asset_id);
create index if not exists idx_lms_student_started on public.learning_media_sessions(student_person_id, started_at desc);
create index if not exists idx_lms_asset on public.learning_media_sessions(media_asset_id);
create index if not exists idx_lms_guardian on public.learning_media_sessions(guardian_relationship_id);
create index if not exists idx_lcr_asset on public.learning_content_reports(media_asset_id);
create index if not exists idx_lcr_reporter on public.learning_content_reports(reporter_person_id);
create index if not exists idx_lcr_reviewer on public.learning_content_reports(reviewed_by_person_id);

-- Cover the missing FK indexes in the first Saberes migration before usage grows.
create index if not exists idx_ck_contributor on public.community_knowledge(contributor_person_id);
create index if not exists idx_ck_language on public.community_knowledge(language_id);
create index if not exists idx_ck_variant on public.community_knowledge(language_variant_id);
create index if not exists idx_laa_assessment on public.learning_assessment_attempts(assessment_id);
create index if not exists idx_laa_person on public.learning_assessment_attempts(person_id);
create index if not exists idx_la_course on public.learning_assessments(course_id);
create index if not exists idx_la_lesson on public.learning_assessments(lesson_id);
create index if not exists idx_lcenter_community on public.learning_centers(community_id);
create index if not exists idx_lcenter_ptc on public.learning_centers(ptc_point_id);
create index if not exists idx_lcert_course on public.learning_certifications(course_id);
create index if not exists idx_lcert_person on public.learning_certifications(person_id);
create index if not exists idx_lcert_skill on public.learning_certifications(skill_id);
create index if not exists idx_lreview_knowledge on public.learning_content_reviews(community_knowledge_id);
create index if not exists idx_lreview_course on public.learning_content_reviews(course_id);
create index if not exists idx_lreview_reviewer on public.learning_content_reviews(reviewer_person_id);
create index if not exists idx_lcourse_creator on public.learning_courses(created_by_person_id);
create index if not exists idx_lcourse_language on public.learning_courses(primary_language_id);
create index if not exists idx_lcourse_variant on public.learning_courses(primary_language_variant_id);
create index if not exists idx_lenroll_course on public.learning_enrollments(course_id);
create index if not exists idx_lenroll_guardian on public.learning_enrollments(guardian_relationship_id);
create index if not exists idx_lprofile_community on public.learning_profiles(community_id);
create index if not exists idx_lprofile_language on public.learning_profiles(preferred_language_id);
create index if not exists idx_lprofile_variant on public.learning_profiles(preferred_language_variant_id);
create index if not exists idx_lprofile_primary_profile on public.learning_profiles(primary_profile_id);
create index if not exists idx_lprogress_lesson on public.learning_progress(lesson_id);
create index if not exists idx_lskills_community on public.learning_skills(community_id);
create index if not exists idx_parental_permissions_updated_by on public.parental_permissions(updated_by_person_id);
create index if not exists idx_person_skills_skill on public.person_skills(skill_id);
create index if not exists idx_person_skills_verifier on public.person_skills(verified_by_person_id);

commit;
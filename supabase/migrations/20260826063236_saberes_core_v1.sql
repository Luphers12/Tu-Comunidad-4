create extension if not exists pgcrypto;

create table if not exists public.learning_profiles (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references public.persons(id) on delete cascade,
  primary_profile_id uuid references public.profiles(id) on delete set null,
  role_type text not null check (role_type in ('STUDENT','TEACHER','TUTOR','GUARDIAN','TRADE_INSTRUCTOR','COMMUNITY_KNOWLEDGE_HOLDER','LINGUISTIC_VALIDATOR','CONTENT_REVIEWER','EDUCATION_COORDINATOR','SABERES_ADMIN')),
  birth_date date,
  age_stage text,
  education_level text,
  learning_level text,
  community_id uuid references public.communities(id) on delete set null,
  preferred_language_id uuid references public.languages(id) on delete set null,
  preferred_language_variant_id uuid references public.language_variants(id) on delete set null,
  accessibility_preferences jsonb not null default '{}'::jsonb,
  learning_goals jsonb not null default '[]'::jsonb,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(person_id, role_type)
);

create table if not exists public.guardian_relationships (
  id uuid primary key default gen_random_uuid(),
  guardian_person_id uuid not null references public.persons(id) on delete cascade,
  student_person_id uuid not null references public.persons(id) on delete cascade,
  relationship_type text not null,
  legal_authority_status text not null default 'PENDING' check (legal_authority_status in ('PENDING','VERIFIED','REVOKED','EXPIRED')),
  can_view_progress boolean not null default true,
  can_manage_enrollments boolean not null default false,
  can_manage_communications boolean not null default false,
  can_manage_learning_spend boolean not null default false,
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (guardian_person_id <> student_person_id),
  unique(guardian_person_id, student_person_id)
);

create table if not exists public.parental_permissions (
  id uuid primary key default gen_random_uuid(),
  guardian_relationship_id uuid not null references public.guardian_relationships(id) on delete cascade,
  permission_key text not null,
  is_allowed boolean not null default false,
  settings jsonb not null default '{}'::jsonb,
  updated_by_person_id uuid references public.persons(id) on delete set null,
  updated_at timestamptz not null default now(),
  unique(guardian_relationship_id, permission_key)
);

create table if not exists public.learning_courses (
  id uuid primary key default gen_random_uuid(),
  public_id text unique,
  title text not null,
  description text,
  course_type text not null default 'GENERAL',
  target_age_stage text,
  difficulty_level text,
  primary_language_id uuid references public.languages(id) on delete set null,
  primary_language_variant_id uuid references public.language_variants(id) on delete set null,
  community_id uuid references public.communities(id) on delete set null,
  culture_tags text[] not null default '{}',
  requires_guardian_approval boolean not null default false,
  is_offline_ready boolean not null default false,
  status text not null default 'DRAFT' check (status in ('DRAFT','REVIEW','PUBLISHED','ARCHIVED')),
  created_by_person_id uuid references public.persons(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.learning_lessons (
  id uuid primary key default gen_random_uuid(),
  course_id uuid not null references public.learning_courses(id) on delete cascade,
  title text not null,
  lesson_order integer not null check (lesson_order > 0),
  lesson_type text not null default 'MIXED',
  content jsonb not null default '{}'::jsonb,
  estimated_minutes integer check (estimated_minutes is null or estimated_minutes >= 0),
  xp_reward integer not null default 0 check (xp_reward >= 0),
  is_required boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(course_id, lesson_order)
);

create table if not exists public.learning_enrollments (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references public.persons(id) on delete cascade,
  course_id uuid not null references public.learning_courses(id) on delete cascade,
  status text not null default 'ACTIVE' check (status in ('PENDING_APPROVAL','ACTIVE','PAUSED','COMPLETED','WITHDRAWN')),
  enrolled_at timestamptz not null default now(),
  completed_at timestamptz,
  guardian_relationship_id uuid references public.guardian_relationships(id) on delete set null,
  unique(person_id, course_id)
);

create table if not exists public.learning_progress (
  id uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references public.learning_enrollments(id) on delete cascade,
  lesson_id uuid not null references public.learning_lessons(id) on delete cascade,
  status text not null default 'NOT_STARTED' check (status in ('NOT_STARTED','IN_PROGRESS','COMPLETED','MASTERED')),
  progress_percent numeric(5,2) not null default 0 check (progress_percent between 0 and 100),
  xp_earned integer not null default 0 check (xp_earned >= 0),
  attempts integer not null default 0 check (attempts >= 0),
  last_activity_at timestamptz,
  completed_at timestamptz,
  unique(enrollment_id, lesson_id)
);

create table if not exists public.learning_assessments (
  id uuid primary key default gen_random_uuid(),
  course_id uuid references public.learning_courses(id) on delete cascade,
  lesson_id uuid references public.learning_lessons(id) on delete cascade,
  title text not null,
  assessment_type text not null default 'QUIZ',
  passing_score numeric(5,2) check (passing_score is null or passing_score between 0 and 100),
  max_attempts integer check (max_attempts is null or max_attempts > 0),
  config jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  check (course_id is not null or lesson_id is not null)
);

create table if not exists public.learning_assessment_attempts (
  id uuid primary key default gen_random_uuid(),
  assessment_id uuid not null references public.learning_assessments(id) on delete cascade,
  person_id uuid not null references public.persons(id) on delete cascade,
  score numeric(5,2) check (score is null or score between 0 and 100),
  passed boolean,
  answers jsonb not null default '{}'::jsonb,
  started_at timestamptz not null default now(),
  completed_at timestamptz
);

create table if not exists public.learning_skills (
  id uuid primary key default gen_random_uuid(),
  public_id text unique,
  name text not null,
  category text not null,
  description text,
  community_id uuid references public.communities(id) on delete set null,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.person_skills (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references public.persons(id) on delete cascade,
  skill_id uuid not null references public.learning_skills(id) on delete cascade,
  level text,
  verification_status text not null default 'SELF_REPORTED' check (verification_status in ('SELF_REPORTED','ASSESSED','VERIFIED','EXPIRED')),
  verified_by_person_id uuid references public.persons(id) on delete set null,
  evidence jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  unique(person_id, skill_id)
);

create table if not exists public.learning_certifications (
  id uuid primary key default gen_random_uuid(),
  public_id text unique,
  person_id uuid not null references public.persons(id) on delete cascade,
  course_id uuid references public.learning_courses(id) on delete set null,
  skill_id uuid references public.learning_skills(id) on delete set null,
  title text not null,
  issued_at timestamptz not null default now(),
  expires_at timestamptz,
  status text not null default 'ACTIVE' check (status in ('ACTIVE','EXPIRED','REVOKED')),
  verification_data jsonb not null default '{}'::jsonb
);

create table if not exists public.community_knowledge (
  id uuid primary key default gen_random_uuid(),
  public_id text unique,
  title text not null,
  knowledge_type text not null,
  community_id uuid references public.communities(id) on delete set null,
  language_id uuid references public.languages(id) on delete set null,
  language_variant_id uuid references public.language_variants(id) on delete set null,
  contributor_person_id uuid references public.persons(id) on delete set null,
  cultural_access_level text not null default 'PUBLIC' check (cultural_access_level in ('PUBLIC','COMMUNITY','RESTRICTED','NON_COMMERCIAL')),
  content jsonb not null default '{}'::jsonb,
  validation_status text not null default 'PENDING' check (validation_status in ('PENDING','REVIEWED','VERIFIED','REJECTED','ARCHIVED')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.learning_content_reviews (
  id uuid primary key default gen_random_uuid(),
  course_id uuid references public.learning_courses(id) on delete cascade,
  community_knowledge_id uuid references public.community_knowledge(id) on delete cascade,
  reviewer_person_id uuid not null references public.persons(id) on delete cascade,
  review_type text not null,
  decision text not null check (decision in ('APPROVE','CHANGES_REQUESTED','REJECT')),
  notes text,
  created_at timestamptz not null default now(),
  check (course_id is not null or community_knowledge_id is not null)
);

create table if not exists public.learning_centers (
  id uuid primary key default gen_random_uuid(),
  public_id text unique,
  name text not null,
  community_id uuid not null references public.communities(id) on delete cascade,
  ptc_point_id uuid references public.ptc_points(id) on delete set null,
  center_type text not null default 'COMMUNITY',
  supports_offline boolean not null default false,
  capabilities jsonb not null default '{}'::jsonb,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_learning_profiles_person on public.learning_profiles(person_id);
create index if not exists idx_guardian_student on public.guardian_relationships(student_person_id);
create index if not exists idx_courses_community on public.learning_courses(community_id);
create index if not exists idx_enrollments_person on public.learning_enrollments(person_id);
create index if not exists idx_progress_enrollment on public.learning_progress(enrollment_id);
create index if not exists idx_person_skills_person on public.person_skills(person_id);
create index if not exists idx_community_knowledge_community on public.community_knowledge(community_id);

alter table public.learning_profiles enable row level security;
alter table public.guardian_relationships enable row level security;
alter table public.parental_permissions enable row level security;
alter table public.learning_courses enable row level security;
alter table public.learning_lessons enable row level security;
alter table public.learning_enrollments enable row level security;
alter table public.learning_progress enable row level security;
alter table public.learning_assessments enable row level security;
alter table public.learning_assessment_attempts enable row level security;
alter table public.learning_skills enable row level security;
alter table public.person_skills enable row level security;
alter table public.learning_certifications enable row level security;
alter table public.community_knowledge enable row level security;
alter table public.learning_content_reviews enable row level security;
alter table public.learning_centers enable row level security;

create policy learning_profiles_self_select on public.learning_profiles
for select to authenticated
using (exists (select 1 from public.persons p where p.id = learning_profiles.person_id and p.auth_user_id = (select auth.uid())));

create policy guardian_relationships_party_select on public.guardian_relationships
for select to authenticated
using (exists (select 1 from public.persons p where p.auth_user_id = (select auth.uid()) and p.id in (guardian_relationships.guardian_person_id, guardian_relationships.student_person_id)));

create policy published_courses_select on public.learning_courses
for select to authenticated
using (status = 'PUBLISHED' or exists (select 1 from public.persons p where p.id = learning_courses.created_by_person_id and p.auth_user_id = (select auth.uid())));

create policy published_course_lessons_select on public.learning_lessons
for select to authenticated
using (exists (select 1 from public.learning_courses c where c.id = learning_lessons.course_id and c.status = 'PUBLISHED'));

create policy enrollments_self_select on public.learning_enrollments
for select to authenticated
using (exists (select 1 from public.persons p where p.id = learning_enrollments.person_id and p.auth_user_id = (select auth.uid())));

create policy assessment_attempts_self_select on public.learning_assessment_attempts
for select to authenticated
using (exists (select 1 from public.persons p where p.id = learning_assessment_attempts.person_id and p.auth_user_id = (select auth.uid())));

create policy person_skills_self_select on public.person_skills
for select to authenticated
using (exists (select 1 from public.persons p where p.id = person_skills.person_id and p.auth_user_id = (select auth.uid())));

create policy certifications_self_select on public.learning_certifications
for select to authenticated
using (exists (select 1 from public.persons p where p.id = learning_certifications.person_id and p.auth_user_id = (select auth.uid())));

create policy public_verified_community_knowledge_select on public.community_knowledge
for select to authenticated
using (validation_status = 'VERIFIED' and cultural_access_level = 'PUBLIC');

create policy active_learning_centers_select on public.learning_centers
for select to authenticated
using (is_active = true);
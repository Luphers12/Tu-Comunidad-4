begin;

create table if not exists public.tc_minor_data_protection_policies (
  id uuid primary key default gen_random_uuid(),
  policy_code text not null unique,
  title text not null,
  statement text not null,
  status text not null default 'DESIGN_APPROVED' check (status in ('DRAFT','DESIGN_APPROVED','LEGAL_VERIFIED','RETIRED')),
  legal_status text not null default 'PENDING' check (legal_status in ('PENDING','APPROVED','REJECTED')),
  created_at timestamptz not null default now()
);

alter table public.tc_minor_data_protection_policies enable row level security;
revoke all on public.tc_minor_data_protection_policies from anon, authenticated;

insert into public.tc_minor_data_protection_policies(policy_code,title,statement,status,legal_status)
values
('MINOR_PROFILE_CONTAINMENT','Datos del menor contenidos en su espacio protegido','Los datos detallados de una persona menor de edad permanecen dentro de su espacio protegido y de los espacios de sus padres, madres o tutores legalmente autorizados. Ningún rol de gobernanza, seguridad, operaciones, IA u otro recibe acceso general por razón de su cargo.','DESIGN_APPROVED','PENDING'),
('MINIMAL_PROTECTION_SIGNAL','Solo sale una señal mínima de protección','Cuando exista una señal que requiera protección, fuera del espacio protegido del menor solo podrá circular la mínima información operativa necesaria: identificador opaco de señal, categoría general de riesgo, nivel, fecha, estado y necesidad de revisión. La señal no contiene por defecto nombre, texto, audio, imagen, ubicación exacta, conversación ni otra evidencia del menor.','DESIGN_APPROVED','PENDING'),
('SIGNAL_NOT_FINDING','Una señal no es una conclusión','Una señal de protección indica necesidad de revisión y no constituye por sí sola una acusación, diagnóstico, culpabilidad ni conclusión definitiva.','DESIGN_APPROVED','PENDING')
on conflict (policy_code) do nothing;

create table if not exists public.tc_minor_protection_signals (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('SIG'),
  signal_type text not null check (signal_type in ('SAFETY','WELLBEING','CONTACT_RISK','PRIVACY','LOCATION_RISK','EXPLOITATION_RISK','ABUSE_RISK','OTHER_PROTECTED')),
  severity text not null check (severity in ('LOW','MEDIUM','HIGH','CRITICAL')),
  status text not null default 'OPEN' check (status in ('OPEN','TRIAGE','PROTECTED_REVIEW','RESOLVED','FALSE_POSITIVE','ESCALATED')),
  detected_at timestamptz not null default now(),
  requires_human_review boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.tc_minor_protection_signal_private (
  signal_id uuid primary key references public.tc_minor_protection_signals(id) on delete restrict,
  student_person_id uuid not null references public.persons(id) on delete restrict,
  source_entity_type text,
  source_entity_id uuid,
  protected_context jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.tc_minor_protection_signals enable row level security;
alter table public.tc_minor_protection_signal_private enable row level security;
revoke all on public.tc_minor_protection_signals from anon, authenticated;
revoke all on public.tc_minor_protection_signal_private from anon, authenticated;

create or replace function public.tc_block_minor_signal_identity_leak()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if to_jsonb(new) ?| array['student_person_id','person_id','minor_person_id','name','full_name','email','phone','address','location','latitude','longitude','text','message','audio','image','conversation','evidence'] then
    raise exception 'MINOR_SIGNAL_MUST_NOT_CONTAIN_IDENTIFYING_OR_CONTENT_DATA';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_tc_minor_signal_identity_leak on public.tc_minor_protection_signals;
create trigger trg_tc_minor_signal_identity_leak
before insert or update on public.tc_minor_protection_signals
for each row execute function public.tc_block_minor_signal_identity_leak();

insert into public.tc_feature_gates(
  feature_key,domain,display_name,source_status,backend_status,safety_status,legal_status,cultural_status,approval_status,is_enabled,notes
)
values (
  'safety.minor_protection_signals','SAFETY','Señales mínimas de protección de menores',
  'PENDING','VERIFIED','PENDING','PENDING','PENDING','PENDING',false,
  'Arquitectura fail-closed. Los datos detallados permanecen en el espacio protegido del menor/tutores. Solo la señal mínima puede salir. No activar hasta definir procedimiento humano, RLS/RPC de triage y revisión legal.'
)
on conflict (feature_key) do update set
  backend_status='VERIFIED',
  is_enabled=false,
  notes=excluded.notes,
  updated_at=now();

commit;
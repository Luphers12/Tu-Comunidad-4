begin;

insert into public.tc_governance_seat_catalog (
  seat_code, title, purpose,
  is_mission_guardian, is_community_voice, is_cultural_data_custodian,
  is_independent, expandable_by_territory, status, legal_status
)
select
  'SAFETY_WELLBEING_STEWARD',
  'Custodia de Seguridad, Bienestar y Protección de Menores',
  'Protege la seguridad y el bienestar de participantes, con responsabilidad reforzada sobre menores de edad. Revisa señales de riesgo, salvaguardas, escalamiento, acceso excepcional y debido proceso sin recibir acceso general a la bóveda del menor.',
  false, false, false, true, false, 'DESIGN_APPROVED', 'PENDING'
where not exists (
  select 1 from public.tc_governance_seat_catalog where seat_code='SAFETY_WELLBEING_STEWARD'
);

insert into public.tc_governance_eligibility_roles (
  role_code, seat_id, display_name, purpose, requirements_summary, status, legal_status
)
select
  'SAFETY_WELLBEING_STEWARD_ELIGIBLE', s.id,
  'Elegible para Custodia de Seguridad, Bienestar y Protección de Menores',
  'Elegibilidad específica para ocupar el asiento de seguridad y protección de menores.',
  'Debe demostrar formación, experiencia o competencia verificable en protección, seguridad, bienestar, debido proceso y manejo de información sensible; comprender límites de acceso, conflictos de interés, escalamiento y obligaciones de protección. No se obtiene por ser cliente, administrador o por otra función ordinaria.',
  'DESIGN_APPROVED','PENDING'
from public.tc_governance_seat_catalog s
where s.seat_code='SAFETY_WELLBEING_STEWARD'
  and not exists (
    select 1 from public.tc_governance_eligibility_roles r where r.role_code='SAFETY_WELLBEING_STEWARD_ELIGIBLE'
  );

create table if not exists public.tc_governance_workspace_sections (
  id uuid primary key default gen_random_uuid(),
  seat_id uuid not null references public.tc_governance_seat_catalog(id) on delete restrict,
  section_code text not null,
  title text not null,
  purpose text not null,
  access_class text not null default 'MINIMAL' check (access_class in ('MINIMAL','PROTECTED','HIGH_RISK_ONLY','AUDIT_ONLY')),
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(seat_id, section_code)
);

alter table public.tc_governance_workspace_sections enable row level security;
revoke all on public.tc_governance_workspace_sections from anon, authenticated;

do $$
declare v_seat uuid;
begin
  select id into v_seat from public.tc_governance_seat_catalog where seat_code='SAFETY_WELLBEING_STEWARD';

  insert into public.tc_governance_workspace_sections(seat_id,section_code,title,purpose,access_class,sort_order)
  values
    (v_seat,'PROTECTION_SIGNAL_QUEUE','Señales de protección','Cola de señales mínimas que requieren evaluación humana. No contiene automáticamente el contenido privado del menor.','MINIMAL',10),
    (v_seat,'HIGH_RISK_DISCLOSURES','Accesos excepcionales','Solicitudes HIGH/CRITICAL para revelar únicamente información estrictamente necesaria y por tiempo limitado.','HIGH_RISK_ONLY',20),
    (v_seat,'SAFE_HELP_CHANNEL','Solicitudes de ayuda','Seguimiento de solicitudes de ayuda iniciadas por menores o tutores sin convertirlas automáticamente en acusaciones.','PROTECTED',30),
    (v_seat,'GUARDIAN_COORDINATION','Coordinación con tutores','Estado de coordinación con padres o tutores autorizados cuando corresponda y sea seguro hacerlo.','PROTECTED',40),
    (v_seat,'CONFLICTS_RECUSALS','Conflictos y recusaciones','Conflictos de interés, recusaciones y sustituciones para impedir autorrevisión o acceso impropio.','AUDIT_ONLY',50),
    (v_seat,'POST_EMERGENCY_REVIEW','Revisión posterior','Revisión obligatoria de accesos o decisiones de emergencia, incluyendo necesidad, alcance y duración.','AUDIT_ONLY',60),
    (v_seat,'SAFETY_POLICY','Políticas y salvaguardas','Cambios de política de protección infantil, límites de IA y reglas de escalamiento.','MINIMAL',70)
  on conflict(seat_id,section_code) do nothing;
end $$;

create table if not exists public.tc_minor_protection_severity_policies (
  severity text primary key check (severity in ('LOW','MEDIUM','HIGH','CRITICAL')),
  public_label text not null,
  description text not null,
  minimum_response text not null,
  additional_vault_disclosure_allowed boolean not null default false,
  requires_human_review boolean not null default true,
  requires_post_action_review boolean not null default false,
  emergency_path_allowed boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.tc_minor_protection_severity_policies enable row level security;
revoke all on public.tc_minor_protection_severity_policies from anon, authenticated;

insert into public.tc_minor_protection_severity_policies(
  severity,public_label,description,minimum_response,additional_vault_disclosure_allowed,
  requires_human_review,requires_post_action_review,emergency_path_allowed
) values
  ('LOW','Informativa','Señal débil o preventiva sin indicios suficientes de peligro inmediato.','Registrar señal mínima y observar según política.',false,true,false,false),
  ('MEDIUM','Preocupación','Existe una preocupación que requiere revisión humana, pero no justifica revelar datos adicionales de la bóveda.','Revisión protegida y coordinación autorizada cuando corresponda.',false,true,false,false),
  ('HIGH','Alto riesgo','Existe información razonable de un riesgo importante que puede requerir datos adicionales para proteger al menor.','Revisión prioritaria; revelación excepcional solo por necesidad y alcance mínimo.',true,true,true,false),
  ('CRITICAL','Crítico','Existe posible peligro grave o inmediato que exige respuesta prioritaria.','Respuesta prioritaria; puede usar vía de emergencia de alcance mínimo con revisión posterior obligatoria.',true,true,true,true)
on conflict(severity) do update set
  public_label=excluded.public_label,
  description=excluded.description,
  minimum_response=excluded.minimum_response,
  additional_vault_disclosure_allowed=excluded.additional_vault_disclosure_allowed,
  requires_human_review=excluded.requires_human_review,
  requires_post_action_review=excluded.requires_post_action_review,
  emergency_path_allowed=excluded.emergency_path_allowed;

create table if not exists public.tc_minor_help_requests (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default public.tc_generate_public_id('MHR'),
  student_person_id uuid not null references public.persons(id) on delete restrict,
  guardian_relationship_id uuid null references public.guardian_relationships(id) on delete set null,
  initiated_by text not null check (initiated_by in ('MINOR','AUTHORIZED_GUARDIAN','SYSTEM_ASSISTED')),
  help_type text not null check (help_type in ('NEED_HELP','FEEL_UNSAFE','CONTACT_GUARDIAN','PRIVACY_CONCERN','OTHER_PROTECTED')),
  protected_message text null,
  status text not null default 'OPEN' check (status in ('OPEN','TRIAGE','ESCALATED','RESOLVED','CANCELLED')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.tc_minor_help_requests enable row level security;
revoke all on public.tc_minor_help_requests from anon, authenticated;

create table if not exists public.tc_minor_protection_principles (
  principle_code text primary key,
  title text not null,
  statement text not null,
  is_foundational boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.tc_minor_protection_principles enable row level security;
revoke all on public.tc_minor_protection_principles from anon, authenticated;

insert into public.tc_minor_protection_principles(principle_code,title,statement,is_foundational)
values
('MINOR_DATA_VAULT','Bóveda del menor','Los datos completos del menor permanecen en su espacio protegido y en el de sus padres o tutores autorizados, salvo revelación excepcional y mínima en un caso HIGH o CRITICAL.',true),
('MINIMUM_NECESSARY_DISCLOSURE','Mínima revelación necesaria','Incluso en alto riesgo, solo puede revelarse la información estrictamente necesaria para proteger al menor; alto riesgo no equivale a abrir toda la bóveda.',true),
('TIME_LIMITED_ACCESS','Acceso temporal','Todo acceso excepcional debe tener alcance y duración limitados, motivo documentado y revocación o expiración.',true),
('POST_EMERGENCY_REVIEW','Revisión después de emergencia','Toda vía de emergencia debe revisarse posteriormente para comprobar necesidad, proporcionalidad, alcance y cumplimiento.',true),
('AI_SIGNAL_NOT_VERDICT','La IA señala, no sentencia','La IA puede detectar patrones o generar señales de protección, pero no puede declarar que una persona es culpable, abusadora o peligrosa ni resolver por sí sola un caso de protección infantil.',true),
('NO_CHILD_SURVEILLANCE','Protección sin vigilancia general','TU COMUNIDAD no debe convertir la protección infantil en vigilancia general de la vida del menor. Solo procesa lo necesario para el servicio y para señales legítimas de protección.',true),
('HELP_REQUEST_NOT_ACCUSATION','Pedir ayuda no es una acusación','Una solicitud de ayuda o una señal de riesgo activa protección y revisión, pero no constituye por sí sola una acusación ni una conclusión de hechos.',true)
on conflict(principle_code) do nothing;

do $$
declare v_cv uuid; v_seat uuid; v_action uuid;
begin
  select id into v_cv from public.tc_constitution_versions where status='MASTER_APPROVED' order by version_no desc limit 1;
  select id into v_seat from public.tc_governance_seat_catalog where seat_code='SAFETY_WELLBEING_STEWARD';

  insert into public.tc_constitution_reserved_actions(
    constitution_version_id,action_code,title,description,protection_class,legal_mechanism_status,sort_order
  )
  select v_cv,'CHANGE_MINOR_SAFETY_POLICY','Cambiar reglas de protección de menores',
    'Modificar reglas de acceso a datos de menores, señales de riesgo, canal de ayuda, revelación HIGH/CRITICAL, IA de protección o salvaguardas equivalentes.',
    'FOUNDATIONAL','PENDING',75
  where not exists(
    select 1 from public.tc_constitution_reserved_actions where constitution_version_id=v_cv and action_code='CHANGE_MINOR_SAFETY_POLICY'
  );

  select id into v_action from public.tc_constitution_reserved_actions where constitution_version_id=v_cv and action_code='CHANGE_MINOR_SAFETY_POLICY';

  insert into public.tc_governance_action_seat_requirements(reserved_action_id,seat_id,requirement_kind,rationale)
  select v_action,v_seat,'SUPPORT_REQUIRED','La Custodia de Seguridad/Bienestar debe participar y apoyar cambios de política de protección infantil.'
  where not exists(
    select 1 from public.tc_governance_action_seat_requirements where reserved_action_id=v_action and seat_id=v_seat
  );
end $$;

insert into public.tc_feature_gates(
 feature_key,domain,display_name,source_status,backend_status,safety_status,legal_status,cultural_status,approval_status,is_enabled,notes
)
values
('safety.minor_help_channel','SAFETY','Canal protegido de ayuda para menores','VERIFIED','VERIFIED','PENDING','PENDING','NOT_REQUIRED','PENDING',false,'Backend estructural creado. No activar hasta definir procedimientos, roles autorizados y revisión legal/safety.'),
('safety.minor_escalation','SAFETY','Escalamiento de protección infantil','VERIFIED','VERIFIED','PENDING','PENDING','NOT_REQUIRED','PENDING',false,'Define niveles LOW/MEDIUM/HIGH/CRITICAL. No activa monitoreo ni decisiones automáticas.'),
('safety.minor_emergency_access','SAFETY','Acceso excepcional por riesgo crítico','VERIFIED','VERIFIED','PENDING','PENDING','NOT_REQUIRED','PENDING',false,'Solo para eventual flujo CRITICAL con alcance mínimo, auditoría y revisión posterior. Sin función de lectura activa todavía.')
on conflict(feature_key) do nothing;

commit;
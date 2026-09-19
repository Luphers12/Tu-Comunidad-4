begin;

create table if not exists public.linguistic_assessment_role_rubrics (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null references public.linguistic_assessment_templates(id) on delete cascade,
  role_code text not null,
  minimum_total_percent numeric(5,2) not null check (minimum_total_percent between 0 and 100),
  minimum_required_item_percent numeric(5,2) not null check (minimum_required_item_percent between 0 and 100),
  zero_critical_errors_required boolean not null default true,
  minimum_independent_reviews integer not null default 2 check (minimum_independent_reviews >= 1),
  required_competencies text[] not null default '{}',
  competency_minimums jsonb not null default '{}'::jsonb,
  notes text,
  status text not null default 'DRAFT' check (status in ('DRAFT','REVIEWED','APPROVED','RETIRED')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(template_id, role_code)
);

create table if not exists public.linguistic_assessment_critical_error_catalog (
  id uuid primary key default gen_random_uuid(),
  error_code text not null unique,
  display_name text not null,
  description text not null,
  blocks_role_verification boolean not null default true,
  severity text not null default 'CRITICAL' check (severity in ('MAJOR','CRITICAL')),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.linguistic_assessment_review_errors (
  id uuid primary key default gen_random_uuid(),
  assessment_review_id uuid not null references public.linguistic_assessment_reviews(id) on delete cascade,
  error_catalog_id uuid not null references public.linguistic_assessment_critical_error_catalog(id) on delete restrict,
  template_item_id uuid references public.linguistic_assessment_template_items(id) on delete set null,
  observation text,
  created_at timestamptz not null default now(),
  unique(assessment_review_id,error_catalog_id,template_item_id)
);

alter table public.linguistic_assessment_role_rubrics enable row level security;
alter table public.linguistic_assessment_critical_error_catalog enable row level security;
alter table public.linguistic_assessment_review_errors enable row level security;

revoke all on public.linguistic_assessment_role_rubrics from anon, authenticated;
revoke all on public.linguistic_assessment_critical_error_catalog from anon, authenticated;
revoke all on public.linguistic_assessment_review_errors from anon, authenticated;

insert into public.linguistic_assessment_critical_error_catalog(error_code,display_name,description,blocks_role_verification,severity)
values
('MEANING_DISTORTION','Distorsión esencial de significado','La respuesta cambia, invierte u omite de forma material el significado esencial del contenido fuente.',true,'CRITICAL'),
('FABRICATED_CONTENT','Contenido inventado','La respuesta agrega información sustantiva que no existe en el contenido fuente o contexto autorizado.',true,'CRITICAL'),
('WRONG_VARIANT_ASSERTION','Variante incorrecta presentada como válida','Se presenta como propia o validada de la variante evaluada una forma que el revisor independiente determina que pertenece a otra variante o no puede sostenerse para la variante objetivo.',true,'CRITICAL'),
('SELF_APPROVAL_OR_REVIEW','Autoaprobación o autorevisión','La persona intenta validar, revisar o aprobar material que creó o modificó materialmente.',true,'CRITICAL'),
('CULTURAL_MISREPRESENTATION','Representación cultural materialmente incorrecta','Se altera, atribuye o presenta de forma materialmente incorrecta una expresión, práctica o conocimiento cultural.',true,'CRITICAL'),
('UNVALIDATED_AS_OFFICIAL','Contenido no validado presentado como oficial','Se marca o afirma como oficial, normativo o comunitariamente validado contenido que aún no completó la cadena requerida.',true,'CRITICAL'),
('UNSAFE_SENSITIVE_TRANSLATION','Error sensible de seguridad/legal/pago','Una traducción en contexto sensible altera instrucciones, identidad, seguridad, legalidad o pago de forma que pueda causar perjuicio.',true,'CRITICAL')
on conflict (error_code) do nothing;

with t as (
  select id from public.linguistic_assessment_templates where template_code='CHUJ_SMI_ENTRY_V1'
)
insert into public.linguistic_assessment_role_rubrics
(template_id,role_code,minimum_total_percent,minimum_required_item_percent,zero_critical_errors_required,minimum_independent_reviews,required_competencies,competency_minimums,notes,status)
select t.id, v.role_code, v.total_pct, v.required_pct, true, v.reviews, v.comps, v.mins::jsonb, v.notes, 'DRAFT'
from t
cross join (values
('TRANSLATOR',94.00,90.00,2,array['TRANSLATE','UNDERSTAND','WRITE']::text[], '{"TRANSLATE":94,"UNDERSTAND":90,"WRITE":90}', 'Alta fidelidad semántica. Variantes legítimas no cuentan como error.'),
('ORTHOGRAPHY_CORRECTOR',96.00,94.00,2,array['ORTHOGRAPHY','WRITE','REVIEW']::text[], '{"ORTHOGRAPHY":96,"WRITE":94,"REVIEW":92}', 'Debe detectar y corregir sin borrar variantes legítimas.'),
('PEER_REVIEWER',96.00,94.00,2,array['REVIEW','TRANSLATE','UNDERSTAND']::text[], '{"REVIEW":96,"TRANSLATE":94,"UNDERSTAND":94}', 'No puede revisar material propio o modificado materialmente por sí mismo.'),
('LINGUISTIC_VALIDATOR',98.00,96.00,3,array['TRANSLATE','UNDERSTAND','WRITE','ORTHOGRAPHY','REVIEW']::text[], '{"TRANSLATE":98,"UNDERSTAND":96,"WRITE":96,"ORTHOGRAPHY":96,"REVIEW":98}', 'Rol de alta responsabilidad; cero errores críticos y evidencia sólida de variante.'),
('CULTURAL_VALIDATOR',98.00,96.00,3,array['CULTURAL_VALIDATE','UNDERSTAND','REVIEW']::text[], '{"CULTURAL_VALIDATE":98,"UNDERSTAND":96,"REVIEW":96}', 'No convierte experiencia personal en representación automática de toda la comunidad.'),
('TERMINOLOGY_SPECIALIST',97.00,95.00,2,array['TERMINOLOGY','TRANSLATE','REVIEW']::text[], '{"TERMINOLOGY":97,"TRANSLATE":95,"REVIEW":95}', 'Debe distinguir propuesta terminológica de término validado/oficial.'),
('VOICE_SPEAKER',92.00,90.00,2,array['VOICE','SPEAK','UNDERSTAND']::text[], '{"VOICE":94,"UNDERSTAND":90}', 'La voz se evalúa por inteligibilidad y fidelidad de variante; no exige nivel de corrector ortográfico.'),
('TRANSCRIBER',96.00,94.00,2,array['TRANSCRIBE','UNDERSTAND','WRITE']::text[], '{"TRANSCRIBE":96,"UNDERSTAND":94,"WRITE":92}', 'Debe conservar exactamente lo escuchado y señalar incertidumbre sin inventar.'),
('UI_QA',96.00,94.00,2,array['UI_QA','TRANSLATE','UNDERSTAND']::text[], '{"UI_QA":96,"TRANSLATE":94,"UNDERSTAND":94}', 'Debe detectar textos que cambien función, intención o claridad de interfaz.'),
('FINAL_REVIEWER',99.00,98.00,3,array['REVIEW','TRANSLATE','UNDERSTAND','ORTHOGRAPHY','CULTURAL_VALIDATE','UI_QA']::text[], '{"REVIEW":99,"TRANSLATE":98,"UNDERSTAND":98,"ORTHOGRAPHY":98,"CULTURAL_VALIDATE":98,"UI_QA":98}', 'Estándar máximo para aprobación final; cero errores críticos.'),
('DOMAIN_REVIEWER',98.00,96.00,3,array['REVIEW','UNDERSTAND','TERMINOLOGY']::text[], '{"REVIEW":98,"UNDERSTAND":96,"TERMINOLOGY":96}', 'Debe además cumplir la cualificación específica del dominio sensible correspondiente.')
) as v(role_code,total_pct,required_pct,reviews,comps,mins,notes)
on conflict (template_id,role_code) do update set
minimum_total_percent=excluded.minimum_total_percent,
minimum_required_item_percent=excluded.minimum_required_item_percent,
zero_critical_errors_required=excluded.zero_critical_errors_required,
minimum_independent_reviews=excluded.minimum_independent_reviews,
required_competencies=excluded.required_competencies,
competency_minimums=excluded.competency_minimums,
notes=excluded.notes,
updated_at=now();

insert into public.tc_feature_gates(feature_key,domain,parent_feature_key,display_name,source_status,backend_status,safety_status,legal_status,cultural_status,approval_status,is_enabled,notes)
values ('linguistics.role_rubrics','LINGUISTICS','linguistics.assessment','Rúbricas de elegibilidad por rol lingüístico','VERIFIED','VERIFIED','PENDING','PENDING','PENDING','PENDING',false,'Umbrales estrictos por rol. Cero errores críticos; variantes legítimas no se penalizan.')
on conflict (feature_key) do update set backend_status='VERIFIED',is_enabled=false,updated_at=now();

commit;
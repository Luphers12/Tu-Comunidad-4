begin;

-- Create a new immutable constitution version instead of editing prior approved history.
with latest as (
  select *
  from public.tc_constitution_versions
  where status = 'MASTER_APPROVED'
  order by version_no desc
  limit 1
), new_version as (
  insert into public.tc_constitution_versions (
    version_no,
    public_code,
    title,
    mission_statement,
    status,
    legal_status,
    notes,
    approved_at
  )
  select
    latest.version_no + 1,
    'TCCONST-' || lpad((latest.version_no + 1)::text, 4, '0'),
    'Constitución de Principios de TU COMUNIDAD — Custodia y preservación comunitaria',
    latest.mission_statement,
    'MASTER_APPROVED',
    'PENDING',
    'Conserva íntegramente la versión anterior y añade custodia comunitaria, preservación permanente del patrimonio cultural/lingüístico y separación entre patrimonio comunitario y datos personales sujetos a derechos legales.',
    now()
  from latest
  returning id
), source_version as (
  select id
  from latest
), copied_principles as (
  insert into public.tc_constitution_principles (
    constitution_version_id,
    principle_code,
    protection_level,
    title,
    statement,
    rationale,
    sort_order,
    is_foundational
  )
  select
    nv.id,
    p.principle_code,
    p.protection_level,
    p.title,
    p.statement,
    p.rationale,
    p.sort_order,
    p.is_foundational
  from public.tc_constitution_principles p
  cross join new_version nv
  where p.constitution_version_id = (select id from source_version)
  returning 1
), copied_actions as (
  insert into public.tc_constitution_reserved_actions (
    constitution_version_id,
    action_code,
    title,
    description,
    protection_class,
    legal_mechanism_status,
    sort_order
  )
  select
    nv.id,
    a.action_code,
    a.title,
    a.description,
    a.protection_class,
    a.legal_mechanism_status,
    a.sort_order
  from public.tc_constitution_reserved_actions a
  cross join new_version nv
  where a.constitution_version_id = (select id from source_version)
  returning 1
)
insert into public.tc_constitution_principles (
  constitution_version_id,
  principle_code,
  protection_level,
  title,
  statement,
  rationale,
  sort_order,
  is_foundational
)
select
  nv.id,
  v.principle_code,
  v.protection_level,
  v.title,
  v.statement,
  v.rationale,
  v.sort_order,
  v.is_foundational
from new_version nv
cross join (values
  (
    'COMMUNITY_HERITAGE_PERMANENT_PRESERVATION',
    1::smallint,
    'Preservación permanente del patrimonio comunitario',
    'Los registros culturales, lingüísticos, históricos y de saberes comunitarios que puedan conservarse legítimamente deben preservarse como memoria de la comunidad y no podrán ser destruidos por un cambio de administración, control, misión, cierre comercial o conveniencia económica de TU COMUNIDAD.',
    'La tecnología actúa como custodio. La continuidad de la memoria cultural y lingüística no depende de que TU COMUNIDAD conserve el mismo propietario u operador.',
    180,
    true
  ),
  (
    'COMMUNITY_DATA_IS_CUSTODY_NOT_OWNERSHIP',
    1::smallint,
    'Custodiar no significa apropiarse',
    'TU COMUNIDAD puede almacenar, organizar y utilizar datos comunitarios para servir a la comunidad conforme a finalidades y permisos válidos, pero la custodia tecnológica no convierte esos datos, saberes, idiomas, voces o memorias en propiedad ilimitada de la plataforma.',
    'Un cambio de control o de propietario no amplía automáticamente los derechos de uso sobre el patrimonio comunitario.',
    181,
    true
  ),
  (
    'PERSONAL_DATA_AND_HERITAGE_SEPARATION',
    1::smallint,
    'Separación entre patrimonio y datos personales',
    'Cuando una obligación legal, un derecho de la persona o el retiro válido de un consentimiento exija eliminar, rectificar, restringir o anonimizar datos personales, TU COMUNIDAD deberá proteger ese derecho sin destruir el conocimiento cultural, lingüístico o histórico que pueda conservarse de forma legítima, desidentificada o agregada.',
    'Protege simultáneamente la memoria comunitaria y los derechos de cada persona.',
    182,
    true
  )
) as v(principle_code, protection_level, title, statement, rationale, sort_order, is_foundational);

with current_version as (
  select id
  from public.tc_constitution_versions
  where status = 'MASTER_APPROVED'
  order by version_no desc
  limit 1
)
insert into public.tc_constitution_reserved_actions (
  constitution_version_id,
  action_code,
  title,
  description,
  protection_class,
  legal_mechanism_status,
  sort_order
)
select
  cv.id,
  v.action_code,
  v.title,
  v.description,
  v.protection_class,
  v.legal_mechanism_status,
  v.sort_order
from current_version cv
cross join (values
  (
    'DESTROY_COMMUNITY_HERITAGE',
    'Eliminar patrimonio comunitario',
    'Eliminar, destruir o hacer irrecuperable patrimonio cultural, lingüístico, histórico o de saberes comunitarios que pueda conservarse legítimamente.',
    'FOUNDATIONAL',
    'PENDING',
    75
  ),
  (
    'TRANSFER_COMMUNITY_HERITAGE_CUSTODY',
    'Transferir custodia de patrimonio comunitario',
    'Transferir a otra entidad la custodia de patrimonio cultural, lingüístico, histórico o comunitario requiere garantías de continuidad, misión compatible, trazabilidad y protección de los permisos existentes.',
    'FOUNDATIONAL',
    'PENDING',
    76
  )
) as v(action_code, title, description, protection_class, legal_mechanism_status, sort_order)
where not exists (
  select 1
  from public.tc_constitution_reserved_actions a
  where a.constitution_version_id = cv.id
    and a.action_code = v.action_code
);

create table if not exists public.tc_community_data_stewardship_policies (
  id uuid primary key default gen_random_uuid(),
  policy_code text not null unique,
  data_class text not null,
  stewardship_rule text not null,
  preservation_mode text not null,
  personal_data_rule text not null,
  mission_change_rule text not null,
  legal_status text not null default 'PENDING',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tc_community_data_stewardship_mode_ck check (preservation_mode in ('PERMANENT_HERITAGE','CONDITIONAL_LEGAL_PRESERVATION','OPERATIONAL_RETENTION'))
);

alter table public.tc_community_data_stewardship_policies enable row level security;
revoke all on public.tc_community_data_stewardship_policies from anon, authenticated;

insert into public.tc_community_data_stewardship_policies (
  policy_code,
  data_class,
  stewardship_rule,
  preservation_mode,
  personal_data_rule,
  mission_change_rule,
  legal_status,
  is_active
) values
(
  'TC-DATA-CULTURAL-HERITAGE',
  'CULTURAL_LINGUISTIC_HISTORICAL_HERITAGE',
  'Preservar para la comunidad como patrimonio y memoria; TU COMUNIDAD actúa como custodio, no como propietario ilimitado.',
  'PERMANENT_HERITAGE',
  'Separar o anonimizar identificadores personales cuando sea necesario para respetar derechos legales sin destruir el contenido patrimonial que pueda conservarse legítimamente.',
  'Un cambio de misión, control, propietario o cierre comercial no autoriza destrucción ni nuevos usos incompatibles. Debe mantenerse custodia compatible o transferirse a un custodio compatible bajo garantías.',
  'PENDING',
  true
),
(
  'TC-DATA-PERSONAL',
  'PERSONAL_OR_IDENTIFIABLE_DATA',
  'Proteger a la persona y usar únicamente conforme a finalidad, permiso y ley aplicable.',
  'CONDITIONAL_LEGAL_PRESERVATION',
  'Rectificar, restringir, anonimizar o eliminar cuando corresponda legalmente o por derechos válidos de la persona; conservar por separado únicamente el conocimiento comunitario que pueda mantenerse legítimamente.',
  'Un cambio de misión o control no amplía derechos sobre los datos personales.',
  'PENDING',
  true
)
on conflict (policy_code) do nothing;

commit;
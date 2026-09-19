begin;

create table if not exists public.tc_constitution_versions (
  id uuid primary key default gen_random_uuid(),
  version_no integer not null unique check (version_no > 0),
  public_code text not null unique,
  title text not null,
  mission_statement text not null,
  status text not null default 'DRAFT' check (status in ('DRAFT','MASTER_APPROVED','SUPERSEDED','ARCHIVED')),
  legal_status text not null default 'PENDING' check (legal_status in ('PENDING','REVIEW','VERIFIED','REJECTED')),
  notes text,
  approved_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.tc_constitution_principles (
  id uuid primary key default gen_random_uuid(),
  constitution_version_id uuid not null references public.tc_constitution_versions(id) on delete restrict,
  principle_code text not null,
  protection_level smallint not null check (protection_level between 1 and 3),
  title text not null,
  statement text not null,
  rationale text,
  sort_order integer not null default 0,
  is_foundational boolean not null default false,
  created_at timestamptz not null default now(),
  unique (constitution_version_id, principle_code)
);

create table if not exists public.tc_constitution_reserved_actions (
  id uuid primary key default gen_random_uuid(),
  constitution_version_id uuid not null references public.tc_constitution_versions(id) on delete restrict,
  action_code text not null,
  title text not null,
  description text not null,
  protection_class text not null check (protection_class in ('FOUNDATIONAL','RESERVED','OPERATIONAL')),
  legal_mechanism_status text not null default 'PENDING' check (legal_mechanism_status in ('PENDING','DESIGNED','VERIFIED')),
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique (constitution_version_id, action_code)
);

alter table public.tc_constitution_versions enable row level security;
alter table public.tc_constitution_principles enable row level security;
alter table public.tc_constitution_reserved_actions enable row level security;

revoke all on public.tc_constitution_versions from anon, authenticated;
revoke all on public.tc_constitution_principles from anon, authenticated;
revoke all on public.tc_constitution_reserved_actions from anon, authenticated;

create or replace function public.tc_block_constitution_history_mutation()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  raise exception 'TC_CONSTITUTION_HISTORY_IMMUTABLE: create a new constitution version instead';
end;
$$;

drop trigger if exists trg_tc_constitution_versions_immutable on public.tc_constitution_versions;
create trigger trg_tc_constitution_versions_immutable
before update or delete on public.tc_constitution_versions
for each row
when (old.status in ('MASTER_APPROVED','SUPERSEDED','ARCHIVED'))
execute function public.tc_block_constitution_history_mutation();

drop trigger if exists trg_tc_constitution_principles_immutable on public.tc_constitution_principles;
create trigger trg_tc_constitution_principles_immutable
before update or delete on public.tc_constitution_principles
for each row
execute function public.tc_block_constitution_history_mutation();

drop trigger if exists trg_tc_constitution_reserved_actions_immutable on public.tc_constitution_reserved_actions;
create trigger trg_tc_constitution_reserved_actions_immutable
before update or delete on public.tc_constitution_reserved_actions
for each row
execute function public.tc_block_constitution_history_mutation();

with v as (
  insert into public.tc_constitution_versions (
    version_no, public_code, title, mission_statement, status, legal_status, notes, approved_at
  ) values (
    1,
    'TCCONST-0001',
    'Constitución de Principios de TU COMUNIDAD',
    'TU COMUNIDAD fue creada para servir a la comunidad y no para aprovecharse de ella. Todo lo que se ofrece en la red debe sumar valor, no restarlo.',
    'MASTER_APPROVED',
    'PENDING',
    'Aprobación de producto/MASTER. Pendiente traducción jurídica a estatutos, pactos y contratos por asesor legal competente.',
    now()
  )
  on conflict (version_no) do nothing
  returning id
), version_row as (
  select id from v
  union all
  select id from public.tc_constitution_versions where version_no = 1
  limit 1
)
insert into public.tc_constitution_principles
(constitution_version_id, principle_code, protection_level, title, statement, rationale, sort_order, is_foundational)
select vr.id, p.code, p.level, p.title, p.statement, p.rationale, p.ord, p.foundational
from version_row vr
cross join (values
  ('COMMUNITY_FIRST',1,'La comunidad primero','TU COMUNIDAD fue creada para servir a la comunidad y no para aprovecharse de ella.','La finalidad comunitaria está por encima de la explotación económica.',10,true),
  ('ADD_NOT_SUBTRACT',1,'Sumar, no restar','Todo producto, servicio, función, cobro, algoritmo, contrato, oportunidad, contenido o herramienta debe buscar sumar valor a las personas y a la comunidad, no restarlo.','Toda función nueva debe superar una prueba de beneficio y daño.',20,true),
  ('MISSION_CONTINUITY',1,'La misión debe sobrevivir al control','La finalidad comunitaria debe permanecer protegida aunque cambien fundador, accionistas, administradores, inversionistas o control corporativo.','La continuidad no puede depender de la buena voluntad de una sola persona.',30,true),
  ('NO_EXPLOITATION',1,'No explotación de la necesidad','La red no debe aprovechar injustamente pobreza, aislamiento, falta de transporte, idioma, desconocimiento, urgencia, dependencia económica o falta de alternativas.','El poder de la red no puede convertirse en abuso.',40,true),
  ('FAIR_ECONOMY',1,'Economía justa','Precios, tarifas, comisiones, créditos, penalizaciones y cobros deben ser transparentes, explicables, proporcionales y compatibles con la misión comunitaria.','Los ingresos sostienen la red; no justifican explotación.',50,true),
  ('DIGNITY_AND_AGENCY',1,'Dignidad y control de la persona','Toda persona participante debe conocer qué acepta, qué recibe, qué responsabilidades asume y qué derechos conserva.','La participación debe ser comprensible y respetuosa.',60,true),
  ('DATA_STEWARDSHIP',1,'Custodia responsable de datos','Los datos personales, culturales, lingüísticos y comunitarios solo pueden usarse para fines legítimos, autorizados y compatibles con la misión.','Los datos no son un recurso de explotación ilimitada.',70,true),
  ('CULTURAL_NON_APPROPRIATION',1,'La cultura no se apropia','Idiomas, variantes, voces, saberes, expresiones y conocimientos comunitarios no deben explotarse, entrenarse, comercializarse o redistribuirse fuera de permisos claros y condiciones justas.','Protege conocimiento y patrimonio comunitario.',80,true),
  ('AI_SERVES_COMMUNITY',1,'La IA sirve a la comunidad','La inteligencia artificial debe aumentar la capacidad de la comunidad, no reemplazarla, manipularla ni extraer su conocimiento para beneficio unilateral de la plataforma.','La IA es herramienta y no autoridad final.',90,true),
  ('FAIR_WORK',1,'Trabajo y contribución dignos','Quien aporte trabajo, transporte, traducción, enseñanza, contenido, voz o conocimiento debe conocer condiciones, compensación, derechos y responsabilidades antes de participar.','Evita extraer trabajo o conocimiento sin reglas claras.',100,true),
  ('INDEPENDENT_REVIEW',2,'Revisión independiente','Quien crea, corrige o modifica materialmente contenido sujeto a validación no debe calificarse, validarse ni aprobarse a sí mismo.','Reduce conflictos de interés y protege calidad.',110,false),
  ('ESSENTIAL_ASSET_PROTECTION',1,'Protección de activos esenciales','Marca, software, infraestructura crítica, datos protegidos y demás activos esenciales no deben venderse, transferirse o explotarse de forma que destruya o contradiga la misión comunitaria.','Protege la continuidad material de la red.',120,true),
  ('COMMUNITY_VOICE',2,'La comunidad debe tener voz','Las personas y territorios afectados deben contar con mecanismos de participación, queja, revisión y representación conforme la red crece.','La gobernanza comunitaria requiere canales reales de participación.',130,false),
  ('NO_DEPENDENCY_ABUSE',1,'No abuso de dependencia','TU COMUNIDAD no utilizará la dependencia de una persona o comunidad hacia la red para imponer condiciones injustas o eliminar alternativas de manera abusiva.','Una posición fuerte en un territorio aumenta la responsabilidad de la red.',140,true),
  ('MISSION_OVER_GROWTH',1,'La misión está por encima del crecimiento','Si una expansión, inversión, producto o acuerdo exige traicionar la misión comunitaria, debe rechazarse o rediseñarse aunque sea rentable.','El crecimiento es un medio, no el propósito final.',150,true),
  ('PROTECTIVE_INTERPRETATION',1,'Interpretación protectora','Cuando exista una duda razonable entre decisiones compatibles, deberá preferirse la que proteja mejor a la comunidad, su dignidad, participación y propósito original de la red.','Funciona como regla de interpretación de los demás principios.',160,true)
) as p(code,level,title,statement,rationale,ord,foundational)
on conflict (constitution_version_id, principle_code) do nothing;

with vr as (
  select id from public.tc_constitution_versions where version_no = 1
)
insert into public.tc_constitution_reserved_actions
(constitution_version_id, action_code, title, description, protection_class, legal_mechanism_status, sort_order)
select vr.id, a.code, a.title, a.description, a.class, 'PENDING', a.ord
from vr
cross join (values
  ('CHANGE_CORE_MISSION','Cambiar la misión central','Modificar, eliminar o sustituir la finalidad comunitaria o la regla de no explotación.','FOUNDATIONAL',10),
  ('SELL_CORE_BRAND','Vender o transferir la marca principal','Vender, ceder, gravar o transferir control de la marca TU COMUNIDAD de forma que pueda comprometer la misión.','FOUNDATIONAL',20),
  ('SELL_CORE_SOFTWARE','Vender o transferir tecnología esencial','Transferir software, infraestructura o propiedad intelectual esencial cuando pueda comprometer continuidad o misión.','FOUNDATIONAL',30),
  ('CHANGE_CONTROL','Transferencia de control','Operación, emisión, acuerdo o transferencia que otorgue control efectivo de la red a otra persona o grupo.','FOUNDATIONAL',40),
  ('MERGER_OR_DISSOLUTION','Fusión, transformación o disolución','Fusionar, transformar, disolver o vender sustancialmente todos los activos de la organización.','FOUNDATIONAL',50),
  ('NEW_COMMUNITY_DATA_USE','Nuevo uso sensible de datos comunitarios','Autorizar usos nuevos de datos personales, culturales o lingüísticos que excedan permisos y finalidades existentes.','FOUNDATIONAL',60),
  ('CULTURAL_OR_AI_RIGHTS_EXPANSION','Ampliar derechos culturales o de IA','Ampliar el uso de voces, idiomas, saberes, contenido cultural, entrenamiento de IA o modelado de voz más allá de autorizaciones existentes.','FOUNDATIONAL',70),
  ('HIGH_IMPACT_ECONOMIC_RULES','Cambiar reglas económicas de alto impacto','Introducir o modificar mecanismos de cobro, deuda, crédito, penalización o comisión capaces de crear dependencia o perjuicio comunitario significativo.','RESERVED',80),
  ('COMMUNITY_EXCLUSION_RULES','Cambiar reglas de exclusión','Modificar suspensiones, bloqueos, expulsiones o acceso territorial con impacto significativo sobre derechos de participación.','RESERVED',90),
  ('ROUTINE_OPERATIONS','Operación ordinaria','Horarios, diseño de interfaz, proveedores, rutas, procesos y parámetros operativos que no contradigan los principios protegidos.','OPERATIONAL',100)
) as a(code,title,description,class,ord)
on conflict (constitution_version_id, action_code) do nothing;

create or replace function public.tc_get_current_constitution()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with cv as (
    select *
    from public.tc_constitution_versions
    where status = 'MASTER_APPROVED'
    order by version_no desc
    limit 1
  )
  select jsonb_build_object(
    'version', jsonb_build_object(
      'public_code', cv.public_code,
      'version_no', cv.version_no,
      'title', cv.title,
      'mission_statement', cv.mission_statement,
      'status', cv.status,
      'legal_status', cv.legal_status,
      'approved_at', cv.approved_at
    ),
    'principles', coalesce((
      select jsonb_agg(jsonb_build_object(
        'code', p.principle_code,
        'protection_level', p.protection_level,
        'title', p.title,
        'statement', p.statement,
        'is_foundational', p.is_foundational
      ) order by p.sort_order)
      from public.tc_constitution_principles p
      where p.constitution_version_id = cv.id
    ), '[]'::jsonb),
    'reserved_actions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'code', a.action_code,
        'title', a.title,
        'description', a.description,
        'protection_class', a.protection_class,
        'legal_mechanism_status', a.legal_mechanism_status
      ) order by a.sort_order)
      from public.tc_constitution_reserved_actions a
      where a.constitution_version_id = cv.id
    ), '[]'::jsonb)
  )
  from cv;
$$;

revoke all on function public.tc_get_current_constitution() from public;
grant execute on function public.tc_get_current_constitution() to authenticated;

commit;
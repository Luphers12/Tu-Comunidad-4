begin;

-- -----------------------------------------------------------------------------
-- PERFIL PRINCIPAL LNG
-- -----------------------------------------------------------------------------
create sequence if not exists public.lng_profile_seq start 1;

alter table public.profiles drop constraint if exists profiles_profile_type_check;
alter table public.profiles add constraint profiles_profile_type_check
check (profile_type = any (array['CLI','CON','RSG','VEN','TIE','PAS','PTC','EMP','SOP','ADM','LNG']::text[]));

alter table public.profiles drop constraint if exists chk_profile_public_id_prefix;
alter table public.profiles add constraint chk_profile_public_id_prefix check (
  ((profile_type='CLI') and public_id like 'CLI-%') or
  ((profile_type='CON') and public_id like 'CON-%') or
  ((profile_type='RSG') and public_id like 'RSG-%') or
  ((profile_type='VEN') and public_id like 'VEN-%') or
  ((profile_type='TIE') and public_id like 'TIE-%') or
  ((profile_type='PAS') and public_id like 'PAS-%') or
  ((profile_type='PTC') and public_id like 'PTC-%') or
  ((profile_type='EMP') and public_id like 'EMP-%') or
  ((profile_type='SOP') and public_id like 'SOP-%') or
  ((profile_type='ADM') and public_id like 'ADM-%') or
  ((profile_type='LNG') and public_id like 'LNGP-%')
);

create unique index if not exists uq_profiles_one_lng_per_person
on public.profiles(person_id) where profile_type='LNG';

-- -----------------------------------------------------------------------------
-- CAPACIDADES LINGÜÍSTICAS (NO SE OTORGAN AUTOMÁTICAMENTE)
-- -----------------------------------------------------------------------------
insert into public.capabilities(name) values
 ('linguistic.translate.submit'),
 ('linguistic.correct.orthography'),
 ('linguistic.review.peer'),
 ('linguistic.validate.language'),
 ('linguistic.validate.culture'),
 ('linguistic.terminology.propose'),
 ('linguistic.audio.record'),
 ('linguistic.transcribe.submit'),
 ('linguistic.ui.qa'),
 ('linguistic.release.recommend')
on conflict (name) do nothing;

-- -----------------------------------------------------------------------------
-- CATÁLOGO DE ESPECIALIDADES
-- -----------------------------------------------------------------------------
create table if not exists public.linguistic_role_catalog (
  id uuid primary key default gen_random_uuid(),
  role_code text not null unique,
  display_name text not null,
  description text not null,
  capability_id uuid not null references public.capabilities(id) on delete restrict,
  minimum_proficiency text not null,
  requires_verified_qualification boolean not null default true,
  requires_independent_review boolean not null default false,
  can_self_request boolean not null default true,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint linguistic_role_min_prof_check check (minimum_proficiency in (
    'LEARNER','HERITAGE_SPEAKER','FLUENT_SELF_REPORTED','NATIVE_SELF_REPORTED',
    'COMMUNITY_VALIDATED','PROFESSIONAL_VALIDATED'))
);

insert into public.linguistic_role_catalog
(role_code,display_name,description,capability_id,minimum_proficiency,requires_verified_qualification,requires_independent_review,can_self_request)
select v.role_code,v.display_name,v.description,c.id,v.minimum_proficiency,v.requires_verified,v.requires_independent_review,v.can_self_request
from (values
 ('TRANSLATOR','Traductor/a','Propone traducciones nuevas conservando significado, contexto y variante.','linguistic.translate.submit','FLUENT_SELF_REPORTED',false,true,true),
 ('ORTHOGRAPHY_CORRECTOR','Corrector/a ortográfico/a','Revisa escritura, signos, ortografía y consistencia sin cambiar arbitrariamente el dialecto.','linguistic.correct.orthography','COMMUNITY_VALIDATED',true,true,true),
 ('PEER_REVIEWER','Revisor/a comunitario/a','Compara propuestas y detecta ambigüedad, errores de significado o necesidad de contexto.','linguistic.review.peer','NATIVE_SELF_REPORTED',true,true,true),
 ('LINGUISTIC_VALIDATOR','Validador/a lingüístico/a','Valida naturalidad, significado y pertenencia a la variante seleccionada.','linguistic.validate.language','COMMUNITY_VALIDATED',true,true,true),
 ('CULTURAL_VALIDATOR','Validador/a cultural','Revisa respeto cultural, usos locales, expresiones sensibles y contexto comunitario.','linguistic.validate.culture','COMMUNITY_VALIDATED',true,true,true),
 ('TERMINOLOGY_SPECIALIST','Terminólogo/a y neologismos','Propone términos para conceptos modernos cuando no existe equivalencia clara; nunca publica unilateralmente.','linguistic.terminology.propose','COMMUNITY_VALIDATED',true,true,true),
 ('VOICE_SPEAKER','Locutor/a de pronunciación','Graba pronunciación y frases; la voz requiere consentimiento separado para cada uso.','linguistic.audio.record','FLUENT_SELF_REPORTED',false,true,true),
 ('TRANSCRIBER','Transcriptor/a','Transcribe y coteja audio con texto manteniendo la variante original.','linguistic.transcribe.submit','FLUENT_SELF_REPORTED',false,true,true),
 ('UI_QA','Revisor/a de interfaz','Comprueba que la traducción funciona dentro de botones, menús, mensajes y pantallas sin perder significado.','linguistic.ui.qa','COMMUNITY_VALIDATED',true,true,true),
 ('FINAL_REVIEWER','Revisor/a final','Recomienda una versión para release después de las revisiones requeridas; no activa publicación por sí solo.','linguistic.release.recommend','PROFESSIONAL_VALIDATED',true,true,false)
) as v(role_code,display_name,description,capability_name,minimum_proficiency,requires_verified,requires_independent_review,can_self_request)
join public.capabilities c on c.name=v.capability_name
on conflict (role_code) do update set
 display_name=excluded.display_name,
 description=excluded.description,
 capability_id=excluded.capability_id,
 minimum_proficiency=excluded.minimum_proficiency,
 requires_verified_qualification=excluded.requires_verified_qualification,
 requires_independent_review=excluded.requires_independent_review,
 can_self_request=excluded.can_self_request,
 is_active=true;

-- -----------------------------------------------------------------------------
-- PERFIL LNG EXTENDIDO
-- -----------------------------------------------------------------------------
create table if not exists public.linguistic_profiles (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  contributor_id uuid not null unique references public.linguistic_contributors(id) on delete restrict,
  selected_language_id uuid references public.languages(id) on delete restrict,
  selected_variant_id uuid references public.language_variants(id) on delete restrict,
  onboarding_status text not null default 'STARTED' check (onboarding_status in ('STARTED','PROFILE_COMPLETE','QUALIFICATION_PENDING','READY','PAUSED','RESTRICTED')),
  availability_status text not null default 'PAUSED' check (availability_status in ('AVAILABLE','PAUSED','BUSY','UNAVAILABLE')),
  public_credit_mode text not null default 'ANONYMOUS' check (public_credit_mode in ('ANONYMOUS','PUBLIC_ID','DISPLAY_NAME','COMMUNITY_ONLY')),
  can_receive_tasks boolean not null default false,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint linguistic_profiles_variant_pair_fk foreign key (selected_language_id,selected_variant_id)
    references public.language_variants(language_id,id) on delete restrict
);

-- -----------------------------------------------------------------------------
-- ROLES POR IDIOMA / VARIANTE
-- -----------------------------------------------------------------------------
create table if not exists public.linguistic_contributor_roles (
  id uuid primary key default gen_random_uuid(),
  contributor_id uuid not null references public.linguistic_contributors(id) on delete restrict,
  role_id uuid not null references public.linguistic_role_catalog(id) on delete restrict,
  language_id uuid not null references public.languages(id) on delete restrict,
  variant_id uuid references public.language_variants(id) on delete restrict,
  status text not null default 'REQUESTED' check (status in ('REQUESTED','PENDING_VERIFICATION','VERIFIED','SUSPENDED','REVOKED','REJECTED')),
  granted_by_person_id uuid references public.persons(id) on delete restrict,
  granted_at timestamptz,
  expires_at timestamptz,
  evidence_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint linguistic_contributor_roles_variant_fk foreign key (language_id,variant_id)
    references public.language_variants(language_id,id) on delete restrict,
  constraint linguistic_contributor_roles_grant_time check ((granted_at is null) or (status in ('VERIFIED','SUSPENDED','REVOKED'))),
  constraint linguistic_contributor_roles_expiry check ((expires_at is null) or (granted_at is not null and expires_at >= granted_at)),
  unique nulls not distinct (contributor_id,role_id,language_id,variant_id)
);

create index if not exists idx_linguistic_contributor_roles_lookup
on public.linguistic_contributor_roles(language_id,variant_id,status);

-- Extender cualificaciones existentes sin romper contratos previos.
alter table public.linguistic_contributor_qualifications
  add column if not exists can_orthography_correct boolean not null default false,
  add column if not exists can_linguistic_validate boolean not null default false,
  add column if not exists can_terminology_propose boolean not null default false,
  add column if not exists can_ui_qa boolean not null default false;

-- -----------------------------------------------------------------------------
-- SEGURIDAD: RLS FAIL-CLOSED
-- -----------------------------------------------------------------------------
alter table public.linguistic_role_catalog enable row level security;
alter table public.linguistic_profiles enable row level security;
alter table public.linguistic_contributor_roles enable row level security;

revoke all on public.linguistic_role_catalog from anon, authenticated;
revoke all on public.linguistic_profiles from anon, authenticated;
revoke all on public.linguistic_contributor_roles from anon, authenticated;

-- -----------------------------------------------------------------------------
-- RPC: LECTURA DEL CATÁLOGO DE ROLES (NO SENSIBLE)
-- -----------------------------------------------------------------------------
create or replace function public.tc_get_linguistic_role_catalog()
returns table(
  role_code text,
  display_name text,
  description text,
  minimum_proficiency text,
  requires_verified_qualification boolean,
  requires_independent_review boolean,
  can_self_request boolean
)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select r.role_code,r.display_name,r.description,r.minimum_proficiency,
         r.requires_verified_qualification,r.requires_independent_review,r.can_self_request
  from public.linguistic_role_catalog r
  where r.is_active=true
  order by r.role_code;
$$;
revoke all on function public.tc_get_linguistic_role_catalog() from public;
grant execute on function public.tc_get_linguistic_role_catalog() to anon, authenticated;

-- -----------------------------------------------------------------------------
-- RPC: CREAR MI PERFIL LNG (CERRADO POR FEATURE GATE)
-- -----------------------------------------------------------------------------
create or replace function public.tc_create_my_linguistic_profile(
  p_language_id uuid,
  p_variant_id uuid,
  p_proficiency text,
  p_requested_role_codes text[] default array['TRANSLATOR']::text[]
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_person_id uuid;
  v_profile_id uuid;
  v_profile_public_id text;
  v_contributor_id uuid;
  v_role record;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.tc_is_feature_enabled('linguistics.work_program') then
    raise exception 'LINGUISTICS_WORK_PROGRAM_DISABLED';
  end if;

  select p.id into v_person_id from public.persons p where p.auth_user_id=auth.uid();
  if v_person_id is null then raise exception 'PERSON_NOT_FOUND'; end if;

  if not exists(select 1 from public.languages l where l.id=p_language_id and l.is_active=true) then
    raise exception 'LANGUAGE_NOT_FOUND';
  end if;
  if p_variant_id is not null and not exists(
    select 1 from public.language_variants v where v.id=p_variant_id and v.language_id=p_language_id and v.is_active=true
  ) then raise exception 'VARIANT_NOT_FOUND'; end if;

  select id,public_id into v_profile_id,v_profile_public_id
  from public.profiles where person_id=v_person_id and profile_type='LNG';

  if v_profile_id is null then
    v_profile_public_id := 'LNGP-' || lpad(nextval('public.lng_profile_seq')::text,4,'0');
    insert into public.profiles(public_id,person_id,profile_type,status)
    values(v_profile_public_id,v_person_id,'LNG','pending') returning id into v_profile_id;
  end if;

  insert into public.linguistic_contributors(person_id,is_active)
  values(v_person_id,true)
  on conflict(person_id) do update set is_active=true
  returning id into v_contributor_id;

  insert into public.linguistic_profiles(profile_id,contributor_id,selected_language_id,selected_variant_id,onboarding_status,availability_status,can_receive_tasks)
  values(v_profile_id,v_contributor_id,p_language_id,p_variant_id,'QUALIFICATION_PENDING','PAUSED',false)
  on conflict(profile_id) do update set
    selected_language_id=excluded.selected_language_id,
    selected_variant_id=excluded.selected_variant_id,
    updated_at=now();

  insert into public.linguistic_contributor_qualifications(contributor_id,language_id,variant_id,proficiency,verification_status)
  values(v_contributor_id,p_language_id,p_variant_id,p_proficiency,'SELF_REPORTED')
  on conflict do nothing;

  for v_role in
    select r.id,r.role_code,r.requires_verified_qualification
    from public.linguistic_role_catalog r
    where r.is_active=true and r.can_self_request=true and r.role_code=any(coalesce(p_requested_role_codes,array[]::text[]))
  loop
    insert into public.linguistic_contributor_roles(contributor_id,role_id,language_id,variant_id,status)
    values(v_contributor_id,v_role.id,p_language_id,p_variant_id,
      case when v_role.requires_verified_qualification then 'PENDING_VERIFICATION' else 'REQUESTED' end)
    on conflict (contributor_id,role_id,language_id,variant_id) do update set
      status=case when public.linguistic_contributor_roles.status in ('REVOKED','SUSPENDED') then public.linguistic_contributor_roles.status else excluded.status end,
      updated_at=now();
  end loop;

  return jsonb_build_object(
    'profile_id',v_profile_id,
    'profile_public_id',v_profile_public_id,
    'contributor_id',v_contributor_id,
    'language_id',p_language_id,
    'variant_id',p_variant_id,
    'status','QUALIFICATION_PENDING'
  );
end;
$$;
revoke all on function public.tc_create_my_linguistic_profile(uuid,uuid,text,text[]) from public;
grant execute on function public.tc_create_my_linguistic_profile(uuid,uuid,text,text[]) to authenticated;

-- -----------------------------------------------------------------------------
-- RPC: VER MI PERFIL LNG
-- -----------------------------------------------------------------------------
create or replace function public.tc_get_my_linguistic_profile()
returns jsonb
language sql
security definer
set search_path = public, pg_temp
stable
as $$
with me as (
  select p.id person_id from public.persons p where p.auth_user_id=auth.uid()
), base as (
  select pr.id profile_id,pr.public_id profile_public_id,pr.status profile_status,
         lc.id contributor_id,lp.selected_language_id,lp.selected_variant_id,
         lp.onboarding_status,lp.availability_status,lp.public_credit_mode,lp.can_receive_tasks
  from me
  join public.profiles pr on pr.person_id=me.person_id and pr.profile_type='LNG'
  join public.linguistic_contributors lc on lc.person_id=me.person_id
  join public.linguistic_profiles lp on lp.profile_id=pr.id and lp.contributor_id=lc.id
)
select case when exists(select 1 from base) then jsonb_build_object(
 'profile',(select to_jsonb(base) from base),
 'roles',coalesce((select jsonb_agg(jsonb_build_object(
    'role_code',rc.role_code,'display_name',rc.display_name,'status',cr.status,
    'language_id',cr.language_id,'variant_id',cr.variant_id,'granted_at',cr.granted_at,'expires_at',cr.expires_at
  ) order by rc.role_code)
  from base b
  join public.linguistic_contributor_roles cr on cr.contributor_id=b.contributor_id
  join public.linguistic_role_catalog rc on rc.id=cr.role_id),'[]'::jsonb),
 'qualifications',coalesce((select jsonb_agg(to_jsonb(q) - 'id' - 'contributor_id' - 'verified_by_person_id')
  from base b join public.linguistic_contributor_qualifications q on q.contributor_id=b.contributor_id),'[]'::jsonb)
) else null end;
$$;
revoke all on function public.tc_get_my_linguistic_profile() from public;
grant execute on function public.tc_get_my_linguistic_profile() to authenticated;

commit;
begin;

insert into public.capabilities(name) values ('linguistic.domain.review') on conflict(name) do nothing;

insert into public.linguistic_role_catalog
(role_code,display_name,description,capability_id,minimum_proficiency,requires_verified_qualification,requires_independent_review,can_self_request)
select 'DOMAIN_REVIEWER','Revisor/a especializado/a','Revisa traducciones de dominios sensibles como identidad, pagos, seguridad, cumplimiento o legal. Requiere además acreditación del dominio correspondiente.',c.id,'COMMUNITY_VALIDATED',true,true,true
from public.capabilities c where c.name='linguistic.domain.review'
on conflict(role_code) do update set
 display_name=excluded.display_name,
 description=excluded.description,
 capability_id=excluded.capability_id,
 minimum_proficiency=excluded.minimum_proficiency,
 requires_verified_qualification=true,
 requires_independent_review=true,
 can_self_request=true,
 is_active=true;

create table if not exists public.linguistic_domain_qualifications (
  id uuid primary key default gen_random_uuid(),
  contributor_id uuid not null references public.linguistic_contributors(id) on delete restrict,
  language_id uuid not null references public.languages(id) on delete restrict,
  variant_id uuid references public.language_variants(id) on delete restrict,
  context_name text not null references public.linguistic_context_policies(context_name) on delete restrict,
  qualification_level text not null default 'GENERAL' check (qualification_level in ('GENERAL','SPECIALIZED','EXPERT')),
  verification_status text not null default 'SELF_REPORTED' check (verification_status in ('SELF_REPORTED','PENDING','VERIFIED','REJECTED','REVOKED')),
  evidence_note text,
  verified_by_person_id uuid references public.persons(id) on delete restrict,
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint linguistic_domain_qual_variant_fk foreign key(language_id,variant_id)
    references public.language_variants(language_id,id) on delete restrict,
  unique nulls not distinct (contributor_id,language_id,variant_id,context_name)
);

alter table public.linguistic_domain_qualifications enable row level security;
revoke all on public.linguistic_domain_qualifications from anon,authenticated;

alter table public.linguistic_profiles
  add constraint linguistic_profiles_variant_requires_language
  check (selected_variant_id is null or selected_language_id is not null);

create or replace function public.tc_get_linguistic_context_requirements()
returns table(
 context_name text,
 allow_fuzzy boolean,
 recommended_minimum_domain_level text,
 requires_specialized_review boolean
)
language sql
security definer
set search_path=public,pg_temp
stable
as $$
 select p.context_name,p.allow_fuzzy,
   case when p.context_name in ('LEGAL','PAYMENT','SAFETY','COMPLIANCE','IDENTITY') then 'SPECIALIZED' else 'GENERAL' end,
   (p.context_name in ('LEGAL','PAYMENT','SAFETY','COMPLIANCE','IDENTITY'))
 from public.linguistic_context_policies p
 where p.is_active=true
 order by p.context_name;
$$;
revoke all on function public.tc_get_linguistic_context_requirements() from public;
grant execute on function public.tc_get_linguistic_context_requirements() to anon,authenticated;

commit;
begin;

create table if not exists public.tc_governance_eligibility_roles (
  id uuid primary key default gen_random_uuid(),
  role_code text not null unique,
  seat_id uuid not null references public.tc_governance_seat_catalog(id) on delete restrict,
  display_name text not null,
  purpose text not null,
  requirements_summary text not null,
  status text not null default 'DESIGN_APPROVED' check (status in ('DRAFT','DESIGN_APPROVED','LEGAL_VERIFIED','RETIRED')),
  legal_status text not null default 'PENDING' check (legal_status in ('PENDING','APPROVED','REJECTED','NOT_REQUIRED')),
  created_at timestamptz not null default now()
);

create table if not exists public.tc_governance_seat_eligibilities (
  id uuid primary key default gen_random_uuid(),
  seat_id uuid not null references public.tc_governance_seat_catalog(id) on delete restrict,
  eligibility_role_id uuid not null references public.tc_governance_eligibility_roles(id) on delete restrict,
  profile_id uuid not null references public.profiles(id) on delete restrict,
  status text not null default 'PENDING' check (status in ('PENDING','VERIFIED','SUSPENDED','REVOKED','EXPIRED')),
  evidence_summary text,
  evidence jsonb not null default '{}'::jsonb,
  verified_by_profile_id uuid references public.profiles(id) on delete restrict,
  verified_at timestamptz,
  valid_from timestamptz,
  valid_until timestamptz,
  created_at timestamptz not null default now(),
  unique(seat_id, profile_id, eligibility_role_id)
);

alter table public.tc_governance_eligibility_roles enable row level security;
alter table public.tc_governance_seat_eligibilities enable row level security;

revoke all on public.tc_governance_eligibility_roles from anon, authenticated;
revoke all on public.tc_governance_seat_eligibilities from anon, authenticated;

insert into public.tc_governance_eligibility_roles(role_code,seat_id,display_name,purpose,requirements_summary)
select 'MISSION_GUARDIAN_ELIGIBLE', id, 'Elegible para Guardián de la misión',
       'Protege la misión fundacional y la continuidad institucional.',
       'Requiere designación válida conforme a las reglas de sucesión y gobernanza; no se obtiene por ser cliente, administrador o inversionista.'
from public.tc_governance_seat_catalog where seat_code='MISSION_GUARDIAN'
on conflict (role_code) do nothing;

insert into public.tc_governance_eligibility_roles(role_code,seat_id,display_name,purpose,requirements_summary)
select 'COMMUNITY_REPRESENTATIVE_ELIGIBLE', id, 'Elegible para Representación Comunitaria',
       'Representa intereses y efectos reales sobre una comunidad o territorio.',
       'Requiere vínculo comunitario verificable, legitimidad/selección conforme al mecanismo comunitario definido y ausencia de conflicto incompatible; ser cliente por sí solo no basta.'
from public.tc_governance_seat_catalog where seat_code='COMMUNITY_REPRESENTATIVE'
on conflict (role_code) do nothing;

insert into public.tc_governance_eligibility_roles(role_code,seat_id,display_name,purpose,requirements_summary)
select 'CULTURAL_DATA_CUSTODIAN_ELIGIBLE', id, 'Elegible para Custodia Cultural, Lingüística y de Datos Comunitarios',
       'Protege idiomas, cultura, memoria, saberes, voces y datos comunitarios.',
       'Requiere experiencia o legitimidad cultural/lingüística/comunitaria verificada, conocimiento de las reglas de custodia y ausencia de conflicto incompatible; un rol de traductor o cliente por sí solo no basta.'
from public.tc_governance_seat_catalog where seat_code='CULTURAL_DATA_CUSTODIAN'
on conflict (role_code) do nothing;

insert into public.tc_governance_eligibility_roles(role_code,seat_id,display_name,purpose,requirements_summary)
select 'OPERATIONS_STEWARD_ELIGIBLE', id, 'Elegible para Custodia de Operaciones',
       'Aporta criterio operativo sobre logística, comercio, PTC, transporte y continuidad de servicio.',
       'Requiere función operativa relevante y verificada; ser cliente por sí solo no basta.'
from public.tc_governance_seat_catalog where seat_code='OPERATIONS_STEWARD'
on conflict (role_code) do nothing;

insert into public.tc_governance_eligibility_roles(role_code,seat_id,display_name,purpose,requirements_summary)
select 'INDEPENDENT_LEGAL_STEWARD_ELIGIBLE', id, 'Elegible para Custodia Independiente y Legal',
       'Aporta revisión independiente, cumplimiento y criterio legal cuando corresponda.',
       'Requiere independencia verificable y la cualificación apropiada para el alcance asignado; ser cliente, administrador o inversionista por sí solo no basta.'
from public.tc_governance_seat_catalog where seat_code='INDEPENDENT_LEGAL_STEWARD'
on conflict (role_code) do nothing;

create or replace function public.tc_governance_membership_requires_verified_eligibility()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ok boolean;
begin
  select exists(
    select 1
    from public.tc_governance_seat_eligibilities e
    join public.tc_governance_eligibility_roles r on r.id=e.eligibility_role_id
    where e.seat_id=new.seat_id
      and e.profile_id=new.profile_id
      and e.status='VERIFIED'
      and r.seat_id=new.seat_id
      and r.status in ('DESIGN_APPROVED','LEGAL_VERIFIED')
      and (e.valid_from is null or e.valid_from <= now())
      and (e.valid_until is null or e.valid_until > now())
  ) into v_ok;

  if not coalesce(v_ok,false) then
    raise exception 'GOVERNANCE_SEAT_ELIGIBILITY_REQUIRED';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_governance_membership_requires_verified_eligibility on public.tc_governance_council_memberships;
create trigger trg_governance_membership_requires_verified_eligibility
before insert or update of seat_id, profile_id, status
on public.tc_governance_council_memberships
for each row
when (new.status in ('NOMINATED','ACTIVE'))
execute function public.tc_governance_membership_requires_verified_eligibility();

create or replace function public.tc_governance_eligibility_integrity_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role_seat uuid;
begin
  select seat_id into v_role_seat
  from public.tc_governance_eligibility_roles
  where id=new.eligibility_role_id;

  if v_role_seat is null or v_role_seat <> new.seat_id then
    raise exception 'GOVERNANCE_ELIGIBILITY_ROLE_SEAT_MISMATCH';
  end if;

  if new.status='VERIFIED' then
    if new.verified_by_profile_id is null or new.verified_at is null then
      raise exception 'GOVERNANCE_ELIGIBILITY_VERIFICATION_EVIDENCE_REQUIRED';
    end if;
    if new.verified_by_profile_id = new.profile_id then
      raise exception 'GOVERNANCE_SELF_VERIFICATION_FORBIDDEN';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_governance_eligibility_integrity_guard on public.tc_governance_seat_eligibilities;
create trigger trg_governance_eligibility_integrity_guard
before insert or update
on public.tc_governance_seat_eligibilities
for each row
execute function public.tc_governance_eligibility_integrity_guard();

commit;
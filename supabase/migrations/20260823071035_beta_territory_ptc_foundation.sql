create table if not exists public.countries (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.departments (
  id uuid primary key default gen_random_uuid(),
  country_id uuid not null references public.countries(id) on delete restrict,
  code text not null,
  name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(country_id, code),
  unique(country_id, name)
);

create table if not exists public.municipalities (
  id uuid primary key default gen_random_uuid(),
  department_id uuid not null references public.departments(id) on delete restrict,
  code text not null,
  name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(department_id, code),
  unique(department_id, name)
);

create table if not exists public.communities (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default ('COM-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,12))),
  municipality_id uuid not null references public.municipalities(id) on delete restrict,
  name text not null,
  community_type text not null default 'COMMUNITY' check (community_type in ('COMMUNITY','ALDEA','CASERIO','BARRIO','ZONE','OTHER')),
  latitude numeric(9,6),
  longitude numeric(9,6),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(municipality_id, name),
  check (latitude is null or latitude between -90 and 90),
  check (longitude is null or longitude between -180 and 180)
);

create table if not exists public.ptc_points (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique default ('PTC-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,12))),
  community_id uuid not null references public.communities(id) on delete restrict,
  public_name text not null,
  address_label text,
  latitude numeric(9,6),
  longitude numeric(9,6),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (latitude is null or latitude between -90 and 90),
  check (longitude is null or longitude between -180 and 180)
);

create table if not exists public.service_coverage (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references public.communities(id) on delete cascade,
  ptc_id uuid references public.ptc_points(id) on delete set null,
  coverage_mode text not null check (coverage_mode in ('HOME','PTC','PARTIAL','NONE')),
  home_delivery_available boolean not null default false,
  is_active boolean not null default true,
  notes text,
  updated_at timestamptz not null default now(),
  unique(community_id)
);

create index if not exists idx_departments_country on public.departments(country_id);
create index if not exists idx_municipalities_department on public.municipalities(department_id);
create index if not exists idx_communities_municipality on public.communities(municipality_id);
create index if not exists idx_ptc_points_community on public.ptc_points(community_id);
create index if not exists idx_service_coverage_community on public.service_coverage(community_id);

alter table public.countries enable row level security;
alter table public.departments enable row level security;
alter table public.municipalities enable row level security;
alter table public.communities enable row level security;
alter table public.ptc_points enable row level security;
alter table public.service_coverage enable row level security;

do $$ begin
  create policy countries_public_read on public.countries for select using (is_active);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy departments_public_read on public.departments for select using (is_active);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy municipalities_public_read on public.municipalities for select using (is_active);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy communities_public_read on public.communities for select using (is_active);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy ptc_points_public_read on public.ptc_points for select using (is_active);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy service_coverage_public_read on public.service_coverage for select using (is_active);
exception when duplicate_object then null; end $$;

insert into public.countries(code,name)
values ('GTM','Guatemala')
on conflict (code) do update set name=excluded.name, is_active=true;

with c as (select id from public.countries where code='GTM')
insert into public.departments(country_id,code,name)
select c.id, x.code, x.name
from c cross join (values
 ('01','Guatemala'),('02','El Progreso'),('03','Sacatepéquez'),('04','Chimaltenango'),('05','Escuintla'),('06','Santa Rosa'),('07','Sololá'),('08','Totonicapán'),('09','Quetzaltenango'),('10','Suchitepéquez'),('11','Retalhuleu'),('12','San Marcos'),('13','Huehuetenango'),('14','Quiché'),('15','Baja Verapaz'),('16','Alta Verapaz'),('17','Petén'),('18','Izabal'),('19','Zacapa'),('20','Chiquimula'),('21','Jalapa'),('22','Jutiapa')
) as x(code,name)
on conflict (country_id,code) do update set name=excluded.name, is_active=true;

with d as (
  select id from public.departments where name='Huehuetenango' and country_id=(select id from public.countries where code='GTM')
)
insert into public.municipalities(department_id,code,name)
select d.id, x.code, x.name
from d cross join (values
 ('SMI','San Mateo Ixtatán'),
 ('SCB','Santa Cruz Barillas'),
 ('SSC','San Sebastián Coatán'),
 ('NEN','Nentón')
) as x(code,name)
on conflict (department_id,code) do update set name=excluded.name, is_active=true;

with m as (
  select id,name from public.municipalities where department_id=(select id from public.departments where name='Huehuetenango' and country_id=(select id from public.countries where code='GTM'))
)
insert into public.communities(municipality_id,name,community_type)
select m.id, x.community_name, x.community_type
from m join (values
 ('San Mateo Ixtatán','Bulej','ALDEA'),
 ('San Mateo Ixtatán','Yalambojoch','ALDEA'),
 ('San Mateo Ixtatán','Centro','BARRIO'),
 ('Santa Cruz Barillas','Centro','BARRIO'),
 ('San Sebastián Coatán','Centro','BARRIO'),
 ('Nentón','Centro','BARRIO')
) as x(municipality_name,community_name,community_type)
on m.name=x.municipality_name
on conflict (municipality_id,name) do update set is_active=true;

insert into public.ptc_points(community_id,public_name,address_label)
select c.id,
       case when c.name='Bulej' then 'Punto TU COMUNIDAD Bulej Centro'
            when c.name='Yalambojoch' then 'Punto TU COMUNIDAD Yalambojoch'
            else 'Punto TU COMUNIDAD ' || c.name end,
       c.name
from public.communities c
join public.municipalities m on m.id=c.municipality_id
where m.name='San Mateo Ixtatán' and c.name in ('Bulej','Yalambojoch','Centro')
and not exists (select 1 from public.ptc_points p where p.community_id=c.id and p.is_active);

insert into public.service_coverage(community_id,ptc_id,coverage_mode,home_delivery_available,notes)
select c.id,p.id,
       case when c.name='Bulej' then 'HOME' else 'PTC' end,
       (c.name='Bulej'),
       'Beta STAGING inicial'
from public.communities c
left join public.ptc_points p on p.community_id=c.id and p.is_active
join public.municipalities m on m.id=c.municipality_id
where m.name='San Mateo Ixtatán' and c.name in ('Bulej','Yalambojoch','Centro')
on conflict (community_id) do update set ptc_id=excluded.ptc_id, coverage_mode=excluded.coverage_mode, home_delivery_available=excluded.home_delivery_available, is_active=true, notes=excluded.notes, updated_at=now();
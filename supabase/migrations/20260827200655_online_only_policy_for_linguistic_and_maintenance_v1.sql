begin;

create table if not exists public.tc_online_only_policies (
  policy_key text primary key,
  domain text not null,
  display_name text not null,
  online_required boolean not null default true,
  allow_offline_draft boolean not null default false,
  allow_offline_queue boolean not null default false,
  allow_later_sync boolean not null default false,
  reason text not null,
  status text not null default 'APPROVED' check (status in ('DRAFT','APPROVED','RETIRED')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.tc_online_only_policies (
  policy_key, domain, display_name, online_required, allow_offline_draft, allow_offline_queue, allow_later_sync, reason, status
) values
  ('linguistics.online_only','LINGUISTICS','Trabajo lingüístico en línea',true,false,false,false,'Traducción, corrección, revisión, validación, terminología, voz, transcripción y QA requieren sesión conectada y datos vigentes en Supabase.','APPROVED'),
  ('maintenance.online_only','SYSTEM_MAINTENANCE','Mantenimiento de TU COMUNIDAD en línea',true,false,false,false,'Cambios técnicos, administrativos, configuración, mantenimiento y operaciones de sistema requieren conexión activa y validación contra el backend autoritativo.','APPROVED')
on conflict (policy_key) do update set
  online_required = excluded.online_required,
  allow_offline_draft = excluded.allow_offline_draft,
  allow_offline_queue = excluded.allow_offline_queue,
  allow_later_sync = excluded.allow_later_sync,
  reason = excluded.reason,
  status = excluded.status,
  updated_at = now();

alter table public.linguistic_tasks
  add column if not exists online_required boolean not null default true;

update public.linguistic_tasks set online_required = true where online_required is distinct from true;

alter table public.linguistic_tasks
  drop constraint if exists linguistic_tasks_online_required_check;

alter table public.linguistic_tasks
  add constraint linguistic_tasks_online_required_check check (online_required = true);

commit;
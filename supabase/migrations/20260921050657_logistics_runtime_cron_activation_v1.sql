
create extension if not exists pg_cron with schema pg_catalog;

grant usage on schema cron to postgres;
grant all privileges on all tables in schema cron to postgres;

select cron.schedule(
  'tc-logistics-runtime-worker',
  '30 seconds',
  $$select public.tc_process_logistics_runtime_batch(25);$$
);


create or replace function public.tc_process_logistics_runtime_batch(
  p_limit integer default 20
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_job record;
  v_attempt integer;
  v_started timestamptz;
  v_result jsonb;
  v_error_code text;
  v_error_message text;
  v_outcome text;
  v_succeeded integer := 0;
  v_retried integer := 0;
  v_dead integer := 0;
  v_processed integer := 0;
begin
  if p_limit<1 or p_limit>100 then
    raise exception using errcode='P0001', message='TC_RUNTIME_BATCH_LIMIT_INVALID';
  end if;

  for v_job in
    select o.id,o.max_attempts
    from public.logistics_runtime_outbox o
    where o.status in ('PENDING','RETRY')
      and o.available_at<=now()
    order by o.available_at,o.created_at,o.id
    limit p_limit
    for update skip locked
  loop
    v_started:=clock_timestamp();

    update public.logistics_runtime_outbox
       set status='PROCESSING',
           attempt_count=attempt_count+1,
           locked_at=now(),
           last_error=null
     where id=v_job.id
     returning attempt_count into v_attempt;

    begin
      v_result:=public.tc_process_logistics_runtime_event(v_job.id);

      update public.logistics_runtime_outbox
         set status='SUCCEEDED',
             processed_at=now(),
             locked_at=null,
             result=v_result,
             last_error=null
       where id=v_job.id;

      insert into public.logistics_runtime_attempts(
        outbox_id,attempt_no,outcome,result,
        started_at,finished_at
      ) values(
        v_job.id,v_attempt,'SUCCEEDED',v_result,
        v_started,clock_timestamp()
      );

      v_succeeded:=v_succeeded+1;
    exception
      when others then
        v_error_code:=sqlstate;
        v_error_message:=sqlerrm;

        if v_attempt>=v_job.max_attempts then
          v_outcome:='DEAD';

          update public.logistics_runtime_outbox
             set status='DEAD',
                 processed_at=now(),
                 locked_at=null,
                 last_error=v_error_code||':'||v_error_message
           where id=v_job.id;

          v_dead:=v_dead+1;
        else
          v_outcome:='RETRY';

          update public.logistics_runtime_outbox
             set status='RETRY',
                 available_at=now()+(least(v_attempt,10)*interval '30 seconds'),
                 locked_at=null,
                 last_error=v_error_code||':'||v_error_message
           where id=v_job.id;

          v_retried:=v_retried+1;
        end if;

        insert into public.logistics_runtime_attempts(
          outbox_id,attempt_no,outcome,error_code,error_message,
          started_at,finished_at
        ) values(
          v_job.id,v_attempt,v_outcome,v_error_code,v_error_message,
          v_started,clock_timestamp()
        );
    end;

    v_processed:=v_processed+1;
  end loop;

  return jsonb_build_object(
    'processed',v_processed,
    'succeeded',v_succeeded,
    'retried',v_retried,
    'dead',v_dead
  );
end;
$$;

revoke all on function public.tc_process_logistics_runtime_batch(integer)
  from public,anon,authenticated;
grant execute on function public.tc_process_logistics_runtime_batch(integer)
  to service_role;

comment on function public.tc_process_logistics_runtime_batch(integer) is
'Concurrent-safe logistics outbox worker using FOR UPDATE SKIP LOCKED. Each event is idempotently deduplicated at enqueue and retried with bounded backoff; DEAD after max_attempts.';

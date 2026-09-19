
begin;

create unique index if not exists uq_ui_dictionary_one_active_general
  on public.ui_dictionary_versions(target_language_id)
  where is_released and target_variant_id is null;

create unique index if not exists uq_ui_dictionary_one_active_variant
  on public.ui_dictionary_versions(target_language_id,target_variant_id)
  where is_released and target_variant_id is not null;

do $$ begin
  alter table public.ui_dictionary_versions
    add constraint ui_dictionary_versions_active_state_check
    check (
      (is_released
       and lifecycle_status='RELEASED'
       and released_at is not null
       and invalidated_at is null)
      or
      (not is_released and lifecycle_status<>'RELEASED')
    );
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.ui_dictionary_versions
    add constraint ui_dictionary_versions_invalidation_state_check
    check (
      (invalidated_at is null and lifecycle_status<>'INVALIDATED')
      or
      (invalidated_at is not null
       and lifecycle_status='INVALIDATED'
       and not is_released)
    );
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.ui_dictionary_versions
    add constraint ui_dictionary_versions_release_history_check
    check (
      released_at is null
      or lifecycle_status in('RELEASED','SUPERSEDED','INVALIDATED')
    );
exception when duplicate_object then null; end $$;

create or replace function public.tc_guard_ui_release_entry()
returns trigger
language plpgsql
set search_path to ''
as $function$
declare
  v_old_status text;
  v_new_status text;
begin
  if tg_op in ('UPDATE','DELETE') then
    select v.lifecycle_status
      into v_old_status
    from public.ui_dictionary_versions v
    where v.id=old.dictionary_version_id;

    if v_old_status is distinct from 'DRAFT' then
      raise exception 'UI_RELEASE_HISTORY_IMMUTABLE';
    end if;
  end if;

  if tg_op in ('INSERT','UPDATE') then
    select v.lifecycle_status
      into v_new_status
    from public.ui_dictionary_versions v
    where v.id=new.dictionary_version_id;

    if v_new_status is distinct from 'DRAFT' then
      raise exception 'UI_RELEASE_HISTORY_IMMUTABLE';
    end if;
  end if;

  if tg_op='DELETE' then return old; end if;
  return new;
end;
$function$;

drop trigger if exists trg_ui_entry_immutable
  on public.ui_dictionary_release_entries;
create trigger trg_ui_entry_immutable
before insert or update or delete on public.ui_dictionary_release_entries
for each row execute function public.tc_guard_ui_release_entry();

create or replace function public.tc_block_ui_release_decision_mutation()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  raise exception 'UI_RELEASE_DECISION_IMMUTABLE';
end;
$function$;

drop trigger if exists trg_ui_release_decision_immutable
  on public.ui_dictionary_release_decisions;
create trigger trg_ui_release_decision_immutable
before update or delete on public.ui_dictionary_release_decisions
for each row execute function public.tc_block_ui_release_decision_mutation();

create or replace function public.compile_ui_dictionary_release(
  p_version_code integer,
  p_description text,
  p_target_language_id uuid,
  p_target_variant_id uuid default null
) returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_version uuid;
  v_hash text;
  v_holes int;
  v_person uuid;
  v_latest integer;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.tc_is_feature_enabled('linguistics.publication') then
    raise exception 'LINGUISTIC_PUBLICATION_DISABLED';
  end if;
  if not public.tc_check_my_permission(
    'linguistic.release.manage','GLOBAL'::public.tc_scope_type,null
  ) then
    raise exception 'LINGUISTIC_RELEASE_MANAGE_FORBIDDEN';
  end if;
  if p_version_code is null or p_version_code<1 then
    raise exception 'INVALID_VERSION_CODE';
  end if;

  select p.id into v_person
  from public.persons p
  where p.auth_user_id=auth.uid();
  if v_person is null then raise exception 'AUTHENTICATED_PERSON_REQUIRED'; end if;

  perform 1
  from public.languages l
  where l.id=p_target_language_id and l.is_active
  for update;
  if not found then raise exception 'TARGET_LANGUAGE_NOT_ACTIVE'; end if;

  if p_target_variant_id is not null and not exists(
    select 1
    from public.language_variants lv
    where lv.id=p_target_variant_id
      and lv.language_id=p_target_language_id
      and lv.is_active
  ) then
    raise exception 'TARGET_VARIANT_NOT_ACTIVE';
  end if;

  select max(v.version_code)
    into v_latest
  from public.ui_dictionary_versions v
  where v.target_language_id=p_target_language_id
    and v.target_variant_id is not distinct from p_target_variant_id;

  if v_latest is not null and p_version_code<=v_latest then
    raise exception 'RELEASE_VERSION_NOT_NEWER_THAN_LATEST';
  end if;

  insert into public.ui_dictionary_versions(
    version_code,target_language_id,target_variant_id,content_hash,
    description,lifecycle_status,is_released
  ) values(
    p_version_code,p_target_language_id,p_target_variant_id,'PENDING',
    p_description,'DRAFT',false
  ) returning id into v_version;

  with ranked as (
    select
      k.id key_id,
      tp.id trp_id,
      tp.language_id,
      tp.variant_id,
      case
        when p_target_variant_id is not null
         and tp.language_id=p_target_language_id
         and tp.variant_id=p_target_variant_id then 1
        when tp.language_id=p_target_language_id
         and tp.variant_id is null then 2
        when tp.language_id=cp.fallback_language_id
         and tp.variant_id is null then 3
      end rk,
      case
        when p_target_variant_id is not null
         and tp.language_id=p_target_language_id
         and tp.variant_id=p_target_variant_id then 'EXACT_VARIANT'
        when tp.language_id=p_target_language_id
         and tp.variant_id is null then 'LANGUAGE_GENERAL'
        when tp.language_id=cp.fallback_language_id
         and tp.variant_id is null then 'SYSTEM_FALLBACK'
      end rt,
      row_number() over(
        partition by k.id
        order by
          case
            when p_target_variant_id is not null
             and tp.language_id=p_target_language_id
             and tp.variant_id=p_target_variant_id then 1
            when tp.language_id=p_target_language_id
             and tp.variant_id is null then 2
            when tp.language_id=cp.fallback_language_id
             and tp.variant_id is null then 3
            else 9
          end,
          (tp.consensus_status='VERIFICADA') desc,
          tp.created_at,
          tp.id
      ) rn
    from public.ui_interface_keys k
    join public.linguistic_context_policies cp
      on cp.context_name=k.context_name
     and cp.is_active
    join public.languages fl
      on fl.id=cp.fallback_language_id
     and fl.is_active
    join public.linguistic_context_policy_statuses cps
      on cps.policy_id=cp.id
    join public.translation_proposals tp
      on tp.concept_id=k.concept_id
     and tp.consensus_status=cps.allowed_status
     and tp.retired_at is null
     and tp.publication_status not in('RETIRED','SUPERSEDED')
    where tp.language_id=cp.fallback_language_id
       or (
         tp.language_id=p_target_language_id
         and tp.source_submission_id is not null
         and coalesce(
           (public.tc_linguistic_submission_readiness(
             tp.source_submission_id
           )->>'ready')::boolean,
           false
         )
       )
  ), winners as (
    select * from ranked where rn=1 and rk is not null
  )
  insert into public.ui_dictionary_release_entries(
    dictionary_version_id,ui_key_id,translation_proposal_id,
    resolved_language_id,resolved_variant_id,resolution_type
  )
  select
    v_version,key_id,trp_id,language_id,variant_id,rt
  from winners;

  select count(*)
    into v_holes
  from public.ui_interface_keys k
  left join public.ui_dictionary_release_entries e
    on e.dictionary_version_id=v_version
   and e.ui_key_id=k.id
  left join public.translation_proposals tp
    on tp.id=e.translation_proposal_id
  where k.context_name in('PAYMENT','LEGAL','SAFETY','IDENTITY','COMPLIANCE')
    and (e.id is null or tp.consensus_status<>'VERIFICADA');

  if v_holes>0 then
    raise exception 'RELEASE_BLOCKED_CRITICAL_GAPS:%',v_holes;
  end if;

  select encode(
    extensions.digest(
      convert_to(
        coalesce(
          string_agg(
            k.ui_key||chr(31)||tp.texto_original||chr(30),
            '' order by k.ui_key
          ),
          ''
        ),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  )
  into v_hash
  from public.ui_dictionary_release_entries e
  join public.ui_interface_keys k on k.id=e.ui_key_id
  join public.translation_proposals tp on tp.id=e.translation_proposal_id
  where e.dictionary_version_id=v_version;

  update public.ui_dictionary_versions
  set content_hash=v_hash,
      lifecycle_status='DRAFT',
      is_released=false,
      released_at=null,
      invalidated_at=null,
      invalidation_reason=null
  where id=v_version;

  insert into public.ui_dictionary_release_decisions(
    release_id,decision_type,actor_person_id,note,metadata
  ) values(
    v_version,'COMPILED',v_person,p_description,
    jsonb_build_object(
      'version_code',p_version_code,
      'content_hash',v_hash
    )
  );

  return v_version;
end;
$function$;

create or replace function public.tc_validate_ui_dictionary_release(
  p_release_public_id text,
  p_note text default null
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v public.ui_dictionary_versions%rowtype;
  v_person uuid;
  v_hash text;
  v_invalid int;
  v_key_count int;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.tc_is_feature_enabled('linguistics.publication') then
    raise exception 'LINGUISTIC_PUBLICATION_DISABLED';
  end if;
  if not public.tc_check_my_permission(
    'linguistic.release.validate','GLOBAL'::public.tc_scope_type,null
  ) then
    raise exception 'LINGUISTIC_RELEASE_VALIDATE_FORBIDDEN';
  end if;

  select p.id into v_person
  from public.persons p
  where p.auth_user_id=auth.uid();

  select * into v
  from public.ui_dictionary_versions
  where public_id=p_release_public_id
  for update;

  if not found then raise exception 'RELEASE_NOT_FOUND'; end if;
  if v.lifecycle_status<>'DRAFT' or v.is_released then
    raise exception 'RELEASE_NOT_DRAFT';
  end if;

  select count(*)
    into v_invalid
  from public.ui_dictionary_release_entries e
  join public.translation_proposals tp
    on tp.id=e.translation_proposal_id
  where e.dictionary_version_id=v.id
    and (
      tp.retired_at is not null
      or tp.publication_status in('RETIRED','SUPERSEDED')
      or (
        tp.source_submission_id is not null
        and not coalesce(
          (public.tc_linguistic_submission_readiness(
            tp.source_submission_id
          )->>'ready')::boolean,
          false
        )
      )
    );

  if v_invalid>0 then
    raise exception 'RELEASE_HAS_NOT_READY_ENTRIES:%',v_invalid;
  end if;

  select count(*)
    into v_key_count
  from public.ui_dictionary_release_entries
  where dictionary_version_id=v.id;

  if v_key_count=0 then raise exception 'RELEASE_EMPTY'; end if;

  select encode(
    extensions.digest(
      convert_to(
        coalesce(
          string_agg(
            k.ui_key||chr(31)||tp.texto_original||chr(30),
            '' order by k.ui_key
          ),
          ''
        ),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  )
  into v_hash
  from public.ui_dictionary_release_entries e
  join public.ui_interface_keys k on k.id=e.ui_key_id
  join public.translation_proposals tp on tp.id=e.translation_proposal_id
  where e.dictionary_version_id=v.id;

  if v_hash is distinct from v.content_hash then
    raise exception 'RELEASE_HASH_MISMATCH';
  end if;

  update public.ui_dictionary_versions
  set lifecycle_status='VALIDATED',
      validated_by_person_id=v_person,
      validated_at=now(),
      validation_summary=jsonb_build_object(
        'key_count',v_key_count,
        'content_hash',v_hash,
        'invalid_entries',v_invalid
      )
  where id=v.id;

  insert into public.ui_dictionary_release_decisions(
    release_id,decision_type,actor_person_id,note,metadata
  ) values(
    v.id,'VALIDATED',v_person,p_note,
    jsonb_build_object(
      'key_count',v_key_count,
      'content_hash',v_hash
    )
  );

  return jsonb_build_object(
    'success',true,
    'release_public_id',v.public_id,
    'status','VALIDATED',
    'key_count',v_key_count,
    'content_hash',v_hash
  );
end;
$function$;

create or replace function public.tc_activate_ui_dictionary_release(
  p_release_public_id text,
  p_note text default null
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v public.ui_dictionary_versions%rowtype;
  v_person uuid;
  v_old uuid;
  v_old_code integer;
  v_hash text;
  v_invalid integer;
  v_key_count integer;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.tc_is_feature_enabled('linguistics.publication') then
    raise exception 'LINGUISTIC_PUBLICATION_DISABLED';
  end if;
  if not public.tc_check_my_permission(
    'linguistic.release.activate','GLOBAL'::public.tc_scope_type,null
  ) then
    raise exception 'LINGUISTIC_RELEASE_ACTIVATE_FORBIDDEN';
  end if;

  select p.id into v_person
  from public.persons p
  where p.auth_user_id=auth.uid();

  select * into v
  from public.ui_dictionary_versions
  where public_id=p_release_public_id
  for update;

  if not found then raise exception 'RELEASE_NOT_FOUND'; end if;
  if v.lifecycle_status<>'APPROVED' then
    raise exception 'RELEASE_NOT_APPROVED';
  end if;
  if v.validated_by_person_id is null
     or v.approved_by_person_id is null
     or v.validated_by_person_id=v.approved_by_person_id then
    raise exception 'RELEASE_SEPARATION_OF_DUTIES_FAILED';
  end if;

  perform 1
  from public.languages l
  where l.id=v.target_language_id
  for update;

  select cur.id,cur.version_code
    into v_old,v_old_code
  from public.ui_dictionary_versions cur
  where cur.is_released
    and cur.target_language_id=v.target_language_id
    and cur.target_variant_id is not distinct from v.target_variant_id
    and cur.id<>v.id
  order by cur.version_code desc
  limit 1
  for update;

  if v_old is not null and v.version_code<=v_old_code then
    raise exception 'RELEASE_VERSION_NOT_NEWER_THAN_CURRENT';
  end if;

  select count(*)
    into v_invalid
  from public.ui_dictionary_release_entries e
  join public.translation_proposals tp
    on tp.id=e.translation_proposal_id
  where e.dictionary_version_id=v.id
    and (
      tp.retired_at is not null
      or tp.publication_status in('RETIRED','SUPERSEDED')
      or (
        tp.source_submission_id is not null
        and not coalesce(
          (public.tc_linguistic_submission_readiness(
            tp.source_submission_id
          )->>'ready')::boolean,
          false
        )
      )
    );

  if v_invalid>0 then
    raise exception 'RELEASE_HAS_NOT_READY_ENTRIES:%',v_invalid;
  end if;

  select count(*)
    into v_key_count
  from public.ui_dictionary_release_entries
  where dictionary_version_id=v.id;

  if v_key_count=0 then raise exception 'RELEASE_EMPTY'; end if;

  select encode(
    extensions.digest(
      convert_to(
        coalesce(
          string_agg(
            k.ui_key||chr(31)||tp.texto_original||chr(30),
            '' order by k.ui_key
          ),
          ''
        ),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  )
  into v_hash
  from public.ui_dictionary_release_entries e
  join public.ui_interface_keys k on k.id=e.ui_key_id
  join public.translation_proposals tp on tp.id=e.translation_proposal_id
  where e.dictionary_version_id=v.id;

  if v_hash is distinct from v.content_hash then
    raise exception 'RELEASE_HASH_MISMATCH';
  end if;

  if v_old is not null then
    update public.ui_dictionary_versions
    set is_released=false,
        lifecycle_status='SUPERSEDED'
    where id=v_old;

    insert into public.ui_dictionary_release_decisions(
      release_id,decision_type,actor_person_id,note,metadata
    ) values(
      v_old,'SUPERSEDED',v_person,p_note,
      jsonb_build_object('superseded_by',v.public_id)
    );
  end if;

  update public.ui_dictionary_versions
  set is_released=true,
      released_at=coalesce(released_at,now()),
      lifecycle_status='RELEASED',
      activated_by_person_id=v_person,
      supersedes_version_id=v_old,
      invalidated_at=null,
      invalidation_reason=null
  where id=v.id;

  insert into public.ui_dictionary_release_decisions(
    release_id,decision_type,actor_person_id,note
  ) values(v.id,'ACTIVATED',v_person,p_note);

  return jsonb_build_object(
    'success',true,
    'release_public_id',v.public_id,
    'status','RELEASED'
  );
end;
$function$;

create or replace function public.tc_create_ui_dictionary_rollback(
  p_source_release_public_id text,
  p_new_version_code integer,
  p_description text default null
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  src public.ui_dictionary_versions%rowtype;
  v_new uuid;
  v_new_public text;
  v_person uuid;
  v_count int;
  v_latest integer;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.tc_is_feature_enabled('linguistics.publication') then
    raise exception 'LINGUISTIC_PUBLICATION_DISABLED';
  end if;
  if not public.tc_check_my_permission(
    'linguistic.release.rollback','GLOBAL'::public.tc_scope_type,null
  ) then
    raise exception 'LINGUISTIC_RELEASE_ROLLBACK_FORBIDDEN';
  end if;
  if p_new_version_code is null or p_new_version_code<1 then
    raise exception 'INVALID_VERSION_CODE';
  end if;

  select p.id into v_person
  from public.persons p
  where p.auth_user_id=auth.uid();

  select * into src
  from public.ui_dictionary_versions
  where public_id=p_source_release_public_id
  for update;

  if not found then raise exception 'SOURCE_RELEASE_NOT_FOUND'; end if;
  if src.released_at is null then raise exception 'SOURCE_WAS_NEVER_RELEASED'; end if;
  if src.invalidated_at is not null or src.lifecycle_status='INVALIDATED' then
    raise exception 'SOURCE_RELEASE_INVALIDATED';
  end if;

  perform 1
  from public.languages l
  where l.id=src.target_language_id
  for update;

  select max(v.version_code)
    into v_latest
  from public.ui_dictionary_versions v
  where v.target_language_id=src.target_language_id
    and v.target_variant_id is not distinct from src.target_variant_id;

  if v_latest is not null and p_new_version_code<=v_latest then
    raise exception 'RELEASE_VERSION_NOT_NEWER_THAN_LATEST';
  end if;

  insert into public.ui_dictionary_versions(
    version_code,target_language_id,target_variant_id,content_hash,
    description,is_released,lifecycle_status,rollback_of_version_id
  ) values(
    p_new_version_code,src.target_language_id,src.target_variant_id,
    src.content_hash,
    coalesce(p_description,'Rollback from '||src.public_id),
    false,'DRAFT',src.id
  ) returning id,public_id into v_new,v_new_public;

  insert into public.ui_dictionary_release_entries(
    dictionary_version_id,ui_key_id,translation_proposal_id,
    resolved_language_id,resolved_variant_id,resolution_type
  )
  select
    v_new,ui_key_id,translation_proposal_id,
    resolved_language_id,resolved_variant_id,resolution_type
  from public.ui_dictionary_release_entries
  where dictionary_version_id=src.id;

  get diagnostics v_count=row_count;
  if v_count=0 then raise exception 'SOURCE_RELEASE_EMPTY'; end if;

  insert into public.ui_dictionary_release_decisions(
    release_id,decision_type,actor_person_id,note,metadata
  ) values(
    v_new,'ROLLBACK_CREATED',v_person,p_description,
    jsonb_build_object(
      'rollback_of',src.public_id,
      'entry_count',v_count
    )
  );

  return jsonb_build_object(
    'success',true,
    'release_public_id',v_new_public,
    'status','DRAFT',
    'rollback_of',src.public_id,
    'entry_count',v_count
  );
end;
$function$;

revoke all on function public.tc_guard_ui_release_entry()
  from public,anon,authenticated;
revoke all on function public.tc_block_ui_release_decision_mutation()
  from public,anon,authenticated;

revoke all on function public.compile_ui_dictionary_release(integer,text,uuid,uuid)
  from public,anon;
grant execute on function public.compile_ui_dictionary_release(integer,text,uuid,uuid)
  to authenticated;

revoke all on function public.tc_validate_ui_dictionary_release(text,text)
  from public,anon;
grant execute on function public.tc_validate_ui_dictionary_release(text,text)
  to authenticated;

revoke all on function public.tc_activate_ui_dictionary_release(text,text)
  from public,anon;
grant execute on function public.tc_activate_ui_dictionary_release(text,text)
  to authenticated;

revoke all on function public.tc_create_ui_dictionary_rollback(text,integer,text)
  from public,anon;
grant execute on function public.tc_create_ui_dictionary_rollback(text,integer,text)
  to authenticated;

commit;

create or replace function public.tc_create_ui_dictionary_rollback(
  p_source_release_public_id text,
  p_new_version_code integer,
  p_description text default null::text
)
returns jsonb
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
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.tc_is_feature_enabled('linguistics.publication') then raise exception 'LINGUISTIC_PUBLICATION_DISABLED'; end if;
  if not public.tc_check_my_permission('linguistic.release.rollback','GLOBAL'::public.tc_scope_type,null) then raise exception 'LINGUISTIC_RELEASE_ROLLBACK_FORBIDDEN'; end if;
  if p_new_version_code is null or p_new_version_code<1 then raise exception 'INVALID_VERSION_CODE'; end if;

  select p.id into v_person
  from public.persons p
  where p.auth_user_id=auth.uid();

  select * into src
  from public.ui_dictionary_versions
  where public_id=p_source_release_public_id;

  if not found then raise exception 'SOURCE_RELEASE_NOT_FOUND'; end if;
  if src.released_at is null then raise exception 'SOURCE_WAS_NEVER_RELEASED'; end if;
  if src.invalidated_at is not null or src.lifecycle_status='INVALIDATED' then
    raise exception 'SOURCE_RELEASE_INVALIDATED';
  end if;

  insert into public.ui_dictionary_versions(
    version_code,target_language_id,target_variant_id,content_hash,description,
    is_released,lifecycle_status,rollback_of_version_id
  )
  values(
    p_new_version_code,src.target_language_id,src.target_variant_id,src.content_hash,
    coalesce(p_description,'Rollback from '||src.public_id),false,'DRAFT',src.id
  )
  returning id,public_id into v_new,v_new_public;

  insert into public.ui_dictionary_release_entries(
    dictionary_version_id,ui_key_id,translation_proposal_id,
    resolved_language_id,resolved_variant_id,resolution_type
  )
  select
    v_new,ui_key_id,translation_proposal_id,
    resolved_language_id,resolved_variant_id,resolution_type
  from public.ui_dictionary_release_entries
  where dictionary_version_id=src.id;

  get diagnostics v_count = row_count;
  if v_count=0 then raise exception 'SOURCE_RELEASE_EMPTY'; end if;

  insert into public.ui_dictionary_release_decisions(
    release_id,decision_type,actor_person_id,note,metadata
  )
  values(
    v_new,'ROLLBACK_CREATED',v_person,p_description,
    jsonb_build_object('rollback_of',src.public_id,'entry_count',v_count)
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
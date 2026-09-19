begin;

create or replace function public.get_ui_dictionary_bundle(p_client_lang_id uuid,p_client_var_id uuid default null,p_target_version integer default null)
returns jsonb
language plpgsql
stable security definer
set search_path = ''
as $$
declare
  v_version uuid;
  v_code int;
  v_hash text;
  v_payload jsonb;
  v_key_count int;
  v_invalid boolean;
begin
  select v.id,v.version_code,v.content_hash into v_version,v_code,v_hash
  from public.ui_dictionary_versions v
  where v.is_released
    and v.target_language_id=p_client_lang_id
    and v.target_variant_id is not distinct from p_client_var_id
  order by v.version_code desc limit 1;

  if v_version is null then
    return jsonb_build_object('dictionary_version',null,'dictionary_hash',null,'key_count',0,'requires_sync',true,'invalidate_cache',true,'release_valid',false,'translations','{}'::jsonb);
  end if;

  select exists(
    select 1
    from public.ui_dictionary_release_entries e
    join public.translation_proposals tp on tp.id=e.translation_proposal_id
    where e.dictionary_version_id=v_version
      and tp.source_submission_id is not null
      and not coalesce((public.tc_linguistic_submission_readiness(tp.source_submission_id)->>'ready')::boolean,false)
  ) into v_invalid;

  if v_invalid then
    return jsonb_build_object('dictionary_version',v_code,'dictionary_hash',v_hash,'key_count',0,'requires_sync',true,'invalidate_cache',true,'release_valid',false,'translations','{}'::jsonb);
  end if;

  select count(*) into v_key_count from public.ui_dictionary_release_entries e where e.dictionary_version_id=v_version;
  if p_target_version is not null and p_target_version=v_code then
    return jsonb_build_object('dictionary_version',v_code,'dictionary_hash',v_hash,'key_count',v_key_count,'requires_sync',false,'invalidate_cache',false,'release_valid',true,'translations','{}'::jsonb);
  end if;

  select jsonb_object_agg(k.ui_key,tp.texto_original order by k.ui_key) into v_payload
  from public.ui_dictionary_release_entries e
  join public.ui_interface_keys k on k.id=e.ui_key_id
  join public.translation_proposals tp on tp.id=e.translation_proposal_id
  where e.dictionary_version_id=v_version;

  return jsonb_build_object('dictionary_version',v_code,'dictionary_hash',v_hash,'key_count',v_key_count,'requires_sync',true,'invalidate_cache',false,'release_valid',true,'translations',coalesce(v_payload,'{}'::jsonb));
end;
$$;

create or replace function public.resolve_ui_translation_bundle(p_namespace text,p_requested_keys text[],p_client_lang_id uuid,p_client_var_id uuid default null)
returns table(
  ui_key text,display_text text,resolved_language_id uuid,resolved_variant_id uuid,
  translation_id uuid,translation_public_id text,resolution_type text,translation_status text,
  fallback_used boolean,missing_translation boolean,dictionary_version integer,dictionary_hash text
)
language plpgsql
stable security definer
set search_path = ''
as $$
declare v_version uuid; v_code int; v_hash text;
begin
  select v.id,v.version_code,v.content_hash into v_version,v_code,v_hash
  from public.ui_dictionary_versions v
  where v.is_released and v.target_language_id=p_client_lang_id
    and v.target_variant_id is not distinct from p_client_var_id
  order by v.version_code desc limit 1;
  if v_version is null then return; end if;

  return query
  with req as (
    select k.id,k.ui_key from public.ui_interface_keys k
    where k.namespace=p_namespace and (p_requested_keys is null or k.ui_key=any(p_requested_keys))
  ), resolved as (
    select r.ui_key,e.resolved_language_id,e.resolved_variant_id,e.resolution_type,tp.*
    from req r
    left join public.ui_dictionary_release_entries e
      on e.dictionary_version_id=v_version and e.ui_key_id=r.id
    left join public.translation_proposals tp
      on tp.id=e.translation_proposal_id
      and (tp.source_submission_id is null
           or coalesce((public.tc_linguistic_submission_readiness(tp.source_submission_id)->>'ready')::boolean,false))
  )
  select x.ui_key,
         coalesce(x.texto_original,'[MISSING_TRANSLATION]'),
         x.resolved_language_id,x.resolved_variant_id,
         x.id,x.public_id,x.resolution_type,x.consensus_status,
         coalesce(x.resolution_type='SYSTEM_FALLBACK',true),
         (x.id is null),v_code,v_hash
  from resolved x;
end;
$$;

commit;
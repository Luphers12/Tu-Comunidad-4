
create index if not exists idx_ui_release_decisions_release_created
  on public.ui_dictionary_release_decisions(release_id,created_at desc);

create index if not exists idx_ui_release_decisions_actor_created
  on public.ui_dictionary_release_decisions(actor_person_id,created_at desc);

create index if not exists idx_ui_release_entries_translation
  on public.ui_dictionary_release_entries(translation_proposal_id);

create index if not exists idx_ui_release_entries_ui_key
  on public.ui_dictionary_release_entries(ui_key_id);

create index if not exists idx_ui_release_entries_resolved_language_variant
  on public.ui_dictionary_release_entries(resolved_language_id,resolved_variant_id);

create index if not exists idx_ui_versions_validated_by
  on public.ui_dictionary_versions(validated_by_person_id)
  where validated_by_person_id is not null;

create index if not exists idx_ui_versions_approved_by
  on public.ui_dictionary_versions(approved_by_person_id)
  where approved_by_person_id is not null;

create index if not exists idx_ui_versions_activated_by
  on public.ui_dictionary_versions(activated_by_person_id)
  where activated_by_person_id is not null;

create index if not exists idx_ui_versions_supersedes
  on public.ui_dictionary_versions(supersedes_version_id)
  where supersedes_version_id is not null;

create index if not exists idx_ui_versions_rollback_of
  on public.ui_dictionary_versions(rollback_of_version_id)
  where rollback_of_version_id is not null;

create index if not exists idx_ui_versions_latest_general
  on public.ui_dictionary_versions(target_language_id,version_code desc)
  where target_variant_id is null;

create index if not exists idx_ui_versions_latest_variant
  on public.ui_dictionary_versions(
    target_language_id,target_variant_id,version_code desc
  )
  where target_variant_id is not null;

-- VERIFIED REPLAY OVERLAY — 2026-09-20
-- Apply after 20260824031258_linguistic_core_ui_canonical_v1.sql
-- and before 20260827191235_linguistic_assessment_chuj_smi_pilot_v1.sql.
-- LIVE STAGING value verified: Chuj / cac.

update public.languages
set iso_code='cac'
where name='Chuj' and iso_code is null;

do $$
begin
  if not exists (select 1 from public.languages where name='Chuj' and iso_code='cac') then
    raise exception 'TC_REPLAY_CHUJ_ISO_NOT_RECOVERED';
  end if;
end $$;

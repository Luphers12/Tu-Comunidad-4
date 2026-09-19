-- Make affiliation evidence/review history tamper-resistant while leaving applicant requirement payload editable only through RPC.

create or replace function public.tc_guard_affiliation_requirement_mutation()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  -- Requirements may be updated only by trusted RPCs / service-side code.
  -- Direct authenticated table writes are already blocked by RLS (SELECT-only policies),
  -- so this trigger mainly protects against accidental DELETE.
  if tg_op='DELETE' then
    raise exception 'AFFILIATION_REQUIREMENT_DELETE_FORBIDDEN' using errcode='P0001';
  end if;
  return new;
end;
$function$;

revoke all on function public.tc_guard_affiliation_requirement_mutation() from public, anon, authenticated;

drop trigger if exists trg_affiliation_requirement_no_delete on public.affiliation_application_requirements;
create trigger trg_affiliation_requirement_no_delete
before delete on public.affiliation_application_requirements
for each row execute function public.tc_guard_affiliation_requirement_mutation();

create or replace function public.tc_guard_affiliation_evidence_link_mutation()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  raise exception 'AFFILIATION_EVIDENCE_LINK_APPEND_ONLY' using errcode='P0001';
end;
$function$;

revoke all on function public.tc_guard_affiliation_evidence_link_mutation() from public, anon, authenticated;

drop trigger if exists trg_affiliation_evidence_link_append_only on public.affiliation_application_evidence_links;
create trigger trg_affiliation_evidence_link_append_only
before update or delete on public.affiliation_application_evidence_links
for each row execute function public.tc_guard_affiliation_evidence_link_mutation();

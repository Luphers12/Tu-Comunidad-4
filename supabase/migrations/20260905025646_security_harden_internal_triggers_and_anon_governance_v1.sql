-- Internal trigger functions must never be callable through the exposed RPC API.
revoke all on function public.tc_block_governance_history_mutation() from public, anon, authenticated;
revoke all on function public.tc_block_minor_disclosure_event_mutation() from public, anon, authenticated;
revoke all on function public.tc_block_minor_incident_event_mutation() from public, anon, authenticated;
revoke all on function public.tc_governance_eligibility_integrity_guard() from public, anon, authenticated;
revoke all on function public.tc_governance_membership_requires_verified_eligibility() from public, anon, authenticated;
revoke all on function public.tc_guard_governance_membership_workspace() from public, anon, authenticated;
revoke all on function public.tc_guard_governance_profile() from public, anon, authenticated;
revoke all on function public.tc_guard_governance_review_update() from public, anon, authenticated;
revoke all on function public.tc_guard_governance_workspace() from public, anon, authenticated;
revoke all on function public.tc_guard_minor_authority_notification() from public, anon, authenticated;
revoke all on function public.tc_guard_minor_disclosure_request() from public, anon, authenticated;
revoke all on function public.tc_validate_assessment_item_score() from public, anon, authenticated;

-- Fix the one mutable search_path reported by the database security advisor.
alter function public.tc_block_minor_incident_event_mutation() set search_path = '';

-- Governance mutations and sensitive readiness helpers require a signed-in caller.
-- Keep authenticated access intact because these functions perform their own
-- capability/identity checks; remove accidental anonymous exposure.
revoke execute on function public.tc_create_governance_proposal(text,text,text,jsonb,text,text) from public, anon;
revoke execute on function public.tc_submit_governance_proposal(uuid) from public, anon;
revoke execute on function public.tc_review_governance_proposal(uuid,text,text,text) from public, anon;
revoke execute on function public.tc_mark_governance_proposal_approved(uuid) from public, anon;
revoke execute on function public.tc_withdraw_my_governance_review(uuid,text) from public, anon;
revoke execute on function public.tc_governance_evaluate_proposal(uuid) from public, anon;
revoke execute on function public.tc_governance_current_profile(character varying) from public, anon;
revoke execute on function public.tc_governance_active_membership(uuid) from public, anon;
revoke execute on function public.tc_linguistic_submission_approval_readiness(uuid) from public, anon;
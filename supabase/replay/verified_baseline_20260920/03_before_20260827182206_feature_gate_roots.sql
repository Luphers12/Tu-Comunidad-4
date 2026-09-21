-- VERIFIED REPLAY OVERLAY — 2026-09-20
-- Apply before 20260827182206_linguistic_employment_compensation_chain_v1.sql.
-- Both parent feature gates were verified LIVE and remain fail-closed.

insert into public.tc_feature_gates
(feature_key,domain,parent_feature_key,display_name,source_status,backend_status,safety_status,legal_status,cultural_status,approval_status,is_enabled,notes)
values
('linguistics.work_program','LINGUISTICS',null,'Programa de trabajo lingüístico','VERIFIED','VERIFIED','PENDING','PENDING','PENDING','PENDING',false,'Raíz del dominio lingüístico. Fail-closed: habilita solo tras aprobación de seguridad, legal y cultural.')
on conflict(feature_key) do update set
  backend_status='VERIFIED', is_enabled=false, updated_at=now();

insert into public.tc_feature_gates
(feature_key,domain,parent_feature_key,display_name,source_status,backend_status,safety_status,legal_status,cultural_status,approval_status,is_enabled,notes)
values
('linguistics.compensation','LINGUISTICS','linguistics.work_program','Compensación de trabajo lingüístico','VERIFIED','VERIFIED','PENDING','PENDING','PENDING','PENDING',false,'Raíz de compensación lingüística. Fail-closed: no autoriza emitir dinero ni Créditos TC.')
on conflict(feature_key) do update set
  backend_status='VERIFIED', is_enabled=false, updated_at=now();

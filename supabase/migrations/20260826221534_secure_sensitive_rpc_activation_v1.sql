begin;

insert into public.tc_feature_gates (
  feature_key, domain, display_name,
  source_status, backend_status, safety_status, legal_status, cultural_status, approval_status,
  is_enabled, notes
)
values
  ('commerce.checkout','COMMERCE','Checkout real','VERIFIED','VERIFIED','NOT_REQUIRED','PENDING','NOT_REQUIRED','PENDING',false,'RPC probado, pero bloqueado hasta aprobación de activación.'),
  ('logistics.driver_assignment','LOGISTICS','Asignación real de conductor','VERIFIED','VERIFIED','PENDING','PENDING','NOT_REQUIRED','PENDING',false,'RPC probado, pero bloqueado hasta aprobación operativa/legal.'),
  ('logistics.custody_sync','LOGISTICS','Sincronización de custodia','VERIFIED','VERIFIED','PENDING','PENDING','NOT_REQUIRED','PENDING',false,'Procesamiento offline/custodia bloqueado hasta activación operativa.'),
  ('operations.sync_conflict_resolution','OPERATIONS','Resolución de conflictos de sincronización','VERIFIED','VERIFIED','PENDING','PENDING','NOT_REQUIRED','PENDING',false,'Flujo administrativo sensible; bloqueado hasta política de autorización explícita.')
on conflict (feature_key) do nothing;

revoke execute on function public.execute_checkout(text,text,text,jsonb,text) from authenticated;
revoke execute on function public.assign_driver_route(text,text,text,text) from authenticated;
revoke execute on function public.process_event(jsonb) from authenticated;
revoke execute on function public.resolve_sync_conflict(text,text,text,text) from authenticated;

commit;
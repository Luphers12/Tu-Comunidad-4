ALTER FUNCTION public.execute_checkout(text, text, text, jsonb, text) SET search_path = public, extensions, pg_temp;
ALTER FUNCTION public.assign_driver_route(text, text, text, text) SET search_path = public, extensions, pg_temp;
ALTER FUNCTION public.process_event(jsonb) SET search_path = public, extensions, pg_temp;
CREATE INDEX idx_tc_scopes_capability_id
    ON public.profile_capability_scopes (capability_id);

DROP POLICY IF EXISTS policy_select_profile_capability_scopes
ON public.profile_capability_scopes;

CREATE POLICY policy_select_profile_capability_scopes
ON public.profile_capability_scopes
FOR SELECT TO authenticated
USING (
    EXISTS (
        SELECT 1
        FROM public.persons pe
        JOIN public.profiles pr ON pr.person_id = pe.id
        WHERE pe.auth_user_id = (SELECT auth.uid())
          AND pr.id = profile_capability_scopes.profile_id
    )
);
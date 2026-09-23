# TU COMUNIDAD — GUARDIAN MCP CHECKOUT AUDIT TOOL

**Local date:** 2026-09-22  
**Supabase:** STAGING `ckvwfeljoonwhzmtrmnw`  
**Edge Function:** `guardian-mcp`  
**Deployed version:** 2  
**Edge bundle SHA-256:** `81eb116f9dcb690fe6c248625ec4f51a90a3eb3e0da471cf4625a0fb29d2ff14`  
**Backend branch:** `tc/full-build-20260918`  
**Production / merge / deploy:** NOT TOUCHED

## Purpose

Extend the existing CrewAI Guardian Supabase MCP with one narrow, purpose-built READ ONLY audit tool:

`guardian_checkout_requirements_gate_v1`

The tool is designed for the V4 Guardian checkout requirements audit without exposing arbitrary SQL or private application data.

## Security boundary preserved

The Edge Function continues to use:

- custom bearer-token authentication;
- `SET TRANSACTION READ ONLY`;
- `SET LOCAL ROLE guardian_mcp_reader`;
- hard-coded allowlisted tools;
- no arbitrary SQL input;
- no PII output;
- no business-table write path.

`verify_jwt=false` remains unchanged because the existing function performs its own bearer-token hash authentication.

## Tool coverage

Direct catalog verification now covers:

- A — legacy checkout retired/fail-closed and grants;
- B — manual store acceptance retired/fail-closed and grants;
- C — provider-independent payment requirement columns/shape constraint;
- D — trusted payment marker boundary and grants;
- E — explicit checkout payment gate;
- F — payment-to-order binding defense-in-depth trigger/guard;
- G — canonical package grain.

The exact catalog query was independently executed under `guardian_mcp_reader` in a READ ONLY transaction after deployment and produced:

`A=true, B=true, C=true, D=true, E=true, F=true, G=true`.

## Intentionally not broadened

The tool returns `NO VERIFICADO` for evidence outside the current safe boundary:

- H — full migration/source parity needs migration-history access plus separate GitHub read-only evidence;
- I — exact no-test-residue counts need a purpose-built aggregate surface because `guardian_mcp_reader` has no direct business-table SELECT;
- J — database SECURITY DEFINER executable counts are observable, but Supabase management Security Advisor is outside the DB-only MCP boundary.

These limitations are explicit rather than bypassed with broader privileges.

## Database impact

- schema migrations added: **0**
- application/business data writes: **0**
- RLS changes: **0**
- role grants changed: **0**
- public RPC changes: **0**

Only the existing STAGING Edge Function was updated.

## Repository parity

The deployed `guardian-mcp` source is now stored at:

`supabase/functions/guardian-mcp/index.ts`

This creates a repository source for the previously live-only Edge Function and allows future code review/parity checks.

## Next safe work

Mac-independent work can continue around narrow Guardian read-only evidence surfaces.

Mac/FlutterFlow-dependent work remains deferred until a compatible computer is available.

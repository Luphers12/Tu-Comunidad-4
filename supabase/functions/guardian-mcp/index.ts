import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.7";

const EXPECTED_TOKEN_SHA256 = "879c200e1b45aed576438c1f28e7ce762c9f79bb9b0e57f57feff429ee823bef";
const DB_URL = Deno.env.get("SUPABASE_DB_URL");
if (!DB_URL) throw new Error("SUPABASE_DB_URL is not available");

const sql = postgres(DB_URL, {
  max: 1,
  idle_timeout: 5,
  connect_timeout: 5,
  prepare: false,
});

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, mcp-protocol-version, mcp-session-id",
  "Access-Control-Allow-Methods": "POST, GET, DELETE, OPTIONS",
  "Access-Control-Expose-Headers": "mcp-session-id",
};

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

async function sha256Hex(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(hash)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function authenticate(req: Request): Promise<boolean> {
  const header = req.headers.get("authorization") ?? "";
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) return false;
  const digest = await sha256Hex(match[1]);
  return digest === EXPECTED_TOKEN_SHA256;
}

async function runAffiliationIntegrity() {
  return await sql.begin(async (tx) => {
    await tx.unsafe("SET TRANSACTION READ ONLY");
    await tx.unsafe("SET LOCAL ROLE guardian_mcp_reader");
    const rows = await tx.unsafe(
      "select anomaly_code, severity, affected_count, invariant from guardian_audit.guardian_affiliation_integrity_v1() order by severity, anomaly_code"
    );
    return rows.map((r) => ({
      anomaly_code: String(r.anomaly_code),
      severity: String(r.severity),
      affected_count: Number(r.affected_count),
      invariant: String(r.invariant),
    }));
  });
}


async function runCheckoutRequirementsGate() {
  return await sql.begin(async (tx) => {
    await tx.unsafe("SET TRANSACTION READ ONLY");
    await tx.unsafe("SET LOCAL ROLE guardian_mcp_reader");

    const rows = await tx.unsafe(`
      with f as (
        select
          pg_catalog.to_regprocedure('public.execute_checkout(text,text,text,jsonb,text)') as legacy_checkout_oid,
          pg_catalog.to_regprocedure('public.tc_accept_sub_order(text,text)') as manual_accept_oid,
          pg_catalog.to_regprocedure('public.tc_mark_checkout_payment_requirement_satisfied(text,text,text,jsonb)') as payment_mark_oid,
          pg_catalog.to_regprocedure('public.tc_commit_checkout(text,text,text)') as commit_oid,
          pg_catalog.to_regprocedure('public.tc_guard_payment_order_binding_requires_satisfaction()') as binding_guard_oid,
          pg_catalog.to_regprocedure('public.tc_start_preparation(text,text,text)') as start_prep_oid,
          pg_catalog.to_regprocedure('public.tc_source_allocate_reserve(text,jsonb,text)') as source_alloc_oid
      ),
      d as (
        select
          *,
          case when legacy_checkout_oid is null then null else pg_catalog.pg_get_functiondef(legacy_checkout_oid) end as legacy_checkout_def,
          case when manual_accept_oid is null then null else pg_catalog.pg_get_functiondef(manual_accept_oid) end as manual_accept_def,
          case when payment_mark_oid is null then null else pg_catalog.pg_get_functiondef(payment_mark_oid) end as payment_mark_def,
          case when commit_oid is null then null else pg_catalog.pg_get_functiondef(commit_oid) end as commit_def,
          case when binding_guard_oid is null then null else pg_catalog.pg_get_functiondef(binding_guard_oid) end as binding_guard_def,
          case when start_prep_oid is null then null else pg_catalog.pg_get_functiondef(start_prep_oid) end as start_prep_def,
          case when source_alloc_oid is null then null else pg_catalog.pg_get_functiondef(source_alloc_oid) end as source_alloc_def
        from f
      ),
      cols as (
        select
          count(*) filter (where a.attname in (
            'payment_requirement_satisfied',
            'payment_requirement_satisfied_at',
            'payment_requirement_basis',
            'payment_requirement_provider_event_ref'
          )) = 4 as four_columns,
          bool_or(
            a.attname='payment_requirement_satisfied'
            and pg_catalog.format_type(a.atttypid,a.atttypmod)='boolean'
            and a.attnotnull
            and pg_catalog.pg_get_expr(ad.adbin,ad.adrelid)='false'
          ) as gate_column_correct,
          bool_or(
            a.attname='payment_requirement_satisfied_at'
            and pg_catalog.format_type(a.atttypid,a.atttypmod)='timestamp with time zone'
            and not a.attnotnull
          ) as gate_time_correct
        from pg_catalog.pg_attribute a
        join pg_catalog.pg_class c on c.oid=a.attrelid
        join pg_catalog.pg_namespace n on n.oid=c.relnamespace
        left join pg_catalog.pg_attrdef ad on ad.adrelid=a.attrelid and ad.adnum=a.attnum
        where n.nspname='public'
          and c.relname='payment_authorizations'
          and a.attnum>0
          and not a.attisdropped
      ),
      shape as (
        select exists(
          select 1
          from pg_catalog.pg_constraint con
          join pg_catalog.pg_class c on c.oid=con.conrelid
          join pg_catalog.pg_namespace n on n.oid=c.relnamespace
          where n.nspname='public'
            and c.relname='payment_authorizations'
            and con.conname='payment_authorizations_requirement_shape_check'
            and position('payment_requirement_satisfied' in lower(pg_catalog.pg_get_constraintdef(con.oid,true))) > 0
            and position('payment_requirement_satisfied_at is not null' in lower(pg_catalog.pg_get_constraintdef(con.oid,true))) > 0
            and position('payment_requirement_basis' in lower(pg_catalog.pg_get_constraintdef(con.oid,true))) > 0
        ) as shape_constraint_present
      ),
      trig as (
        select exists(
          select 1
          from pg_catalog.pg_trigger t
          join pg_catalog.pg_class c on c.oid=t.tgrelid
          join pg_catalog.pg_namespace n on n.oid=c.relnamespace
          where n.nspname='public'
            and c.relname='payment_authorizations'
            and not t.tgisinternal
            and t.tgname='payment_authorizations_order_binding_guard'
            and position('tc_guard_payment_order_binding_requires_satisfaction' in lower(pg_catalog.pg_get_triggerdef(t.oid,true))) > 0
        ) as binding_trigger_present
      ),
      sec as (
        select
          count(*) filter (
            where p.prosecdef and pg_catalog.has_function_privilege('anon',p.oid,'EXECUTE')
          )::bigint as anon_sd_exec,
          count(*) filter (
            where p.prosecdef and pg_catalog.has_function_privilege('authenticated',p.oid,'EXECUTE')
          )::bigint as auth_sd_exec
        from pg_catalog.pg_proc p
        join pg_catalog.pg_namespace n on n.oid=p.pronamespace
        where n.nspname='public'
      )
      select jsonb_build_object(
        'legacy_exists', d.legacy_checkout_oid is not null,
        'legacy_retired', coalesce(position('TC_LEGACY_CHECKOUT_RETIRED_USE_QUOTE_PAYMENT_COMMIT' in d.legacy_checkout_def)>0,false),
        'legacy_anon_exec', case when d.legacy_checkout_oid is null then false else pg_catalog.has_function_privilege('anon',d.legacy_checkout_oid,'EXECUTE') end,
        'legacy_auth_exec', case when d.legacy_checkout_oid is null then false else pg_catalog.has_function_privilege('authenticated',d.legacy_checkout_oid,'EXECUTE') end,
        'legacy_service_exec', case when d.legacy_checkout_oid is null then false else pg_catalog.has_function_privilege('service_role',d.legacy_checkout_oid,'EXECUTE') end,

        'manual_exists', d.manual_accept_oid is not null,
        'manual_retired', coalesce(position('TC_MANUAL_SUB_ORDER_ACCEPTANCE_RETIRED' in d.manual_accept_def)>0,false),
        'manual_anon_exec', case when d.manual_accept_oid is null then false else pg_catalog.has_function_privilege('anon',d.manual_accept_oid,'EXECUTE') end,
        'manual_auth_exec', case when d.manual_accept_oid is null then false else pg_catalog.has_function_privilege('authenticated',d.manual_accept_oid,'EXECUTE') end,
        'manual_service_exec', case when d.manual_accept_oid is null then false else pg_catalog.has_function_privilege('service_role',d.manual_accept_oid,'EXECUTE') end,

        'payment_four_columns', cols.four_columns,
        'payment_gate_column_correct', coalesce(cols.gate_column_correct,false),
        'payment_gate_time_correct', coalesce(cols.gate_time_correct,false),
        'payment_shape_constraint_present', shape.shape_constraint_present,

        'marker_exists', d.payment_mark_oid is not null,
        'marker_service_exec', case when d.payment_mark_oid is null then false else pg_catalog.has_function_privilege('service_role',d.payment_mark_oid,'EXECUTE') end,
        'marker_anon_exec', case when d.payment_mark_oid is null then false else pg_catalog.has_function_privilege('anon',d.payment_mark_oid,'EXECUTE') end,
        'marker_auth_exec', case when d.payment_mark_oid is null then false else pg_catalog.has_function_privilege('authenticated',d.payment_mark_oid,'EXECUTE') end,
        'marker_event_present', coalesce(position('PAYMENT_REQUIREMENT_SATISFIED' in d.payment_mark_def)>0,false),
        'marker_sets_gate', coalesce(position('payment_requirement_satisfied=true' in replace(lower(d.payment_mark_def),' ',''))>0,false),

        'commit_exists', d.commit_oid is not null,
        'commit_checks_gate', coalesce(position('payment_requirement_satisfied' in lower(d.commit_def))>0,false),
        'commit_checks_gate_time', coalesce(position('payment_requirement_satisfied_at is null' in lower(d.commit_def))>0,false),
        'commit_gate_error', coalesce(position('TC_PAYMENT_REQUIREMENT_NOT_SATISFIED' in d.commit_def)>0,false),
        'old_generic_state_gate_absent', coalesce(position('v_pay.state not in' in lower(d.commit_def))=0,true),

        'binding_guard_exists', d.binding_guard_oid is not null,
        'binding_trigger_present', trig.binding_trigger_present,
        'binding_checks_order', coalesce(position('new.order_id is not null' in lower(d.binding_guard_def))>0,false),
        'binding_checks_gate', coalesce(position('payment_requirement_satisfied' in lower(d.binding_guard_def))>0,false),
        'binding_gate_error', coalesce(position('TC_PAYMENT_REQUIREMENT_NOT_SATISFIED' in d.binding_guard_def)>0,false),

        'commit_does_not_create_pkg', coalesce(position('insert into public.packages' in lower(d.commit_def))=0,true),
        'commit_reports_zero_pkg', coalesce(position('''package_count'',0' in replace(lower(d.commit_def),' ',''))>0,false),
        'prep_creates_pkg', coalesce(position('insert into public.packages' in lower(d.start_prep_def))>0,false),
        'prep_requires_reservation', coalesce(position('tc_reservation_required' in lower(d.start_prep_def))>0,false),
        'source_reserves_inventory', coalesce(position('tc_inv_reserve' in lower(d.source_alloc_def))>0,false),

        'anon_sd_exec_count', sec.anon_sd_exec,
        'auth_sd_exec_count', sec.auth_sd_exec
      ) as audit
      from d cross join cols cross join shape cross join trig cross join sec
    `);

    const a = rows?.[0]?.audit ?? {};
    const yes = (v: unknown) => v === true;
    const noExec3 = (prefix: string) =>
      a[prefix + "_anon_exec"] === false &&
      a[prefix + "_auth_exec"] === false &&
      a[prefix + "_service_exec"] === false;

    const A = yes(a.legacy_exists) && yes(a.legacy_retired) && noExec3("legacy");
    const B = yes(a.manual_exists) && yes(a.manual_retired) && noExec3("manual");
    const C = yes(a.payment_four_columns) && yes(a.payment_gate_column_correct) &&
      yes(a.payment_gate_time_correct) && yes(a.payment_shape_constraint_present);
    const D = yes(a.marker_exists) && yes(a.marker_service_exec) &&
      a.marker_anon_exec === false && a.marker_auth_exec === false &&
      yes(a.marker_event_present) && yes(a.marker_sets_gate);
    const E = yes(a.commit_exists) && yes(a.commit_checks_gate) &&
      yes(a.commit_checks_gate_time) && yes(a.commit_gate_error) &&
      yes(a.old_generic_state_gate_absent);
    const F = yes(a.binding_guard_exists) && yes(a.binding_trigger_present) &&
      yes(a.binding_checks_order) && yes(a.binding_checks_gate) && yes(a.binding_gate_error);
    const G = yes(a.commit_does_not_create_pkg) && yes(a.commit_reports_zero_pkg) &&
      yes(a.prep_creates_pkg) && yes(a.prep_requires_reservation) &&
      yes(a.source_reserves_inventory);

    return [
      {
        check_code: "A",
        check_name: "Legacy checkout fail-closed",
        result: A ? "PASS" : "FAIL",
        confidence: "ALTA",
        evidence: {
          function_exists: a.legacy_exists,
          retired_stub: a.legacy_retired,
          anon_execute: a.legacy_anon_exec,
          authenticated_execute: a.legacy_auth_exec,
          service_role_execute: a.legacy_service_exec,
        },
        canonical_expected: "execute_checkout is a retired fail-closed stub with no anon/authenticated/service_role EXECUTE.",
        risk: A ? "NONE OBSERVED" : "Legacy checkout may bypass canonical quote/payment/commit.",
        missing_evidence: null,
      },
      {
        check_code: "B",
        check_name: "Manual store acceptance retired",
        result: B ? "PASS" : "FAIL",
        confidence: "ALTA",
        evidence: {
          function_exists: a.manual_exists,
          retired_stub: a.manual_retired,
          anon_execute: a.manual_anon_exec,
          authenticated_execute: a.manual_auth_exec,
          service_role_execute: a.manual_service_exec,
        },
        canonical_expected: "Committed store inventory does not require a universal manual per-order acceptance RPC.",
        risk: B ? "NONE OBSERVED" : "Manual store acceptance may reintroduce a non-canonical blocking step.",
        missing_evidence: null,
      },
      {
        check_code: "C",
        check_name: "Provider-independent payment requirement shape",
        result: C ? "PASS" : "FAIL",
        confidence: "ALTA",
        evidence: {
          four_columns: a.payment_four_columns,
          gate_column_correct: a.payment_gate_column_correct,
          gate_timestamp_correct: a.payment_gate_time_correct,
          shape_constraint_present: a.payment_shape_constraint_present,
        },
        canonical_expected: "payment_authorizations has the explicit provider-independent payment requirement gate and evidence-shape constraint.",
        risk: C ? "NONE OBSERVED" : "Payment requirement evidence shape may be incomplete.",
        missing_evidence: null,
      },
      {
        check_code: "D",
        check_name: "Trusted payment adapter boundary",
        result: D ? "PASS" : "FAIL",
        confidence: "ALTA",
        evidence: {
          function_exists: a.marker_exists,
          service_role_execute: a.marker_service_exec,
          anon_execute: a.marker_anon_exec,
          authenticated_execute: a.marker_auth_exec,
          evidence_event_present: a.marker_event_present,
          sets_gate: a.marker_sets_gate,
        },
        canonical_expected: "Only trusted backend service boundary may mark payment requirement satisfied and must append evidence.",
        risk: D ? "NONE OBSERVED" : "Untrusted caller or incomplete evidence may satisfy the payment gate.",
        missing_evidence: null,
      },
      {
        check_code: "E",
        check_name: "Checkout commit explicit payment gate",
        result: E ? "PASS" : "FAIL",
        confidence: "ALTA",
        evidence: {
          function_exists: a.commit_exists,
          checks_gate: a.commit_checks_gate,
          checks_gate_timestamp: a.commit_checks_gate_time,
          fail_closed_error_present: a.commit_gate_error,
          old_generic_provider_state_gate_absent: a.old_generic_state_gate_absent,
        },
        canonical_expected: "tc_commit_checkout requires the explicit payment requirement gate rather than a provider state label alone.",
        risk: E ? "NONE OBSERVED" : "Checkout may commit without canonical payment evidence.",
        missing_evidence: null,
      },
      {
        check_code: "F",
        check_name: "Defense in depth on payment-to-order binding",
        result: F ? "PASS" : "FAIL",
        confidence: "ALTA",
        evidence: {
          guard_exists: a.binding_guard_exists,
          trigger_present: a.binding_trigger_present,
          checks_order_binding: a.binding_checks_order,
          checks_payment_gate: a.binding_checks_gate,
          fail_closed_error_present: a.binding_gate_error,
        },
        canonical_expected: "PAY->ORDER binding independently fails closed if the payment requirement is not satisfied.",
        risk: F ? "NONE OBSERVED" : "Direct payment-to-order binding may bypass the checkout gate.",
        missing_evidence: null,
      },
      {
        check_code: "G",
        check_name: "Canonical package grain",
        result: G ? "PASS" : "FAIL",
        confidence: "ALTA",
        evidence: {
          checkout_does_not_create_pkg: a.commit_does_not_create_pkg,
          checkout_reports_zero_pkg: a.commit_reports_zero_pkg,
          sourcing_reserves_inventory: a.source_reserves_inventory,
          preparation_requires_reservation: a.prep_requires_reservation,
          preparation_creates_pkg: a.prep_creates_pkg,
        },
        canonical_expected: "payment -> order demand -> sourcing -> inventory reservation -> preparation -> PKG birth.",
        risk: G ? "NONE OBSERVED" : "PKG may be created at the wrong grain or before inventory reservation.",
        missing_evidence: null,
      },
      {
        check_code: "H",
        check_name: "Migration and source-of-truth parity",
        result: "NO VERIFICADO",
        confidence: "NO APLICA",
        evidence: {
          staging_migration_catalog: "NOT_ACCESSIBLE_TO_GUARDIAN_MCP_READER",
          github_parity: "NOT_AVAILABLE_IN_SUPABASE_GUARDIAN_MCP",
        },
        canonical_expected: "STAGING migration is present and canonical GitHub migration matches byte-for-byte.",
        risk: "Source-of-truth parity requires separate read-only migration/GitHub evidence.",
        missing_evidence: "Read-only STAGING migration status plus separate read-only GitHub migration parity.",
      },
      {
        check_code: "I",
        check_name: "No test residue",
        result: "NO VERIFICADO",
        confidence: "NO APLICA",
        evidence: {
          direct_business_table_reads: "DENIED_TO_GUARDIAN_MCP_READER",
        },
        canonical_expected: "Rollback-only verification leaves no test checkout/payment/profile-context residue.",
        risk: "No direct business-table access is intentionally granted to the Guardian MCP reader.",
        missing_evidence: "Purpose-built aggregate no-test-residue audit surface.",
      },
      {
        check_code: "J",
        check_name: "Security surface after hardening",
        result: "NO VERIFICADO",
        confidence: "NO APLICA",
        evidence: {
          anon_security_definer_executable_count: Number(a.anon_sd_exec_count ?? 0),
          authenticated_security_definer_executable_count: Number(a.auth_sd_exec_count ?? 0),
          supabase_management_security_advisor: "NOT_AVAILABLE_IN_DB_ONLY_MCP",
        },
        canonical_expected: "Review user-executable SECURITY DEFINER exposure and Supabase security-advisor findings after hardening.",
        risk: "Database catalog counts are visible, but management security-advisor findings are not.",
        missing_evidence: "Allowlisted read-only Supabase management security-advisor summary.",
      },
    ];
  });
}


async function handleRpc(msg: any): Promise<any | null> {
  const id = Object.prototype.hasOwnProperty.call(msg ?? {}, "id") ? msg.id : undefined;
  const method = msg?.method;
  const isNotification = id === undefined;

  if (method === "notifications/initialized") return null;

  if (method === "initialize") {
    return {
      jsonrpc: "2.0",
      id,
      result: {
        protocolVersion: msg?.params?.protocolVersion ?? "2025-06-18",
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: "tu-comunidad-guardian-supabase", version: "1.1.0" },
      },
    };
  }

  if (method === "ping") {
    return { jsonrpc: "2.0", id, result: {} };
  }

  if (method === "tools/list") {
    return {
      jsonrpc: "2.0",
      id,
      result: {
        tools: [
          {
            name: "guardian_affiliation_integrity_v1",
            description: "READ ONLY. Returns only aggregated affiliation integrity anomaly counts from TU COMUNIDAD staging. No person IDs, private data, notes, coordinates, payloads, or arbitrary SQL.",
            inputSchema: { type: "object", properties: {}, additionalProperties: false },
          },
          {
            name: "guardian_checkout_requirements_gate_v1",
            description: "READ ONLY. Audits checkout requirements gate A-J using hard-coded catalog introspection under guardian_mcp_reader. Returns no PII and exposes no arbitrary SQL. A-G are directly auditable; H/I/J explicitly report missing evidence where the boundary does not expose it.",
            inputSchema: { type: "object", properties: {}, additionalProperties: false },
          },
        ],
      },
    };
  }

  if (method === "tools/call") {
    const name = msg?.params?.name;
    const args = msg?.params?.arguments ?? {};
    if (!["guardian_affiliation_integrity_v1", "guardian_checkout_requirements_gate_v1"].includes(name)) {
      return {
        jsonrpc: "2.0",
        id,
        result: {
          content: [{ type: "text", text: "Tool not allowlisted." }],
          isError: true,
        },
      };
    }
    if (args && typeof args === "object" && Object.keys(args).length > 0) {
      return {
        jsonrpc: "2.0",
        id,
        result: {
          content: [{ type: "text", text: "This tool accepts no arguments." }],
          isError: true,
        },
      };
    }
    try {
      const rows = name === "guardian_affiliation_integrity_v1"
        ? await runAffiliationIntegrity()
        : await runCheckoutRequirementsGate();
      return {
        jsonrpc: "2.0",
        id,
        result: {
          content: [{ type: "text", text: JSON.stringify(rows) }],
          isError: false,
        },
      };
    } catch (_err) {
      return {
        jsonrpc: "2.0",
        id,
        result: {
          content: [{ type: "text", text: "Guardian audit query failed." }],
          isError: true,
        },
      };
    }
  }

  if (isNotification) return null;
  return {
    jsonrpc: "2.0",
    id,
    error: { code: -32601, message: "Method not found" },
  };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  if (!(await authenticate(req))) {
    return json({ error: "unauthorized" }, 401);
  }

  if (req.method === "GET") {
    return new Response(null, { status: 405, headers: { ...corsHeaders, Allow: "POST, DELETE, OPTIONS" } });
  }

  if (req.method === "DELETE") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  let body: any;
  try {
    body = await req.json();
  } catch (_err) {
    return json({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } }, 400);
  }

  if (Array.isArray(body)) {
    const results = (await Promise.all(body.map(handleRpc))).filter((x) => x !== null);
    if (results.length === 0) return new Response(null, { status: 202, headers: corsHeaders });
    return json(results);
  }

  const result = await handleRpc(body);
  if (result === null) return new Response(null, { status: 202, headers: corsHeaders });
  return json(result);
});

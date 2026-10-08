import { createClient } from "npm:@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const wimoveisSecret = Deno.env.get("ZAP_VRSYNC_SECRET_KEY")?.trim();
const dfimoveisSecret = Deno.env.get("DFIMOVEIS_VRSYNC_SECRET_KEY")?.trim();
const supabase = createClient(supabaseUrl, serviceRoleKey);

type ZapLeadPayload = {
  leadOrigin?: unknown;
  timestamp?: unknown;
  originLeadId?: unknown;
  originListingId?: unknown;
  clientListingId?: unknown;
  name?: unknown;
  email?: unknown;
  ddd?: unknown;
  phone?: unknown;
  phoneNumber?: unknown;
  message?: unknown;
  temperature?: unknown;
  transactionType?: unknown;
  extraData?: unknown;
};

function text(value: unknown, maxLength: number) {
  return typeof value === "string" ? value.trim().slice(0, maxLength) : "";
}

function basicCredentials(request: Request) {
  const authorization = request.headers.get("authorization") ?? "";
  const match = authorization.match(/^Basic\s+(.+)$/i);
  if (!match) return { username: "", password: "" };
  try {
    const decoded = atob(match[1]).trim();
    const separator = decoded.indexOf(":");
    if (separator < 0) return { username: "", password: decoded };
    return {
      username: decoded.slice(0, separator).trim(),
      password: decoded.slice(separator + 1).trim(),
    };
  } catch {
    return { username: "", password: "" };
  }
}

function matchesSecret(candidate: string, expected: string | undefined) {
  return Boolean(candidate && expected && candidate === expected);
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const credentials = basicCredentials(request);
  const provider = matchesSecret(credentials.password, wimoveisSecret) || matchesSecret(credentials.username, wimoveisSecret)
    ? "wimoveis_vrsync"
    : matchesSecret(credentials.password, dfimoveisSecret) || matchesSecret(credentials.username, dfimoveisSecret)
    ? "dfimoveis_vrsync"
    : "";
  if (!provider) {
    console.warn("Unauthorized VRSYNC request", {
      hasUsername: Boolean(credentials.username),
      hasPassword: Boolean(credentials.password),
    });
    return new Response("Unauthorized", { status: 401 });
  }

  // Mantemos o portal tecnicamente conectado, porém nenhum lead é criado até o
  // administrador liberar a integração no CRM. O 204 evita novas tentativas do portal.
  const { data: integration, error: integrationError } = await supabase
    .from("crm_portal_lead_integrations")
    .select("enabled")
    .eq("provider", provider)
    .maybeSingle();
  if (integrationError) {
    console.error("Could not read portal integration status", integrationError);
    return new Response("Integration configuration unavailable", { status: 503 });
  }
  if (!integration?.enabled) return new Response(null, { status: 204 });

  let payload: ZapLeadPayload;
  try {
    payload = await request.json();
  } catch {
    return Response.json({ error: "JSON inválido." }, { status: 400 });
  }

  const phone = text(payload.phoneNumber, 32) ||
    text(payload.ddd, 4) + text(payload.phone, 24);
  // O campo originListingId identifica o anúncio no portal. É esse código que
  // o admin informa no cadastro do imóvel; clientListingId fica como fallback.
  const listingId = text(payload.originListingId, 160) || text(payload.clientListingId, 160);
  const { data, error } = await supabase.rpc(provider === "dfimoveis_vrsync" ? "create_dfimoveis_vrsync_lead" : "create_zap_vrsync_lead", {
    p_origin_lead_id: text(payload.originLeadId, 160),
    p_client_listing_id: listingId,
    p_name: text(payload.name, 160),
    p_phone: phone,
    p_email: text(payload.email, 160),
    p_message: text(payload.message, 4000),
    p_transaction_type: text(payload.transactionType, 16),
    p_lead_origin: text(payload.leadOrigin, 32),
    p_payload: payload,
  });

  if (error) {
    console.error("Could not create VRSYNC lead", {
      provider,
      originListingId: text(payload.originListingId, 160),
      clientListingId: text(payload.clientListingId, 160),
      error: error.message,
    });
    return Response.json({ error: error.message }, { status: 422 });
  }
  const lead = Array.isArray(data) ? data[0] : data;
  return Response.json({ leadId: lead?.lead_id, duplicate: Boolean(lead?.duplicate) }, { status: 201 });
});

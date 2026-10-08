import { createClient } from "npm:@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false },
});

const allowedOrigins = new Set([
  "https://sonialima-imoveis.pages.dev",
  "https://contatosonialima.netlify.app",
  "https://contato.crmsonialimaimoveis.online",
  "http://localhost:5500",
  "http://127.0.0.1:5500",
]);

const allowedKeys = new Set([
  "contractVersion",
  "name",
  "phone",
  "email",
  "interestType",
  "interest",
  "routingMode",
  "assignedOwner",
  "source",
  "pageUrl",
  "website",
]);

function corsHeaders(origin: string | null) {
  const headers: Record<string, string> = {
    "Access-Control-Allow-Headers": "content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    Vary: "Origin",
  };
  if (origin && allowedOrigins.has(origin)) headers["Access-Control-Allow-Origin"] = origin;
  return headers;
}

function json(origin: string | null, status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(origin), "Content-Type": "application/json; charset=utf-8" },
  });
}

function plainText(value: unknown, field: string, maxLength: number, required = true) {
  if (typeof value !== "string") {
    if (!required && (value === null || value === undefined)) return "";
    throw new Error(`${field}:type`);
  }
  const normalized = value.trim();
  if (
    (required && !normalized) ||
    normalized.length > maxLength ||
    /[\u0000-\u001f\u007f]/u.test(normalized)
  ) {
    throw new Error(`${field}:format`);
  }
  return normalized;
}

function validEmail(value: string) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(value);
}

function validPageUrl(value: string) {
  try {
    const url = new URL(value);
    return (
      allowedOrigins.has(url.origin) &&
      (url.protocol === "https:" || url.hostname === "localhost" || url.hostname === "127.0.0.1")
    );
  } catch {
    return false;
  }
}

async function sha256(value: string) {
  const data = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

// A repeated phone must still leave an auditable event on the existing lead
// and notify administrators. The RPC remains service-role-only.
async function recordDuplicateSiteRegistration(input: {
  name: string;
  phone: string;
  interest: string;
  source: string;
  pageUrl: string;
}) {
  const { error } = await supabase.rpc("record_public_site_duplicate_lead_attempt", {
    p_name: input.name,
    p_phone: input.phone,
    p_interest: input.interest,
    p_source: input.source,
    p_page_url: input.pageUrl,
  });
  if (error) console.error("duplicate site lead audit error", error);
}

Deno.serve(async (request) => {
  const origin = request.headers.get("origin");
  if (request.method === "OPTIONS") {
    if (origin && !allowedOrigins.has(origin))
      return json(origin, 403, { error: "Origem não autorizada." });
    return new Response(null, { status: 204, headers: corsHeaders(origin) });
  }
  if (request.method !== "POST") return json(origin, 405, { error: "Método não permitido." });
  if (origin && !allowedOrigins.has(origin))
    return json(origin, 403, { error: "Origem não autorizada." });

  try {
    const contentType = request.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase();
    if (contentType !== "application/json")
      return json(origin, 400, { error: "Envie os dados em formato JSON." });

    const contentLength = Number(request.headers.get("content-length") || "0");
    if (!Number.isFinite(contentLength) || contentLength > 10_000)
      return json(origin, 413, { error: "Dados enviados são muito grandes." });

    const parsed: unknown = await request.json();
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed))
      return json(origin, 400, { error: "Dados enviados são inválidos." });
    const body = parsed as Record<string, unknown>;
    if (Object.keys(body).some((key) => !allowedKeys.has(key)))
      return json(origin, 400, { error: "O formulário contém campos não permitidos." });

    if (typeof body.website !== "string" || body.website.length > 200)
      return json(origin, 400, { error: "Dados enviados são inválidos." });
    if (body.website.trim()) return json(origin, 200, { ok: true });

    const contractVersion = plainText(body.contractVersion, "contractVersion", 10);
    const name = plainText(body.name, "name", 120);
    const phone = plainText(body.phone, "phone", 32);
    const email = plainText(body.email, "email", 254, false).toLowerCase();
    const interestType = plainText(body.interestType, "interestType", 10);
    const interest = plainText(body.interest, "interest", 160);
    const routingMode = plainText(body.routingMode, "routingMode", 20);
    const source = plainText(body.source, "source", 60);
    const pageUrl = plainText(body.pageUrl, "pageUrl", 500);
    const assignedOwner = body.assignedOwner;
    const digits = phone.replace(/\D/g, "").replace(/^55(?=\d{10,11}$)/, "");

    if (contractVersion !== "1.0")
      return json(origin, 400, { error: "Versão do formulário não suportada." });
    if (name.length < 2) return json(origin, 400, { error: "Informe seu nome completo." });
    if (![10, 11].includes(digits.length))
      return json(origin, 400, { error: "Informe um telefone válido com DDD." });
    if (email && !validEmail(email))
      return json(origin, 400, { error: "Informe um e-mail válido." });
    if (!(["Venda", "Aluguel"] as string[]).includes(interestType))
      return json(origin, 400, { error: "Selecione interesse em venda ou aluguel." });
    if (!(["fixed_owner", "round_robin"] as string[]).includes(routingMode))
      return json(origin, 400, { error: "Roteamento inválido." });
    if (source !== "site_sonialima_imoveis")
      return json(origin, 400, { error: "Origem do formulário inválida." });
    if (!validPageUrl(pageUrl)) return json(origin, 400, { error: "Página de origem inválida." });
    if (assignedOwner !== null && assignedOwner !== "crmvitor")
      return json(origin, 400, { error: "Responsável solicitado não é permitido." });

    const isFinancing = interest === "Financiamento Caixa";
    const validFixedRoute =
      isFinancing && routingMode === "fixed_owner" && assignedOwner === "crmvitor";
    const validRoundRobin = !isFinancing && routingMode === "round_robin" && assignedOwner === null;
    if (!validFixedRoute && !validRoundRobin)
      return json(origin, 400, { error: "Combinação de interesse e roteamento inválida." });

    const forwarded = request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() || "unknown";
    const agent = request.headers.get("user-agent") || "unknown";
    const fingerprint = await sha256(`${forwarded}|${agent}|sonialima-site-v1`);

    const { data, error } = await supabase.rpc("create_public_bio_lead", {
      p_assigned_owner: assignedOwner,
      p_contract_version: contractVersion,
      p_email: email || null,
      p_lead_type: interestType,
      p_name: name,
      p_page_url: pageUrl,
      p_phone: digits,
      p_property_interest: interest,
      p_request_fingerprint: fingerprint,
      p_routing_mode: routingMode,
      p_source: source,
    });

    if (error) {
      const duplicate =
        error.message.includes("telefone já possui") ||
        error.message.includes("telefone ja possui");
      const limited = error.message.includes("Muitas tentativas");
      const invalid =
        error.message.includes("inválid") ||
        error.message.includes("inval") ||
        error.message.includes("não permitido");
      const safeMessage = duplicate
        ? "Este telefone já possui atendimento cadastrado. Nossa equipe entrará em contato."
        : limited
          ? "Muitas tentativas. Aguarde uma hora e tente novamente."
          : invalid
            ? "Os dados do formulário são inválidos."
            : "Não foi possível enviar agora. Tente novamente em alguns instantes.";
      if (duplicate) {
        await recordDuplicateSiteRegistration({
          name,
          phone: digits,
          interest,
          source,
          pageUrl,
        });
      }
      if (!duplicate && !limited && !invalid) console.error("bio-lead-intake RPC error", error);
      return json(origin, duplicate ? 409 : limited ? 429 : invalid ? 400 : 500, {
        error: safeMessage,
      });
    }

    return json(origin, 201, { ok: true, leadId: data });
  } catch (error) {
    if (error instanceof Error && error.message.includes(":"))
      return json(origin, 400, { error: "Dados enviados são inválidos." });
    return json(origin, 400, { error: "Não foi possível ler os dados enviados." });
  }
});

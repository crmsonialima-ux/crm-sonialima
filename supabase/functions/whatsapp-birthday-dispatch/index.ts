import { createClient } from "npm:@supabase/supabase-js@2";

const GRAPH_VERSION = "v25.0";

type Dispatch = {
  dispatch_id: string;
  sale_id: string;
  recipient_name: string;
  recipient_phone: string;
  birthday_year: number;
};

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim() ?? "";
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
}

function normalizedInternationalPhone(value: unknown): string {
  const digits = typeof value === "string" ? value.replace(/\D/g, "") : "";
  return /^55[1-9]\d{10,11}$/.test(digits) ? digits : "";
}

function firstName(name: string): string {
  return name.trim().split(/\s+/)[0]?.slice(0, 80) || "cliente";
}

function client() {
  return createClient(requiredEnv("SUPABASE_URL"), requiredEnv("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

function authorized(request: Request): boolean {
  const expected = requiredEnv("WHATSAPP_BIRTHDAY_CRON_SECRET");
  return request.headers.get("x-crm-scheduler-secret") === expected;
}

function metaConfig() {
  return {
    accessToken: requiredEnv("WHATSAPP_ACCESS_TOKEN"),
    phoneNumberId: requiredEnv("WHATSAPP_PHONE_NUMBER_ID"),
    businessAccountId: requiredEnv("WHATSAPP_BUSINESS_ACCOUNT_ID"),
    templateName: requiredEnv("WHATSAPP_TEMPLATE_NAME"),
    language: requiredEnv("WHATSAPP_TEMPLATE_LANGUAGE"),
  };
}

async function metaPhoneValidation() {
  const config = metaConfig();
  const response = await fetch(
    `https://graph.facebook.com/${GRAPH_VERSION}/${encodeURIComponent(config.phoneNumberId)}?fields=id,display_phone_number,verified_name,quality_rating`,
    { headers: { authorization: `Bearer ${config.accessToken}` } },
  );
  const body = await response.json().catch(() => ({}));
  return { ok: response.ok, status: response.status, body };
}

async function metaTemplateValidation() {
  const config = metaConfig();
  const response = await fetch(
    `https://graph.facebook.com/${GRAPH_VERSION}/${encodeURIComponent(config.businessAccountId)}/message_templates?name=${encodeURIComponent(config.templateName)}&fields=name,status,language`,
    { headers: { authorization: `Bearer ${config.accessToken}` } },
  );
  const body = await response.json().catch(() => ({}));
  const templates = typeof body === "object" && body !== null
    ? (body as { data?: Array<{ name?: string; status?: string; language?: string }> }).data ?? []
    : [];
  return {
    ok: response.ok && templates.some((template) =>
      template.name === config.templateName && template.status === "APPROVED" && template.language === config.language,
    ),
    status: response.status,
  };
}
async function sendTemplate(dispatch: Dispatch) {
  const config = metaConfig();
  const response = await fetch(
    `https://graph.facebook.com/${GRAPH_VERSION}/${encodeURIComponent(config.phoneNumberId)}/messages`,
    {
      method: "POST",
      headers: {
        authorization: `Bearer ${config.accessToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        messaging_product: "whatsapp",
        to: dispatch.recipient_phone,
        type: "template",
        template: {
          name: config.templateName,
          language: { code: config.language },
          components: [{ type: "body", parameters: [{ type: "text", text: firstName(dispatch.recipient_name) }] }],
        },
      }),
    },
  );
  const body = await response.json().catch(() => ({}));
  return { ok: response.ok, status: response.status, body };
}

function safeMetaStatus(response: { status: number; body: unknown }) {
  return { http_status: response.status, response: response.body };
}

Deno.serve(async (request) => {
  try {
    if (request.method !== "POST") return new Response("Method not allowed", { status: 405 });
    if (!authorized(request)) return new Response("Unauthorized", { status: 401 });

    const action = new URL(request.url).searchParams.get("action") ?? "dispatch";
    if (action === "validate") {
      const result = await metaPhoneValidation();
      const template = await metaTemplateValidation();
      const configured = result.ok && template.ok;
      return Response.json({ configured, phoneHttpStatus: result.status, templateHttpStatus: template.status, templateApproved: template.ok }, { status: configured ? 200 : 502 });
    }
    const template = await metaTemplateValidation();
    if (!template.ok) return Response.json({ error: "Birthday template is not approved." }, { status: 503 });
    if (action === "test") {
      const payload = await request.json().catch(() => null) as { phone?: unknown; firstName?: unknown } | null;
      const phone = normalizedInternationalPhone(payload?.phone);
      const name = typeof payload?.firstName === "string" ? firstName(payload.firstName) : "";
      if (!phone || !name) return Response.json({ error: "Invalid test recipient." }, { status: 400 });
      const result = await sendTemplate({
        dispatch_id: "manual-test",
        sale_id: "manual-test",
        recipient_name: name,
        recipient_phone: phone,
        birthday_year: new Date().getFullYear(),
      });
      const metaMessageId = result.ok && typeof result.body === "object" && result.body !== null
        ? (result.body as { messages?: Array<{ id?: string }> }).messages?.[0]?.id ?? null
        : null;
      const { error: logError } = await client()
        .from("crm_whatsapp_birthday_manual_tests")
        .insert({
          recipient_name: name,
          recipient_phone: phone,
          birthday_year: new Date().getFullYear(),
          status: result.ok ? "sent" : "failed",
          meta_message_id: metaMessageId,
          meta_status: safeMetaStatus(result),
          attempted_at: new Date().toISOString(),
          sent_at: result.ok ? new Date().toISOString() : null,
        });
      if (logError) throw new Error("Could not record manual birthday test result.");
      return Response.json({ sent: result.ok, httpStatus: result.status }, { status: result.ok ? 200 : 502 });
    }
    if (action !== "dispatch") return Response.json({ error: "Invalid action" }, { status: 400 });
    if (Deno.env.get("WHATSAPP_BIRTHDAY_AUTOMATION_ENABLED") !== "true") {
      return Response.json({ error: "Birthday automation is disabled." }, { status: 503 });
    }

    const { data, error } = await client().rpc("claim_crm_birthday_dispatches");
    if (error) throw new Error("Could not claim birthday dispatches.");
    const dispatches = (data ?? []) as Dispatch[];
    let sent = 0;
    let failed = 0;
    for (const dispatch of dispatches) {
      const result = await sendTemplate(dispatch);
      const metaMessageId = result.ok && typeof result.body === "object" && result.body !== null
        ? (result.body as { messages?: Array<{ id?: string }> }).messages?.[0]?.id ?? null
        : null;
      const { error: recordError } = await client().rpc("record_crm_birthday_dispatch", {
        p_dispatch_id: dispatch.dispatch_id,
        p_status: result.ok ? "sent" : "failed",
        p_meta_message_id: metaMessageId,
        p_meta_status: safeMetaStatus(result),
      });
      if (recordError) throw new Error("Could not record birthday dispatch result.");
      if (result.ok) sent += 1; else failed += 1;
    }
    return Response.json({ processed: dispatches.length, sent, failed });
  } catch (error) {
    console.error("WhatsApp birthday dispatch failed.", error instanceof Error ? error.message : "unknown error");
    return Response.json({ error: "Birthday dispatch unavailable." }, { status: 500 });
  }
});




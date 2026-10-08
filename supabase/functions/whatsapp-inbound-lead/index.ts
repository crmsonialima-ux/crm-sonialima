import { createClient } from "npm:@supabase/supabase-js@2";
import { extractInboundWhatsAppMessages, type InboundWhatsAppMessage, isRecord } from "./parser.ts";
import { validateMetaSignature } from "./webhook-security.ts";

const MAX_WEBHOOK_BYTES = 1_048_576;
const DEFAULT_RPC_NAME = "process_whatsapp_inbound_message";

type ProcessedResult = {
  messageId: string;
  status: string;
  leadId?: string;
  duplicate?: boolean;
};

function env(name: string): string {
  return Deno.env.get(name)?.trim() ?? "";
}

function plainText(body: string, status: number): Response {
  return new Response(body, {
    status,
    headers: { "content-type": "text/plain; charset=utf-8" },
  });
}

function webhookVerification(request: Request): Response {
  const url = new URL(request.url);
  const mode = url.searchParams.get("hub.mode") ?? "";
  const verifyToken = url.searchParams.get("hub.verify_token") ?? "";
  const challenge = url.searchParams.get("hub.challenge") ?? "";
  const expectedToken = env("WHATSAPP_WEBHOOK_VERIFY_TOKEN");

  if (!expectedToken) {
    console.error("WhatsApp webhook verify token is not configured.");
    return plainText("Webhook verification is not configured", 500);
  }
  if (mode !== "subscribe" || !challenge || verifyToken !== expectedToken) {
    return plainText("Forbidden", 403);
  }
  return plainText(challenge, 200);
}

function supabaseClient() {
  const url = env("SUPABASE_URL");
  const serviceRoleKey = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceRoleKey) {
    throw new Error("Supabase server credentials are not configured.");
  }
  return createClient(url, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

function rpcResult(data: unknown, messageId: string): ProcessedResult {
  const row = Array.isArray(data) ? data[0] : data;
  if (!isRecord(row)) return { messageId, status: "processed" };
  return {
    messageId,
    status: typeof row.status === "string" ? row.status : "processed",
    leadId:
      typeof row.lead_id === "string"
        ? row.lead_id
        : typeof row.leadId === "string"
          ? row.leadId
          : undefined,
    duplicate: typeof row.duplicate === "boolean" ? row.duplicate : undefined,
  };
}

async function processMessage(message: InboundWhatsAppMessage): Promise<ProcessedResult> {
  const rpcName = env("WHATSAPP_INBOUND_RPC") || DEFAULT_RPC_NAME;
  const reference = message.portalReference;
  const { data, error } = await supabaseClient().rpc(rpcName, {
    p_message_id: message.messageId,
    p_phone: message.phone,
    p_contact_name: message.contactName,
    p_message_text: message.text,
    p_received_at: message.receivedAt,
    p_portal: reference?.portal ?? null,
    p_external_code: reference?.externalCode ?? null,
    p_phone_number_id: message.phoneNumberId || null,
    p_parse_status: message.parseStatus,
    p_parse_reason: message.parseReason,
    p_payload: message.rawPayload,
  });
  if (error) {
    console.error("WhatsApp inbound message RPC failed.", {
      messageId: message.messageId,
      portal: reference?.portal ?? null,
      externalCode: reference?.externalCode ?? null,
      code: error.code,
    });
    throw new Error("Inbound message processing failed.");
  }
  return rpcResult(data, message.messageId);
}

async function receiveWebhook(request: Request): Promise<Response> {
  const appSecret = env("WHATSAPP_APP_SECRET");
  if (!appSecret) {
    console.error("WhatsApp app secret is not configured.");
    return Response.json({ error: "Webhook authentication is not configured." }, { status: 500 });
  }

  const body = await request.arrayBuffer();
  if (body.byteLength > MAX_WEBHOOK_BYTES) {
    return Response.json({ error: "Payload too large." }, { status: 413 });
  }
  const validSignature = await validateMetaSignature(
    appSecret,
    body,
    request.headers.get("x-hub-signature-256"),
  );
  if (!validSignature) {
    return Response.json({ error: "Invalid signature." }, { status: 401 });
  }

  let payload: unknown;
  try {
    payload = JSON.parse(new TextDecoder().decode(body));
  } catch {
    return Response.json({ error: "Invalid JSON." }, { status: 400 });
  }
  if (!isRecord(payload) || payload.object !== "whatsapp_business_account") {
    return Response.json(
      { error: "Invalid WhatsApp webhook payload." },
      {
        status: 400,
      },
    );
  }

  const messages = extractInboundWhatsAppMessages(payload, env("WHATSAPP_PHONE_NUMBER_ID"));
  const results: ProcessedResult[] = [];
  try {
    // Sequential processing keeps logs deterministic. Database-side idempotency
    // and locking remain the authority for retries and concurrent invocations.
    for (const message of messages) results.push(await processMessage(message));
  } catch {
    // Meta will retry. Already processed message IDs must be idempotent in the RPC.
    return Response.json(
      { error: "Webhook processing failed." },
      {
        status: 500,
      },
    );
  }

  console.info("WhatsApp webhook processed.", {
    inboundTextMessages: messages.length,
    propertyReferences: messages.filter((message) => message.portalReference).length,
  });
  return Response.json({ received: true, processed: results.length, results });
}

export async function handler(request: Request): Promise<Response> {
  if (request.method === "GET") return webhookVerification(request);
  if (request.method === "POST") return receiveWebhook(request);
  return new Response("Method not allowed", {
    status: 405,
    headers: { allow: "GET, POST" },
  });
}

if (import.meta.main) Deno.serve(handler);

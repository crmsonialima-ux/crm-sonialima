import { createClient } from "npm:@supabase/supabase-js@2";

const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const expectedSecret = Deno.env.get("DFIMOVEIS_VRSYNC_SECRET_KEY");

type LeadPayload = { originLeadId?: unknown; clientListingId?: unknown; name?: unknown; email?: unknown; ddd?: unknown; phone?: unknown; phoneNumber?: unknown; message?: unknown; transactionType?: unknown; leadOrigin?: unknown; [key: string]: unknown };
const text = (value: unknown, max: number) => typeof value === "string" ? value.trim().slice(0, max) : "";
function basicSecret(request: Request) { const value = request.headers.get("authorization") ?? ""; try { return value.startsWith("Basic ") ? atob(value.slice(6)).split(":").slice(1).join(":") : ""; } catch { return ""; } }

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response("Method not allowed", { status: 405 });
  if (!expectedSecret) return new Response("VRSYNC secret is not configured", { status: 500 });
  if (basicSecret(request) !== expectedSecret) return new Response("Unauthorized", { status: 401 });
  const { data: integration, error: integrationError } = await supabase.from("crm_portal_lead_integrations").select("enabled").eq("provider", "dfimoveis_vrsync").maybeSingle();
  if (integrationError) return new Response("Integration configuration unavailable", { status: 503 });
  if (!integration?.enabled) return new Response(null, { status: 204 });

  let payload: LeadPayload;
  try { payload = await request.json(); } catch { return Response.json({ error: "JSON inválido." }, { status: 400 }); }
  const phone = text(payload.phoneNumber, 32) || text(payload.ddd, 4) + text(payload.phone, 24);
  const { data, error } = await supabase.rpc("create_dfimoveis_vrsync_lead", {
    p_origin_lead_id: text(payload.originLeadId, 160), p_client_listing_id: text(payload.clientListingId, 160),
    p_name: text(payload.name, 160), p_phone: phone, p_email: text(payload.email, 160),
    p_message: text(payload.message, 4000), p_transaction_type: text(payload.transactionType, 16),
    p_lead_origin: text(payload.leadOrigin, 32), p_payload: payload,
  });
  if (error) return Response.json({ error: error.message }, { status: 422 });
  const lead = Array.isArray(data) ? data[0] : data;
  return Response.json({ leadId: lead?.lead_id, duplicate: Boolean(lead?.duplicate) }, { status: 201 });
});

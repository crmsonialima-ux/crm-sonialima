import { createClient } from "npm:@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const integrationKey = Deno.env.get("WIMOVEIS_INTEGRATION_KEY");
const supabase = createClient(supabaseUrl, serviceRoleKey);

type LeadPayload = {
  name?: unknown;
  phone?: unknown;
  email?: unknown;
  propertyId?: unknown;
  message?: unknown;
};

function text(value: unknown, maxLength: number) {
  return typeof value === "string" ? value.trim().slice(0, maxLength) : "";
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response("Method not allowed", { status: 405 });
  if (!integrationKey || request.headers.get("x-wimoveis-integration-key") !== integrationKey) {
    return new Response("Unauthorized", { status: 401 });
  }

  let payload: LeadPayload;
  try {
    payload = await request.json();
  } catch {
    return Response.json({ error: "JSON inválido." }, { status: 400 });
  }

  const { data, error } = await supabase.rpc("create_wimoveis_whatsapp_lead", {
    p_name: text(payload.name, 120),
    p_phone: text(payload.phone, 32),
    p_email: text(payload.email, 160),
    p_property_external_id: text(payload.propertyId, 120),
    p_message: text(payload.message, 2000),
  });
  if (error) return Response.json({ error: error.message }, { status: 422 });

  const lead = Array.isArray(data) ? data[0] : data;
  if (!lead?.lead_id || !lead.assigned_owner_whatsapp) {
    return Response.json({ error: "A fila não retornou um corretor configurado." }, { status: 500 });
  }

  const brokerName = String(lead.assigned_owner_name ?? "corretor");
  const propertyTitle = String(lead.property_title ?? "o imóvel");
  const message = `Olá, ${brokerName}! Tenho interesse em ${propertyTitle}.`;
  const whatsappUrl = `https://wa.me/${lead.assigned_owner_whatsapp}?text=${encodeURIComponent(message)}`;

  return Response.json({ leadId: lead.lead_id, whatsappUrl });
});

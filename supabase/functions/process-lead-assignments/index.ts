import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";
import { displayText } from "../_shared/display-text.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const vapidPublicKey = Deno.env.get("VAPID_PUBLIC_KEY");
const vapidPrivateKey = Deno.env.get("VAPID_PRIVATE_KEY");
const vapidSubject = Deno.env.get("VAPID_SUBJECT") || "mailto:unassigned-contact@example.invalid";
const appsScriptUrl = Deno.env.get("GOOGLE_APPS_SCRIPT_API_URL");
const cronTriggerSecret = Deno.env.get("CRM_CRON_TRIGGER_SECRET");

const pushConfigured = Boolean(vapidPublicKey && vapidPrivateKey);
if (pushConfigured) {
  webpush.setVapidDetails(vapidSubject, vapidPublicKey!, vapidPrivateKey!);
}
const supabase = createClient(url, serviceRoleKey);

function normalizedKey(value: string) {
  return value
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]/g, "");
}

function field(record: Record<string, unknown>, aliases: string[]) {
  const entries = Object.entries(record).map(
    ([key, value]) => [normalizedKey(key), value] as const,
  );
  for (const alias of aliases) {
    const matched = entries.find(([key]) => key === normalizedKey(alias));
    if (matched?.[1] !== undefined && matched[1] !== null && String(matched[1]).trim() !== "") {
      return matched[1];
    }
  }
  return undefined;
}

function amount(value: unknown) {
  if (typeof value === "number") return value;
  const source = String(value ?? "").trim();
  if (!source) return undefined;
  const normalized = source.includes(",")
    ? source.replace(/\./g, "").replace(",", ".")
    : source.replace(/[^\d.-]/g, "");
  const parsed = Number(normalized);
  return Number.isFinite(parsed) ? parsed : undefined;
}

async function syncPropertiesFromSpreadsheet() {
  if (!appsScriptUrl) return { synced: 0, skipped: true };
  const endpoint = new URL(appsScriptUrl);
  endpoint.searchParams.set("action", "listImoveis");
  endpoint.searchParams.set("_", String(Date.now()));
  const response = await fetch(endpoint, { redirect: "follow", cache: "no-store" });
  if (!response.ok) throw new Error(`Planilha respondeu ${response.status}.`);
  const payload = (await response.json()) as {
    success?: boolean;
    message?: string;
    data?: Record<string, unknown>[];
  };
  if (!payload.success || !Array.isArray(payload.data)) {
    throw new Error(payload.message || "Não foi possível ler IMÓVEIS V3.");
  }
  const properties = payload.data.map((record) => ({
    id: String(record._id ?? field(record, ["Código", "Codigo"]) ?? ""),
    code: String(field(record, ["Código", "Codigo"]) ?? ""),
    title: String(
      field(record, ["Título", "Titulo", "Endereço/identificação", "Endereco/identificacao"]) ??
        "Imóvel sem título",
    ),
    address: String(
      field(record, ["Endereço/identificação", "Endereco/identificacao", "Endereço", "Endereco"]) ??
        "",
    ),
    neighborhood: String(field(record, ["Bairro"]) ?? ""),
    city: String(field(record, ["Cidade"]) ?? ""),
    purpose: String(field(record, ["Finalidade"]) ?? ""),
    brokerName: String(field(record, ["Corretor responsável", "Corretor responsavel"]) ?? ""),
    value: amount(
      field(record, ["Valor de venda", "Valor de locação", "Valor de locacao", "Valor"]),
    ),
  }));
  const { data, error } = await supabase.rpc("sync_property_catalog", { p_properties: properties });
  if (error) throw new Error(error.message);
  const { error: responsibilityError } = await supabase.rpc(
    "sync_property_document_responsibilities",
    {
      p_properties: properties.map((property) => ({
        external_id: property.id,
        title: property.title,
        broker_name: property.brokerName,
      })),
    },
  );
  if (responsibilityError) throw new Error(responsibilityError.message);
  return { synced: Number(data ?? 0), skipped: false };
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error ?? "Erro desconhecido.");
}

async function recordSystemError(
  area: string,
  operation: string,
  error: unknown,
  details: Record<string, unknown> = {},
  subjectUserId: string | null = null,
) {
  await supabase.rpc("record_crm_system_error", {
    p_subject_user_id: subjectUserId,
    p_area: area,
    p_operation: operation,
    p_message: errorMessage(error),
    p_details: details,
  });
}

async function recordDeliveryAttempt(
  notificationId: string,
  subscriptionId: string | null,
  status: "sent" | "failed" | "no_subscription" | "invalid_subscription",
  options: {
    httpStatus?: number;
    errorCode?: string;
    error?: unknown;
    details?: Record<string, unknown>;
  } = {},
) {
  const { error } = await supabase.rpc("record_notification_delivery_attempt", {
    p_notification_id: notificationId,
    p_subscription_id: subscriptionId,
    p_status: status,
    p_http_status: options.httpStatus ?? null,
    p_error_code: options.errorCode ?? null,
    p_error_message: options.error ? errorMessage(options.error) : null,
    p_details: options.details ?? {},
  });
  if (error) {
    await recordSystemError("notifications", "Registrar tentativa de entrega push", error, {
      notificationId,
      subscriptionId,
      status,
    });
  }
}

Deno.serve(async (request) => {
  const usesServiceRole = request.headers.get("Authorization") === `Bearer ${serviceRoleKey}`;
  const usesCronSecret = Boolean(
    cronTriggerSecret && request.headers.get("x-crm-cron-secret") === cronTriggerSecret,
  );
  if (!usesServiceRole && !usesCronSecret) {
    return new Response("Unauthorized", { status: 401 });
  }

  const processorErrors: Array<{ processor: string; message: string }> = [];
  const processors = [
    "process_expired_lead_assignments",
    "process_due_visit_notifications",
    "process_due_lead_reminders",
    "process_property_match_opportunities",
    "process_agenda_notifications",
    "process_agenda_cartorio_vitor_document_notifications",
    "process_assignment_notification_tests",
  ];
  for (const processor of processors) {
    const { error } = await supabase.rpc(processor);
    if (!error) continue;
    processorErrors.push({ processor, message: error.message });
    await recordSystemError("notification_processor", processor, error);
  }

  // Uma execucao interrompida nao pode deixar a notificacao presa para sempre.
  const staleProcessing = new Date(Date.now() - 10 * 60_000).toISOString();
  const { error: staleClaimError } = await supabase
    .from("crm_notification_outbox")
    .update({ delivery_status: "queued" })
    .is("dismissed_at", null)
    .eq("delivery_status", "processing")
    .lt("delivery_updated_at", staleProcessing);
  if (staleClaimError) {
    await recordSystemError(
      "notifications",
      "Liberar notificacoes presas em processamento",
      staleClaimError,
    );
  }

  const { data: isBusinessHours, error: businessHoursError } =
    await supabase.rpc("crm_is_business_hours");
  if (businessHoursError) {
    await recordSystemError(
      "notifications",
      "Verificar expediente antes da entrega push",
      businessHoursError,
    );
    return Response.json({ error: businessHoursError.message }, { status: 500 });
  }

  const { data: isLeadQueueHours, error: leadQueueHoursError } =
    await supabase.rpc("crm_is_lead_queue_hours");
  if (leadQueueHoursError) {
    await recordSystemError(
      "notifications",
      "Verificar horario da esteira antes da entrega push",
      leadQueueHoursError,
    );
    return Response.json({ error: leadQueueHoursError.message }, { status: 500 });
  }

  const retryBefore = new Date(Date.now() - 5 * 60_000).toISOString();
  let notificationQuery = supabase
    .from("crm_notification_outbox")
    .select(
      "id, recipient_id, kind, title, body, url, payload, created_at, available_at, delivery_status, last_delivery_attempt_at",
    )
    .is("delivered_at", null)
    .is("dismissed_at", null)
    .in("delivery_status", ["queued", "failed"])
    .lte("available_at", new Date().toISOString())
    .lt("delivery_attempt_count", 5)
    .or(`last_delivery_attempt_at.is.null,last_delivery_attempt_at.lt.${retryBefore}`)
    .order("available_at")
    .order("created_at")
    .limit(100);
  if (!isLeadQueueHours) {
    notificationQuery = notificationQuery.not(
      "kind",
      "in",
      '("lead_assignment","lead_assignment_expired","lead_unanswered")',
    );
  }
  const notificationResult = isBusinessHours ? await notificationQuery : { data: [], error: null };
  const { data: notifications, error: notificationError } = notificationResult;
  if (notificationError) {
    await recordSystemError("notifications", "Ler fila de entrega push", notificationError);
    return Response.json({ error: notificationError.message }, { status: 500 });
  }

  let claimedCount = 0;
  for (const notification of notifications ?? []) {
    const claimTime = new Date().toISOString();
    const { data: claimed, error: claimError } = await supabase
      .from("crm_notification_outbox")
      .update({ delivery_status: "processing", last_delivery_attempt_at: claimTime })
      .eq("id", notification.id)
      .eq("delivery_status", notification.delivery_status)
      .is("delivered_at", null)
      .is("dismissed_at", null)
      .select("id")
      .maybeSingle();
    if (claimError) {
      await recordSystemError(
        "notifications",
        "Reservar notificacao para entrega",
        claimError,
        { notificationId: notification.id },
        notification.recipient_id,
      );
      continue;
    }
    if (!claimed) continue;
    claimedCount += 1;

    if (!pushConfigured) {
      await recordDeliveryAttempt(notification.id, null, "failed", {
        errorCode: "push_not_configured",
        error: new Error("As chaves VAPID nao estao configuradas."),
      });
      continue;
    }

    const { data: subscriptions, error: subscriptionError } = await supabase
      .from("push_subscriptions")
      .select("id, endpoint, p256dh, auth")
      .eq("user_id", notification.recipient_id);
    if (subscriptionError) {
      await recordDeliveryAttempt(notification.id, null, "failed", {
        errorCode: "subscription_lookup_failed",
        error: subscriptionError,
      });
      continue;
    }
    if (!subscriptions?.length) {
      await recordDeliveryAttempt(notification.id, null, "no_subscription", {
        errorCode: "no_push_subscription",
        details: { reason: "O usuario nao habilitou notificacoes neste aparelho." },
      });
      continue;
    }

    const failures: Array<{
      subscriptionId: string;
      status: "failed" | "invalid_subscription";
      httpStatus?: number;
      error: unknown;
    }> = [];
    const successes: string[] = [];
    for (const subscription of subscriptions) {
      try {
        await webpush.sendNotification(
          {
            endpoint: subscription.endpoint,
            keys: { p256dh: subscription.p256dh, auth: subscription.auth },
          },
          JSON.stringify({
            ...notification.payload,
            kind: notification.kind,
            title: displayText(notification.title),
            body: displayText(notification.body),
            url: notification.url,
            tag: notification.id,
            notificationId: notification.id,
          }),
          {
            urgency: notification.kind === "lead_assignment" ? "high" : "normal",
          }
        );
        successes.push(subscription.id);
      } catch (error) {
        const statusCode = (error as { statusCode?: number }).statusCode;
        const invalid = statusCode === 404 || statusCode === 410;
        if (invalid) {
          await supabase.from("push_subscriptions").delete().eq("id", subscription.id);
        }
        failures.push({
          subscriptionId: subscription.id,
          status: invalid ? "invalid_subscription" : "failed",
          httpStatus: statusCode,
          error,
        });
      }
    }

    // Registra sucessos por ultimo: se ao menos um aparelho aceitou o push, o
    // estado final e "sent", sem esconder falhas dos demais aparelhos.
    for (const failure of failures) {
      await recordDeliveryAttempt(notification.id, failure.subscriptionId, failure.status, {
        httpStatus: failure.httpStatus,
        errorCode:
          failure.status === "invalid_subscription"
            ? "expired_push_subscription"
            : "push_provider_error",
        error: failure.error,
      });
    }
    for (const subscriptionId of successes) {
      await recordDeliveryAttempt(notification.id, subscriptionId, "sent", {
        details: { providerAccepted: true },
      });
    }
  }

  // Supabase é a fonte definitiva dos imóveis. A importação da planilha foi
  // desativada para que registros excluídos nunca sejam recriados pelo cron.
  const propertySync = { synced: 0, skipped: true };

  return Response.json(
    {
      ok: processorErrors.length === 0,
      processed: claimedCount,
      properties: propertySync,
      pushConfigured,
      businessHours: Boolean(isBusinessHours),
      processorErrors,
    },
    { status: processorErrors.length ? 500 : 200 },
  );
});

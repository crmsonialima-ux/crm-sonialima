import { supabase } from "@/lib/supabase";

type ClientErrorContext = {
  area?: string;
  operation?: string;
  details?: Record<string, unknown>;
};

type NotificationClientEvent =
  | "browser_presented"
  | "push_clicked"
  | "push_closed"
  | "inbox_presented"
  | "inbox_opened"
  | "notification_client_error";

type PendingClientError = {
  area: string;
  operation: string;
  message: string;
  details: Record<string, unknown>;
};

const PENDING_ERRORS_KEY = "sonialima.crm.pending-audit-errors.v1";
const ERROR_COOLDOWN_MS = 5 * 60 * 1_000;
const MAX_PENDING_ERRORS = 25;
let flushingPendingErrors = false;
const recentErrorReports = new Map<string, number>();

function errorMessage(error: unknown) {
  if (error instanceof Error) return error.message || error.name;
  if (error instanceof Response) return `HTTP ${error.status} ${error.statusText}`.trim();
  if (typeof error === "string") return error;
  try {
    return JSON.stringify(error);
  } catch {
    return "Erro desconhecido no cliente.";
  }
}

function sanitizeDetailValue(value: unknown, depth = 0): unknown {
  if (depth >= 3) return "[detalhe resumido]";
  if (value == null || typeof value === "boolean" || typeof value === "number") return value;
  if (typeof value === "string") return value.slice(0, 1_000);
  if (value instanceof Error) {
    return {
      name: value.name.slice(0, 120),
      message: value.message.slice(0, 1_000),
      stack: value.stack?.slice(0, 2_000),
    };
  }
  if (Array.isArray(value)) {
    return value.slice(0, 20).map((item) => sanitizeDetailValue(item, depth + 1));
  }
  if (typeof value === "object") {
    const sanitized: Record<string, unknown> = {};
    for (const [key, item] of Object.entries(value).slice(0, 30)) {
      if (/token|password|secret|authorization|cookie/i.test(key)) continue;
      sanitized[key] = sanitizeDetailValue(item, depth + 1);
    }
    return sanitized;
  }
  return String(value).slice(0, 1_000);
}

function safeDetails(value: Record<string, unknown> = {}) {
  const sanitized: Record<string, unknown> = {};
  for (const [key, item] of Object.entries(value).slice(0, 30)) {
    if (/token|password|secret|authorization|cookie/i.test(key)) continue;
    sanitized[key] = sanitizeDetailValue(item, 1);
  }
  return sanitized;
}

function errorFingerprint(error: PendingClientError) {
  const route = typeof error.details.route === "string" ? error.details.route : "";
  return `${error.area}|${error.operation}|${error.message}|${route}`.slice(0, 6_000);
}

function readPendingErrors() {
  if (typeof window === "undefined") return [] as PendingClientError[];
  try {
    const value = JSON.parse(window.localStorage.getItem(PENDING_ERRORS_KEY) ?? "[]");
    return Array.isArray(value) ? (value as PendingClientError[]).slice(-100) : [];
  } catch {
    return [] as PendingClientError[];
  }
}

function writePendingErrors(errors: PendingClientError[]) {
  if (typeof window === "undefined") return;
  try {
    const unique = new Map<string, PendingClientError>();
    for (const error of errors) unique.set(errorFingerprint(error), error);
    window.localStorage.setItem(
      PENDING_ERRORS_KEY,
      JSON.stringify([...unique.values()].slice(-MAX_PENDING_ERRORS)),
    );
  } catch {
    // Se o armazenamento local tambem estiver indisponivel, nao interrompemos o CRM.
  }
}

async function submitClientError(error: PendingClientError) {
  try {
    const { error: rpcError } = await supabase.rpc("record_crm_client_error", {
      p_area: error.area,
      p_operation: error.operation,
      p_message: error.message,
      p_details: error.details,
    });
    return !rpcError;
  } catch {
    return false;
  }
}

async function flushPendingClientErrors() {
  if (flushingPendingErrors) return;
  flushingPendingErrors = true;
  try {
    const pending = readPendingErrors();
    if (!pending.length) return;
    const remaining: PendingClientError[] = [];
    for (const error of pending) {
      if (!(await submitClientError(error))) remaining.push(error);
    }
    writePendingErrors(remaining);
  } finally {
    flushingPendingErrors = false;
  }
}

export async function reportCrmClientError(
  error: unknown,
  { area = "frontend", operation = "Operação no CRM", details = {} }: ClientErrorContext = {},
) {
  const message = errorMessage(error).slice(0, 4_000);
  const errorDetails = safeDetails({
    route: typeof window === "undefined" ? undefined : window.location.pathname,
    userAgent: typeof navigator === "undefined" ? undefined : navigator.userAgent,
    stack: error instanceof Error ? error.stack : undefined,
    happenedAt: new Date().toISOString(),
    ...details,
  });
  const pendingError = { area, operation, message, details: errorDetails };
  const fingerprint = errorFingerprint(pendingError);
  const now = Date.now();
  const lastReportedAt = recentErrorReports.get(fingerprint) ?? 0;
  if (now - lastReportedAt < ERROR_COOLDOWN_MS) return;
  recentErrorReports.set(fingerprint, now);

  if (recentErrorReports.size > 250) {
    for (const [key, reportedAt] of recentErrorReports) {
      if (now - reportedAt > ERROR_COOLDOWN_MS) recentErrorReports.delete(key);
    }
  }
  if (!(await submitClientError(pendingError))) {
    writePendingErrors([...readPendingErrors(), pendingError]);
  }
}

export async function recordNotificationClientEvent(
  notificationId: string,
  eventType: NotificationClientEvent,
  details: Record<string, unknown> = {},
) {
  if (!notificationId) return false;
  const clientEventId =
    typeof crypto !== "undefined" && typeof crypto.randomUUID === "function"
      ? crypto.randomUUID()
      : `${Date.now()}-${Math.random().toString(16).slice(2)}`;
  try {
    const { error } = await supabase.rpc("record_notification_client_event", {
      p_notification_id: notificationId,
      p_event_type: eventType,
      p_details: safeDetails({ clientEventId, ...details }),
    });
    if (error) throw error;
    return true;
  } catch (error) {
    await reportCrmClientError(error, {
      area: "notifications",
      operation: `Registrar evento ${eventType}`,
      details: { notificationId },
    });
    return false;
  }
}

export function installCrmClientErrorCapture() {
  if (typeof window === "undefined") return () => undefined;
  void flushPendingClientErrors();
  const onError = (event: ErrorEvent) => {
    void reportCrmClientError(event.error ?? event.message, {
      area: "window",
      operation: "Erro não tratado",
      details: { filename: event.filename, line: event.lineno, column: event.colno },
    });
  };
  const onUnhandledRejection = (event: PromiseRejectionEvent) => {
    void reportCrmClientError(event.reason, {
      area: "window",
      operation: "Promise rejeitada sem tratamento",
    });
  };
  const onOnline = () => void flushPendingClientErrors();
  window.addEventListener("error", onError);
  window.addEventListener("unhandledrejection", onUnhandledRejection);
  window.addEventListener("online", onOnline);
  return () => {
    window.removeEventListener("error", onError);
    window.removeEventListener("unhandledrejection", onUnhandledRejection);
    window.removeEventListener("online", onOnline);
  };
}

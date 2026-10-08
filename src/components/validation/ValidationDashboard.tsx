import {
  Activity,
  AlertTriangle,
  BellRing,
  CalendarClock,
  CheckCircle2,
  CircleX,
  Clock3,
  RefreshCw,
  Search,
  ShieldCheck,
  UserCheck,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { Button } from "@/components/ui/button";
import { Panel } from "@/components/dashboard/Panel";
import { supabase } from "@/lib/supabase";
import { reportCrmClientError } from "@/lib/audit-client";
import { displayBrokerName } from "@/lib/broker-names";
import { displayText } from "@/lib/display-text";
import { PropertyValueReviewValidation } from "@/components/validation/PropertyValueReviewValidation";

type JsonMap = Record<string, unknown>;

type AuditProfile = {
  id: string;
  full_name: string;
  email: string;
  role: string;
  is_validator: boolean;
  notification_count: number;
  unread_count: number;
  last_notification_at: string | null;
};

type AuditNotification = {
  id: string;
  recipient_id: string;
  recipient_name: string;
  recipient_email: string;
  kind: string;
  title: string;
  body: string;
  url: string;
  payload: JsonMap;
  created_at: string;
  available_at: string | null;
  delivery_status: string;
  delivery_attempt_count: number;
  last_delivery_attempt_at: string | null;
  last_delivery_http_status: number | null;
  last_delivery_error: string | null;
  legacy_processed_or_sent_at: string | null;
  read_at: string | null;
  dismissed_at: string | null;
};

type DeliveryAttempt = {
  id: string;
  notification_id: string;
  recipient_id: string;
  recipient_name: string;
  recipient_email: string;
  subscription_id: string | null;
  channel: string;
  status: string;
  attempted_at: string;
  completed_at: string | null;
  http_status: number | null;
  error_code: string | null;
  error_message: string | null;
  details: JsonMap;
};

type LeadAssignment = {
  id: string;
  lead_id: string;
  lead_name: string;
  broker_id: string;
  broker_name: string;
  broker_email: string;
  attempt_number: number;
  run_number?: number;
  round_number?: number;
  notified_at: string;
  deadline_at: string;
  accepted_at: string | null;
  expired_at: string | null;
};

type LeadActivity = {
  id: string;
  lead_id: string;
  lead_name: string;
  owner_id: string;
  owner_name: string;
  owner_email: string;
  stage: string;
  note: string | null;
  author_id: string | null;
  author_name: string;
  author_email: string | null;
  created_at: string;
};

type AgendaEntry = {
  id: string;
  target_user_id: string;
  target_name: string;
  target_email: string;
  created_by: string;
  creator_name: string;
  creator_email: string;
  category: string;
  scheduled_at: string;
  observation: string;
  feedback_at: string | null;
  feedback_note: string | null;
  feedback_by: string | null;
  feedback_history: unknown[];
  cartorio_protocol_versions: unknown[] | null;
  cartorio_received_at: string | null;
  cartorio_delivered_to_vitor_at: string | null;
  cartorio_vitor_document_uploaded_at: string | null;
  created_at: string;
  updated_at: string;
};

type AuditEvent = {
  id: number;
  subject_user_id: string | null;
  subject_name: string | null;
  subject_email: string | null;
  actor_user_id: string | null;
  actor_email: string | null;
  category: string;
  event_type: string;
  status: string | null;
  entity_type: string | null;
  entity_id: string | null;
  notification_id?: string | null;
  happened_at: string;
  summary: string;
  details: JsonMap;
  error_message: string | null;
};

type UserActionHistory = {
  id: number;
  actor_id: string | null;
  actor_name: string;
  actor_email: string | null;
  operation: "insert" | "update" | "delete";
  area: string;
  source_table: string;
  entity_id: string | null;
  entity_label: string | null;
  before_data: JsonMap;
  after_data: JsonMap;
  changes: Record<string, { before?: unknown; after?: unknown }>;
  occurred_at: string;
};

type ValidationSnapshot = {
  generatedAt: string;
  profileId: string | null;
  profiles: AuditProfile[];
  notifications: AuditNotification[];
  deliveryAttempts: DeliveryAttempt[];
  leadAssignments: LeadAssignment[];
  leadActivities: LeadActivity[];
  agendaEntries: AgendaEntry[];
  auditEvents: AuditEvent[];
  systemErrors: AuditEvent[];
  legacyDeliveryWarning: string;
};

type View = "notifications" | "actions" | "history" | "errors";

async function withTimeout<T>(operation: PromiseLike<T>, milliseconds = 15_000): Promise<T> {
  return Promise.race([
    Promise.resolve(operation),
    new Promise<never>((_, reject) =>
      window.setTimeout(
        () => reject(new Error("A consulta demorou demais. Tente atualizar novamente.")),
        milliseconds,
      ),
    ),
  ]);
}

const EMPTY_SNAPSHOT: ValidationSnapshot = {
  generatedAt: "",
  profileId: null,
  profiles: [],
  notifications: [],
  deliveryAttempts: [],
  leadAssignments: [],
  leadActivities: [],
  agendaEntries: [],
  auditEvents: [],
  systemErrors: [],
  legacyDeliveryWarning: "",
};

const deliveryLabels: Record<string, string> = {
  queued: "Na fila",
  processing: "Enviando",
  sent: "Envio aceito",
  failed: "Falha no envio",
  no_subscription: "Sem dispositivo",
  invalid_subscription: "Dispositivo inválido",
  processed_legacy: "Processado (legado)",
};

const eventLabels: Record<string, string> = {
  lead_assignment_attempt_created: "Lead encaminhado",
  lead_assignment_accepted: "Lead aceito",
  lead_assignment_expired: "Prazo do lead expirado",
  lead_activity_created: "Etapa do lead registrada",
  agenda_entry_created: "Compromisso criado",
  agenda_entry_deleted: "Compromisso excluído",
  agenda_feedback_recorded: "Retorno da agenda registrado",
  cartorio_protocol_saved: "Protocolo de cartório salvo",
  cartorio_received: "Documento recebido no cartório",
  cartorio_delivered_to_vitor: "Documento entregue ao Vitor",
  cartorio_vitor_document_uploaded: "Documento digitalizado pelo Vitor",
  daily_revenue_created: "Lançamento diário criado",
  daily_revenue_deleted: "Lançamento diário excluído",
  broker_added_to_team: "Corretor adicionado à equipe",
  broker_removed_from_team: "Corretor removido das filas",
  browser_presented: "Notificação apresentada pelo navegador",
  push_clicked: "Notifica\u00e7\u00e3o instant\u00e2nea aberta",
  push_closed: "Notifica\u00e7\u00e3o instant\u00e2nea fechada",
  inbox_presented: "Notificação exibida na caixa do CRM",
  inbox_opened: "Notificação aberta no CRM",
  notification_queued: "Notificação criada",
  inbox_read: "Notificação marcada como lida",
  inbox_dismissed: "Notificação removida da caixa",
  notification_client_error: "Erro ao apresentar a notificação",
  client_error: "Erro no CRM",
  system_error: "Erro de sistema",
};

const historyFieldLabels: Record<string, string> = {
  value: "Valor",
  rental_value: "Valor de locação",
  desired_property_value: "Valor desejado",
  commission: "Comissão",
  stage: "Etapa",
  status: "Status",
  owner_id: "Responsável",
  brokers: "Corretores responsáveis",
  wimoveis_code: "Código W Imóveis",
  dfimoveis_code: "Código DF Imóveis",
  title: "Título",
  address: "Endereço",
  neighborhood: "Bairro",
  city: "Cidade",
  property_interest: "Imóvel de interesse",
  phone: "Telefone",
  email: "E-mail",
  notes: "Observações",
  scheduled_at: "Data agendada",
  scheduled_for: "Data agendada",
  reviewable: "Revisável",
  url: "Link",
  assignment_status: "Situação da esteira",
  assignment_deadline_at: "Prazo da esteira",
  assignment_available_at: "Disponível a partir de",
  assignment_run_number: "Execução da esteira",
  attempt_number: "Número da tentativa",
  run_number: "Execução",
  round_number: "Rodada",
  broker_name: "Corretor",
  lead_name: "Lead",
};

function assignmentHistorySummary(entry: UserActionHistory) {
  if (entry.source_table !== "lead_assignment_attempts") return null;
  const data = entry.after_data ?? {};
  const lead = String(data.lead_name ?? "Lead não identificado");
  const broker = String(data.broker_name ?? "Corretor não identificado");
  const run = Number(data.run_number ?? 1);
  const round = Number(data.round_number ?? 1);
  const attempt = Number(data.attempt_number ?? 1);
  const accepted = typeof data.accepted_at === "string" && data.accepted_at;
  const expired = typeof data.expired_at === "string" && data.expired_at;
  return `${lead} foi encaminhado para ${broker} na execução ${run}, rodada ${round}, tentativa ${attempt}. ${
    accepted
      ? `Aceito em ${formatDate(accepted)}.`
      : expired
        ? `Expirou em ${formatDate(expired)}.`
        : "Ficou aguardando resposta."
  }`;
}

function formatHistoryValue(field: string, value: unknown) {
  if (value === null || value === undefined || value === "") return "Não informado";
  if (typeof value === "boolean") return value ? "Sim" : "Não";
  if (
    typeof value === "number" &&
    [
      "value",
      "rental_value",
      "desired_property_value",
      "commission",
      "revenue",
      "invested",
    ].includes(field)
  )
    return value.toLocaleString("pt-BR", { style: "currency", currency: "BRL" });
  if (typeof value === "string" && /^\d{4}-\d{2}-\d{2}T/.test(value)) {
    const date = new Date(value);
    if (!Number.isNaN(date.getTime())) return formatDate(value);
  }
  if (typeof value === "object") return displayAdministratorLabel(JSON.stringify(value));
  return displayText(displayAdministratorLabel(String(value)));
}

function displayAdministratorLabel(value?: string | null) {
  return value
    ?.replace(/crmallyson/gi, "crmadministrador")
    .replace(/crmadministrador/gi, "crmadministrador")
    .replace(/allyson@sonialima\.com\.br/gi, "administrador@sonialima.com.br")
    .replace(/allyson/gi, "Administrador") ?? "";
}

function displayAdministratorEmail(value?: string | null) {
  return displayAdministratorLabel(value);
}
function formatDate(value?: string | null) {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "—";
  return date.toLocaleString("pt-BR", {
    timeZone: "America/Sao_Paulo",
    dateStyle: "short",
    timeStyle: "medium",
  });
}

function scheduledFromPayload(payload: JsonMap) {
  const keys = [
    "availableAt",
    "available_at",
    "scheduledAt",
    "scheduled_at",
    "scheduledFor",
    "scheduled_for",
    "deadlineAt",
    "deadline_at",
    "dueAt",
    "due_at",
    "visitScheduledAt",
  ];
  for (const key of keys) {
    const value = payload[key];
    if (typeof value === "string" && !Number.isNaN(new Date(value).getTime())) return value;
  }
  return null;
}

function statusClass(status?: string | null) {
  if (["sent", "read", "recorded", "completed", "active"].includes(status ?? ""))
    return "border-emerald-400/20 bg-emerald-400/10 text-emerald-300";
  if (["failed", "error", "invalid_subscription", "expired"].includes(status ?? ""))
    return "border-red-400/20 bg-red-400/10 text-red-300";
  if (["queued", "pending", "processing", "processed_legacy"].includes(status ?? ""))
    return "border-amber-300/20 bg-amber-300/10 text-amber-200";
  return "border-white/10 bg-white/[0.04] text-muted-foreground";
}

function StatusBadge({ status, label }: { status?: string | null; label?: string }) {
  return (
    <span
      className={`inline-flex rounded-full border px-2 py-1 text-[10px] font-semibold ${statusClass(status)}`}
    >
      {label ?? status ?? "Não informado"}
    </span>
  );
}

function SummaryCard({
  icon: Icon,
  label,
  value,
  tone = "default",
}: {
  icon: typeof Activity;
  label: string;
  value: number;
  tone?: "default" | "success" | "danger";
}) {
  const toneClass =
    tone === "success" ? "text-emerald-300" : tone === "danger" ? "text-red-300" : "text-copper";
  return (
    <div className="glass rounded-2xl p-4">
      <div className={`flex items-center gap-2 text-xs ${toneClass}`}>
        <Icon size={16} />
        <span>{label}</span>
      </div>
      <p className="mt-3 text-3xl font-semibold tabular-nums text-foreground">{value}</p>
    </div>
  );
}

function EmptyState({ text }: { text: string }) {
  return (
    <div className="rounded-xl border border-dashed border-white/10 px-5 py-10 text-center text-sm text-muted-foreground">
      {text}
    </div>
  );
}

function DetailJson({ value }: { value: unknown }) {
  if (!value || (typeof value === "object" && !Object.keys(value as object).length)) return null;
  return (
    <details className="mt-2 text-xs text-muted-foreground">
      <summary className="cursor-pointer text-copper">Ver dados técnicos</summary>
      <pre className="mt-2 max-h-52 overflow-auto whitespace-pre-wrap rounded-lg bg-black/20 p-3 text-[10px]">
        {JSON.stringify(
          value,
          (_key, nestedValue) =>
            typeof nestedValue === "string" ? displayText(displayAdministratorLabel(nestedValue)) : nestedValue,
          2,
        )}
      </pre>
    </details>
  );
}

export function ValidationDashboard() {
  const [snapshot, setSnapshot] = useState<ValidationSnapshot>(EMPTY_SNAPSHOT);
  const [profiles, setProfiles] = useState<AuditProfile[]>([]);
  const [selectedProfileId, setSelectedProfileId] = useState<string | null>(null);
  const [view, setView] = useState<View>("history");
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState("");
  const [history, setHistory] = useState<UserActionHistory[]>([]);
  const [historyQuery, setHistoryQuery] = useState("");
  const [historyArea, setHistoryArea] = useState("");
  const [historyLoading, setHistoryLoading] = useState(false);
  const [pendingLeadCount, setPendingLeadCount] = useState(0);

  const loadHistory = useCallback(async () => {
    setHistoryLoading(true);
    try {
      let { data, error: historyError } = await withTimeout(
        supabase.rpc("search_crm_user_action_history", {
          p_query: historyQuery.trim() || undefined,
          p_area: historyArea || undefined,
          p_limit: 1000,
          p_offset: 0,
        }),
      );
      if (historyError?.code === "PGRST202") {
        const fallback = await withTimeout(
          supabase
            .from("crm_user_action_history")
            .select("*")
            .order("occurred_at", { ascending: false })
            .limit(1000),
        );
        data = fallback.data;
        historyError = fallback.error;
      }
      if (historyError) throw new Error(historyError.message);
      const normalizedQuery = historyQuery.trim().toLocaleLowerCase("pt-BR");
      setHistory(
        ((data ?? []) as UserActionHistory[]).filter((entry) => {
          if (historyArea && entry.area !== historyArea) return false;
          if (!normalizedQuery) return true;
          return JSON.stringify(entry).toLocaleLowerCase("pt-BR").includes(normalizedQuery);
        }),
      );
      setError("");
    } catch (historyError) {
      setError(
        historyError instanceof Error
          ? displayText(historyError.message)
          : "Não foi possível consultar o histórico.",
      );
    } finally {
      setHistoryLoading(false);
    }
  }, [historyArea, historyQuery]);

  const load = useCallback(
    async (manual = false) => {
      if (manual) setRefreshing(true);
      else setLoading(true);
      try {
        let pendingLeadsQuery = supabase
          .from("crm_leads")
          .select("id")
          .eq("stage", "Aguardando atendimento");
        if (selectedProfileId) {
          pendingLeadsQuery = pendingLeadsQuery.eq("owner_id", selectedProfileId);
        }

        const [{ data, error: rpcError }, { data: pendingLeads, error: pendingLeadsError }] =
          await Promise.all([
            withTimeout(
              supabase.rpc("get_validation_audit", {
                p_profile_id: selectedProfileId,
                p_limit: 500,
              }),
            ),
            withTimeout(pendingLeadsQuery),
          ]);
        if (rpcError) throw rpcError;
        if (pendingLeadsError) throw pendingLeadsError;
        const next = (data ?? EMPTY_SNAPSHOT) as unknown as ValidationSnapshot;
        setPendingLeadCount((pendingLeads ?? []).length);
        setSnapshot({
          ...EMPTY_SNAPSHOT,
          ...next,
          leadAssignments: next.leadAssignments ?? [],
        });
        if (selectedProfileId === null) setProfiles(next.profiles ?? []);
        setError("");
      } catch (rpcError) {
        const message =
          rpcError instanceof Error
            ? displayText(rpcError.message)
            : "N\u00e3o foi poss\u00edvel carregar a auditoria.";
        setError(message);
        void reportCrmClientError(rpcError, {
          area: "validation",
          operation: "Carregar painel de validação",
          details: { selectedProfileId },
        });
      }
      setLoading(false);
      setRefreshing(false);
    },
    [selectedProfileId],
  );

  useEffect(() => {
    void load();
    const timer = window.setInterval(() => {
      if (document.visibilityState === "visible") void load();
    }, 30_000);
    return () => window.clearInterval(timer);
  }, [load]);

  useEffect(() => {
    if (view === "history") void loadHistory();
  }, [view, loadHistory]);

  const brokers = useMemo(
    () => profiles.filter((profile) => profile.role === "broker"),
    [profiles],
  );
  const attemptsByNotification = useMemo(() => {
    const grouped = new Map<string, DeliveryAttempt[]>();
    for (const attempt of snapshot.deliveryAttempts) {
      grouped.set(attempt.notification_id, [
        ...(grouped.get(attempt.notification_id) ?? []),
        attempt,
      ]);
    }
    return grouped;
  }, [snapshot.deliveryAttempts]);
  const notificationEventsById = useMemo(() => {
    const grouped = new Map<string, AuditEvent[]>();
    for (const event of snapshot.auditEvents) {
      if (event.category !== "notification" || !event.notification_id) continue;
      grouped.set(event.notification_id, [...(grouped.get(event.notification_id) ?? []), event]);
    }
    return grouped;
  }, [snapshot.auditEvents]);
  const sentCount = snapshot.notifications.filter(
    (notification) => notification.delivery_status === "sent",
  ).length;
  const explicitlyOpenedNotificationIds = new Set(
    snapshot.auditEvents
      .filter(
        (event) =>
          event.notification_id && ["inbox_opened", "push_clicked"].includes(event.event_type),
      )
      .map((event) => event.notification_id as string),
  );
  const openedCount = explicitlyOpenedNotificationIds.size;
  const currentProfile = profiles.find((profile) => profile.id === selectedProfileId);

  return (
    <>
      <section className="mb-7 flex flex-wrap items-end justify-between gap-4">
        <div>
          <div className="flex items-center gap-2 text-[11px] uppercase tracking-[0.24em] text-muted-foreground">
            <ShieldCheck size={14} className="text-copper" />
            Auditoria exclusiva
          </div>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight text-foreground">
            Painel de validação
          </h1>
          <p className="mt-1 max-w-3xl text-sm text-muted-foreground">
            Evidências de notificações, entregas técnicas, aberturas, descartes, ações e erros do
            CRM.
          </p>
        </div>
        <Button
          variant="outline"
          onClick={() => void load(true)}
          disabled={refreshing}
          className="gap-2"
        >
          <RefreshCw size={15} className={refreshing ? "animate-spin" : ""} />
          Atualizar agora
        </Button>
      </section>

      {error && (
        <div
          role="alert"
          className="mb-5 rounded-xl border border-red-400/20 bg-red-400/10 p-4 text-sm text-red-200"
        >
          Não foi possível carregar a auditoria: {error}
        </div>
      )}

      <PropertyValueReviewValidation />

      <div className="mb-6 overflow-x-auto pb-2">
        <div className="flex min-w-max gap-2">
          <button
            type="button"
            onClick={() => setSelectedProfileId(null)}
            className={`rounded-xl border px-4 py-2 text-sm font-medium transition ${selectedProfileId === null ? "border-copper/50 bg-copper/15 text-copper" : "border-white/10 bg-white/[0.03] text-muted-foreground hover:text-foreground"}`}
          >
            Toda a equipe
          </button>
          {brokers.map((profile) => (
            <button
              key={profile.id}
              type="button"
              onClick={() => setSelectedProfileId(profile.id)}
              className={`rounded-xl border px-4 py-2 text-sm font-medium transition ${selectedProfileId === profile.id ? "border-copper/50 bg-copper/15 text-copper" : "border-white/10 bg-white/[0.03] text-muted-foreground hover:text-foreground"}`}
            >
              {displayBrokerName(profile.full_name) || profile.email}
            </button>
          ))}
        </div>
      </div>

      <div className="mb-5 flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 className="text-lg font-semibold text-foreground">
            {currentProfile
              ? displayBrokerName(currentProfile.full_name) || currentProfile.email
              : "Visão geral da equipe"}
          </h2>
          <p className="text-xs text-muted-foreground">
            Atualização automática a cada 30 segundos · último snapshot{" "}
            {formatDate(snapshot.generatedAt)}
          </p>
        </div>
        <div className="flex rounded-xl border border-white/10 bg-white/[0.02] p-1">
          {(
            [
              ["notifications", "Notificações"],
              ["actions", "Ações e etapas"],
              ["history", "Histórico permanente"],
              ["errors", `Erros (${snapshot.systemErrors.length})`],
            ] as const
          ).map(([value, label]) => (
            <button
              key={value}
              type="button"
              onClick={() => setView(value)}
              className={`rounded-lg px-3 py-2 text-xs font-medium transition ${view === value ? "bg-copper text-white" : "text-muted-foreground hover:text-foreground"}`}
            >
              {label}
            </button>
          ))}
        </div>
      </div>

      <section className="mb-6 grid grid-cols-2 gap-3 lg:grid-cols-5">
        <SummaryCard icon={BellRing} label="Notificações" value={snapshot.notifications.length} />
        <SummaryCard icon={CheckCircle2} label="Envio aceito" value={sentCount} tone="success" />
        <SummaryCard
          icon={UserCheck}
          label="Aberturas comprovadas"
          value={openedCount}
          tone="success"
        />
        <SummaryCard icon={Clock3} label="Leads aguardando" value={pendingLeadCount} />
        <SummaryCard
          icon={CircleX}
          label="Erros registrados"
          value={snapshot.systemErrors.length}
          tone="danger"
        />
      </section>

      {view !== "history" && loading && snapshot.generatedAt === "" ? (
        <div className="glass rounded-2xl px-5 py-20 text-center text-sm text-muted-foreground">
          <RefreshCw className="mx-auto mb-3 animate-spin text-copper" size={20} />
          Carregando trilha de validação…
        </div>
      ) : view === "notifications" ? (
        <NotificationsView
          notifications={snapshot.notifications}
          attemptsByNotification={attemptsByNotification}
          eventsByNotification={notificationEventsById}
          notificationEvents={snapshot.auditEvents.filter(
            (event) => event.category === "notification",
          )}
          legacyWarning={snapshot.legacyDeliveryWarning}
        />
      ) : view === "actions" ? (
        <ActionsView snapshot={snapshot} />
      ) : view === "history" ? (
        <PermanentHistoryView
          history={history}
          query={historyQuery}
          area={historyArea}
          loading={historyLoading}
          onQueryChange={setHistoryQuery}
          onAreaChange={setHistoryArea}
          onSearch={() => void loadHistory()}
        />
      ) : (
        <ErrorsView errors={snapshot.systemErrors} />
      )}
    </>
  );
}

function PermanentHistoryView({
  history,
  query,
  area,
  loading,
  onQueryChange,
  onAreaChange,
  onSearch,
}: {
  history: UserActionHistory[];
  query: string;
  area: string;
  loading: boolean;
  onQueryChange: (value: string) => void;
  onAreaChange: (value: string) => void;
  onSearch: () => void;
}) {
  return (
    <Panel
      title="Histórico permanente de alterações"
      subtitle="Registros imutáveis com responsável, data, hora e comparação antes/depois."
    >
      <form
        className="mb-5 grid gap-2 sm:grid-cols-[minmax(0,1fr)_190px_auto]"
        onSubmit={(event) => {
          event.preventDefault();
          onSearch();
        }}
      >
        <input
          value={query}
          onChange={(event) => onQueryChange(event.target.value)}
          placeholder="Pesquisar imóvel, lead, usuário ou conteúdo..."
          className="rounded-lg border border-white/10 bg-white/[0.03] px-3 py-2.5 text-sm outline-none focus:border-copper/50"
        />
        <select
          value={area}
          onChange={(event) => onAreaChange(event.target.value)}
          className="rounded-lg border border-white/10 bg-background px-3 py-2.5 text-sm outline-none focus:border-copper/50"
        >
          <option value="">Todas as áreas</option>
          <option value="imóvel">Imóveis</option>
          <option value="lead">Leads</option>
          <option value="agenda">Agenda</option>
          <option value="marketing">{"Divulga\u00e7\u00e3o"}</option>
          <option value="preenchimento diário">Preenchimento diário</option>
          <option value="integração">Integrações</option>
          <option value="distribuição">Distribuição</option>
          <option value="usuário">Usuários</option>
        </select>
        <Button type="submit" variant="outline" disabled={loading} className="gap-2">
          {loading ? <RefreshCw size={15} className="animate-spin" /> : <Search size={15} />}
          Pesquisar
        </Button>
      </form>

      {!history.length && !loading ? (
        <EmptyState text="Nenhuma alteração encontrada para os filtros informados." />
      ) : (
        <div className="space-y-3">
          {history.map((entry) => {
            const changes = Object.entries(entry.changes ?? {});
            const assignmentSummary = assignmentHistorySummary(entry);
            return (
              <article
                key={entry.id}
                className="rounded-xl border border-white/8 bg-white/[0.02] p-4"
              >
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div>
                    <div className="flex flex-wrap items-center gap-2">
                      <StatusBadge
                        status={entry.operation === "delete" ? "error" : "recorded"}
                        label={
                          entry.operation === "insert"
                            ? "Cadastro"
                            : entry.operation === "update"
                              ? "Alteração"
                              : "Exclusão"
                        }
                      />
                      <span className="text-[10px] uppercase tracking-wider text-copper">
                        {entry.area}
                      </span>
                    </div>
                    <h3 className="mt-2 text-sm font-semibold text-foreground">
                      {displayAdministratorLabel(entry.entity_label) || entry.entity_id || entry.source_table}
                    </h3>
                    <p className="mt-1 text-xs text-muted-foreground">
                      Por {displayBrokerName(entry.actor_name) || entry.actor_name}
                      {entry.actor_email ? ` · ${displayAdministratorEmail(entry.actor_email)}` : ""}
                    </p>
                  </div>
                  <time className="text-[11px] text-muted-foreground">
                    {formatDate(entry.occurred_at)}
                  </time>
                </div>

                {assignmentSummary && (
                  <p className="mt-3 rounded-lg border border-amber-300/15 bg-amber-300/5 p-3 text-xs leading-relaxed text-amber-100">
                    {assignmentSummary}
                  </p>
                )}

                {changes.length > 0 && (
                  <div className="mt-3 space-y-2 rounded-lg border border-white/10 bg-black/10 p-3">
                    {changes.map(([field, change]) => (
                      <div
                        key={field}
                        className="grid gap-1 text-xs sm:grid-cols-[170px_1fr_auto_1fr]"
                      >
                        <span className="font-medium text-foreground">
                          {historyFieldLabels[field] ?? field.replaceAll("_", " ")}
                        </span>
                        <span className="break-words text-red-300/90">
                          {formatHistoryValue(field, change.before)}
                        </span>
                        <span className="text-muted-foreground">→</span>
                        <span className="break-words text-emerald-300">
                          {formatHistoryValue(field, change.after)}
                        </span>
                      </div>
                    ))}
                  </div>
                )}

                {entry.operation !== "update" && !assignmentSummary && (
                  <DetailJson
                    value={entry.operation === "insert" ? entry.after_data : entry.before_data}
                  />
                )}
              </article>
            );
          })}
        </div>
      )}
    </Panel>
  );
}

function NotificationsView({
  notifications,
  attemptsByNotification,
  eventsByNotification,
  notificationEvents,
  legacyWarning,
}: {
  notifications: AuditNotification[];
  attemptsByNotification: Map<string, DeliveryAttempt[]>;
  eventsByNotification: Map<string, AuditEvent[]>;
  notificationEvents: AuditEvent[];
  legacyWarning: string;
}) {
  const currentIds = new Set(notifications.map((notification) => notification.id));
  const preservedEvents = notificationEvents.filter(
    (event) => event.notification_id && !currentIds.has(event.notification_id),
  );
  return (
    <Panel
      title="Histórico de notificações"
      subtitle="Envio aceito significa confirma\u00e7\u00e3o t\u00e9cnica do provedor; n\u00e3o confirma leitura humana."
    >
      {legacyWarning && (
        <div className="mb-4 flex gap-2 rounded-xl border border-amber-300/20 bg-amber-300/5 p-3 text-xs leading-relaxed text-amber-100">
          <AlertTriangle size={16} className="mt-0.5 shrink-0" />
          {legacyWarning}
        </div>
      )}
      {!notifications.length && !preservedEvents.length ? (
        <EmptyState text="Nenhuma notificação registrada para esta seleção." />
      ) : (
        <div className="space-y-3">
          {notifications.map((notification) => {
            const attempts = attemptsByNotification.get(notification.id) ?? [];
            const events = eventsByNotification.get(notification.id) ?? [];
            const chronologicalEvents = [...events].reverse();
            const presentedEvent = chronologicalEvents.find(
              (event) => event.event_type === "browser_presented",
            );
            const inboxPresentedEvent = chronologicalEvents.find(
              (event) => event.event_type === "inbox_presented",
            );
            const openedEvent = chronologicalEvents.find((event) =>
              ["inbox_opened", "push_clicked"].includes(event.event_type),
            );
            const scheduledAt =
              notification.available_at ?? scheduledFromPayload(notification.payload ?? {});
            return (
              <article
                key={notification.id}
                className="rounded-xl border border-white/8 bg-white/[0.02] p-4"
              >
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div className="min-w-0 flex-1">
                    <div className="flex flex-wrap items-center gap-2">
                      <StatusBadge
                        status={notification.delivery_status}
                        label={
                          deliveryLabels[notification.delivery_status] ??
                          notification.delivery_status
                        }
                      />
                      <span className="text-[10px] uppercase tracking-wider text-muted-foreground">
                        {notification.kind}
                      </span>
                    </div>
                    <h3 className="mt-2 text-sm font-semibold text-foreground">
                      {displayText(notification.title)}
                    </h3>
                    <p className="mt-1 text-xs leading-relaxed text-muted-foreground">
                      {displayText(notification.body)}
                    </p>
                    <p className="mt-2 text-[11px] text-muted-foreground">
                      Para:{" "}
                      {displayBrokerName(notification.recipient_name) ||
                        notification.recipient_email}{" "}
                      · {notification.recipient_email}
                    </p>
                  </div>
                  <div className="min-w-[210px] space-y-1 text-[11px] text-muted-foreground">
                    <p>
                      <span className="text-foreground/80">Criada:</span>{" "}
                      {formatDate(notification.created_at)}
                    </p>
                    {scheduledAt && (
                      <p>
                        <span className="text-foreground/80">Programada:</span>{" "}
                        {formatDate(scheduledAt)}
                      </p>
                    )}
                    <p>
                      <span className="text-foreground/80">Última tentativa:</span>{" "}
                      {formatDate(notification.last_delivery_attempt_at)}
                    </p>
                    <p>
                      <span className="text-foreground/80">Envio aceito/processado:</span>{" "}
                      {formatDate(notification.legacy_processed_or_sent_at)}
                    </p>
                    <p>
                      <span className="text-foreground/80">Apresentada no aparelho:</span>{" "}
                      {formatDate(presentedEvent?.happened_at)}
                    </p>
                    <p>
                      <span className="text-foreground/80">Exibida na caixa do CRM:</span>{" "}
                      {formatDate(inboxPresentedEvent?.happened_at)}
                    </p>
                    <p>
                      <span className="text-foreground/80">Aberta pelo usuário:</span>{" "}
                      {formatDate(openedEvent?.happened_at)}
                    </p>
                    <p>
                      <span className="text-foreground/80">Marcada como lida:</span>{" "}
                      {formatDate(notification.read_at)}
                    </p>
                    <p>
                      <span className="text-foreground/80">Removida da caixa:</span>{" "}
                      {formatDate(notification.dismissed_at)}
                    </p>
                  </div>
                </div>
                {notification.last_delivery_error && (
                  <p className="mt-3 rounded-lg bg-red-400/10 px-3 py-2 text-xs text-red-200">
                    {notification.last_delivery_error}
                    {notification.last_delivery_http_status
                      ? ` · HTTP ${notification.last_delivery_http_status}`
                      : ""}
                  </p>
                )}
                <div className="mt-3 flex flex-wrap gap-2 text-[10px] text-muted-foreground">
                  <span>{notification.delivery_attempt_count} tentativa(s) registrada(s)</span>
                  {notification.url && <span>Destino: {notification.url}</span>}
                </div>
                {attempts.length > 0 && (
                  <details className="mt-3 rounded-lg border border-white/5 bg-black/10 p-3">
                    <summary className="cursor-pointer text-xs font-medium text-copper">
                      Ver tentativas técnicas ({attempts.length})
                    </summary>
                    <div className="mt-3 space-y-2">
                      {attempts.map((attempt) => (
                        <div
                          key={attempt.id}
                          className="flex flex-wrap items-center gap-2 text-[11px] text-muted-foreground"
                        >
                          <StatusBadge
                            status={attempt.status}
                            label={deliveryLabels[attempt.status] ?? attempt.status}
                          />
                          <span>{formatDate(attempt.attempted_at)}</span>
                          {attempt.http_status && <span>HTTP {attempt.http_status}</span>}
                          {attempt.error_message && (
                            <span className="text-red-300">
                              {displayText(attempt.error_message)}
                            </span>
                          )}
                        </div>
                      ))}
                    </div>
                  </details>
                )}
                {events.length > 0 && (
                  <details className="mt-3 rounded-lg border border-white/5 bg-black/10 p-3">
                    <summary className="cursor-pointer text-xs font-medium text-copper">
                      Ver linha do tempo da notificação ({events.length})
                    </summary>
                    <div className="mt-3 space-y-2">
                      {events.map((event) => (
                        <div
                          key={event.id}
                          className="flex flex-wrap items-center gap-2 text-[11px] text-muted-foreground"
                        >
                          <StatusBadge status={event.status} />
                          <span>{eventLabels[event.event_type] ?? event.event_type}</span>
                          <span>{formatDate(event.happened_at)}</span>
                          {event.actor_email && <span>por {displayAdministratorEmail(event.actor_email)}</span>}
                          {event.error_message && (
                            <span className="text-red-300">{displayText(event.error_message)}</span>
                          )}
                        </div>
                      ))}
                    </div>
                  </details>
                )}
                <DetailJson value={notification.payload} />
              </article>
            );
          })}
        </div>
      )}
      {preservedEvents.length > 0 && (
        <div className="mt-5 rounded-xl border border-white/8 bg-white/[0.02] p-4">
          <h3 className="text-sm font-semibold text-foreground">
            Registros preservados sem item na lista atual
          </h3>
          <div className="mt-3 space-y-2">
            {preservedEvents.map((event) => (
              <div
                key={event.id}
                className="flex flex-wrap items-center gap-2 text-xs text-muted-foreground"
              >
                <StatusBadge status={event.status} />
                <span>{eventLabels[event.event_type] ?? event.event_type}</span>
                <span>{displayText(displayAdministratorLabel(event.summary))}</span>
                <span>{formatDate(event.happened_at)}</span>
                {event.subject_email && <span>· {displayAdministratorEmail(event.subject_email)}</span>}
              </div>
            ))}
          </div>
        </div>
      )}
    </Panel>
  );
}

function ActionsView({ snapshot }: { snapshot: ValidationSnapshot }) {
  const operationalEvents = snapshot.auditEvents.filter(
    (event) => event.category !== "notification" && event.category !== "error",
  );
  return (
    <div className="space-y-5">
      <Panel
        title="Linha do tempo auditável"
        subtitle="Registro imutável das ações realizadas no CRM."
      >
        {!operationalEvents.length ? (
          <EmptyState text="Nenhuma ação auditável registrada para esta seleção." />
        ) : (
          <div className="relative space-y-3 before:absolute before:bottom-2 before:left-[11px] before:top-2 before:w-px before:bg-white/10">
            {operationalEvents.map((event) => (
              <article key={event.id} className="relative pl-9">
                <span className="absolute left-1 top-2 h-4 w-4 rounded-full border-4 border-background bg-copper" />
                <div className="rounded-xl border border-white/8 bg-white/[0.02] p-3">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <p className="text-sm font-medium text-foreground">
                      {displayText(
                        eventLabels[event.event_type] ?? event.summary ?? event.event_type,
                      )}
                    </p>
                    <span className="text-[11px] text-muted-foreground">
                      {formatDate(event.happened_at)}
                    </span>
                  </div>
                  <div className="mt-1 flex flex-wrap gap-2 text-[11px] text-muted-foreground">
                    <StatusBadge status={event.status} />
                    {event.actor_email && <span>Executado por {displayAdministratorEmail(event.actor_email)}</span>}
                    {event.subject_email && <span>Referente a {displayAdministratorEmail(event.subject_email)}</span>}
                  </div>
                  {event.error_message && (
                    <p className="mt-2 text-xs text-red-300">{displayText(event.error_message)}</p>
                  )}
                  <DetailJson value={event.details} />
                </div>
              </article>
            ))}
          </div>
        )}
      </Panel>

      <Panel
        title="Tentativas de distribuição"
        subtitle="Encaminhamento, prazo, aceite ou expiração dos leads."
      >
        {!snapshot.leadAssignments.length ? (
          <EmptyState text="Nenhuma tentativa de distribuição registrada." />
        ) : (
          <>
            <div className="space-y-3 lg:hidden">
              {snapshot.leadAssignments.map((assignment) => (
                <article
                  key={assignment.id}
                  className="rounded-xl border border-white/8 bg-white/[0.02] p-3 text-xs"
                >
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0">
                      <p className="break-words font-semibold text-foreground">
                        {assignment.lead_name || assignment.lead_id}
                      </p>
                      <p className="mt-1 break-words text-muted-foreground">
                        {displayBrokerName(assignment.broker_name) || assignment.broker_email}
                      </p>
                    </div>
                    <span className="shrink-0 rounded-full bg-white/[0.04] px-2 py-1 text-[10px] text-muted-foreground">
                      Execução {assignment.run_number ?? 1} · rodada {assignment.round_number ?? 1}·
                      tentativa #{assignment.attempt_number}
                    </span>
                  </div>
                  <dl className="mt-3 grid gap-2 text-[11px] text-muted-foreground sm:grid-cols-2">
                    <div>
                      <dt className="text-foreground/80">Enviado</dt>
                      <dd>{formatDate(assignment.notified_at)}</dd>
                    </div>
                    <div>
                      <dt className="text-foreground/80">Limite</dt>
                      <dd>{formatDate(assignment.deadline_at)}</dd>
                    </div>
                  </dl>
                  <p className="mt-3">
                    {assignment.accepted_at ? (
                      <span className="text-emerald-300">
                        Aceito em {formatDate(assignment.accepted_at)}
                      </span>
                    ) : assignment.expired_at ? (
                      <span className="text-red-300">
                        Expirou em {formatDate(assignment.expired_at)}
                      </span>
                    ) : (
                      <span className="text-amber-200">Aguardando</span>
                    )}
                  </p>
                </article>
              ))}
            </div>
            <div className="hidden overflow-x-auto lg:block">
              <table className="w-full min-w-[850px] text-xs">
                <thead className="text-left text-[10px] uppercase tracking-wider text-muted-foreground">
                  <tr>
                    <th className="p-2">Lead</th>
                    <th className="p-2">Corretor</th>
                    <th className="p-2">Execução / rodada</th>
                    <th className="p-2">Enviado</th>
                    <th className="p-2">Limite</th>
                    <th className="p-2">Resultado</th>
                  </tr>
                </thead>
                <tbody>
                  {snapshot.leadAssignments.map((assignment) => (
                    <tr key={assignment.id} className="border-t border-white/5">
                      <td className="p-2 text-foreground">
                        {assignment.lead_name || assignment.lead_id}
                      </td>
                      <td className="p-2">
                        {displayBrokerName(assignment.broker_name) || assignment.broker_email}
                      </td>
                      <td className="p-2">
                        {assignment.run_number ?? 1} / {assignment.round_number ?? 1} · #
                        {assignment.attempt_number}
                      </td>
                      <td className="p-2">{formatDate(assignment.notified_at)}</td>
                      <td className="p-2">{formatDate(assignment.deadline_at)}</td>
                      <td className="p-2">
                        {assignment.accepted_at ? (
                          <span className="text-emerald-300">
                            Aceito em {formatDate(assignment.accepted_at)}
                          </span>
                        ) : assignment.expired_at ? (
                          <span className="text-red-300">
                            Expirou em {formatDate(assignment.expired_at)}
                          </span>
                        ) : (
                          <span className="text-amber-200">Aguardando</span>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </>
        )}
      </Panel>

      <div className="grid gap-5 xl:grid-cols-2">
        <Panel
          title="Atividades dos leads"
          subtitle="Mudanças de etapa e registros feitos pelos usuários."
        >
          {!snapshot.leadActivities.length ? (
            <EmptyState text="Nenhuma atividade de lead registrada." />
          ) : (
            <div className="max-h-[520px] space-y-2 overflow-y-auto pr-1">
              {snapshot.leadActivities.map((activity) => (
                <article key={activity.id} className="rounded-xl border border-white/8 p-3 text-xs">
                  <div className="flex justify-between gap-3">
                    <strong>{activity.stage}</strong>
                    <span className="text-muted-foreground">{formatDate(activity.created_at)}</span>
                  </div>
                  <p className="mt-1 text-muted-foreground">
                    Lead: {activity.lead_name} · por {activity.author_email || activity.author_name}
                  </p>
                  {activity.note && (
                    <p className="mt-2 leading-relaxed text-foreground/85">{activity.note}</p>
                  )}
                </article>
              ))}
            </div>
          )}
        </Panel>
        <Panel title="Agenda" subtitle="Demandas, compromissos, retornos e etapas de cartório.">
          {!snapshot.agendaEntries.length ? (
            <EmptyState text="Nenhum compromisso registrado." />
          ) : (
            <div className="max-h-[520px] space-y-2 overflow-y-auto pr-1">
              {snapshot.agendaEntries.map((entry) => (
                <article key={entry.id} className="rounded-xl border border-white/8 p-3 text-xs">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <strong className="capitalize">{entry.category.replaceAll("_", " ")}</strong>
                    <span className="text-muted-foreground">{formatDate(entry.scheduled_at)}</span>
                  </div>
                  <p className="mt-1 leading-relaxed text-foreground/85">{entry.observation}</p>
                  <p className="mt-2 text-muted-foreground">
                    Responsável: {entry.target_email} · criada por{" "}
                    {entry.creator_email || "sistema"}
                  </p>
                  {entry.feedback_at && (
                    <p className="mt-1 text-emerald-300">
                      Retorno em {formatDate(entry.feedback_at)}
                      {entry.feedback_note ? ` · ${entry.feedback_note}` : ""}
                    </p>
                  )}
                  {entry.cartorio_received_at && (
                    <p className="mt-1 text-muted-foreground">
                      Recebido no cartório: {formatDate(entry.cartorio_received_at)}
                    </p>
                  )}
                  {entry.cartorio_delivered_to_vitor_at && (
                    <p className="mt-1 text-muted-foreground">
                      Entregue ao Vitor: {formatDate(entry.cartorio_delivered_to_vitor_at)}
                    </p>
                  )}
                  {entry.cartorio_vitor_document_uploaded_at && (
                    <p className="mt-1 text-muted-foreground">
                      Digitalizado: {formatDate(entry.cartorio_vitor_document_uploaded_at)}
                    </p>
                  )}
                </article>
              ))}
            </div>
          )}
        </Panel>
      </div>
    </div>
  );
}

function ErrorsView({ errors }: { errors: AuditEvent[] }) {
  return (
    <Panel
      title="Erros registrados"
      subtitle="Falhas capturadas no navegador, integrações e rotinas do CRM."
    >
      {!errors.length ? (
        <div className="rounded-xl border border-emerald-400/15 bg-emerald-400/5 px-5 py-10 text-center">
          <CheckCircle2 className="mx-auto text-emerald-300" size={24} />
          <p className="mt-3 text-sm font-medium text-emerald-200">
            Nenhum erro registrado nesta seleção.
          </p>
        </div>
      ) : (
        <div className="space-y-3">
          {errors.map((error) => (
            <article
              key={error.id}
              className="rounded-xl border border-red-400/15 bg-red-400/[0.04] p-4"
            >
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <div className="flex items-center gap-2 text-red-300">
                    <AlertTriangle size={15} />
                    <strong className="text-sm">
                      {error.summary || eventLabels[error.event_type] || error.event_type}
                    </strong>
                  </div>
                  <p className="mt-2 text-xs leading-relaxed text-red-100">
                    {error.error_message || "Erro sem mensagem técnica."}
                  </p>
                  <p className="mt-2 text-[11px] text-muted-foreground">
                    Usuário: {displayAdministratorEmail(error.subject_email || error.actor_email) || "sistema"} · área:{" "}
                    {error.entity_type || error.category}
                  </p>
                </div>
                <span className="text-[11px] text-muted-foreground">
                  {formatDate(error.happened_at)}
                </span>
              </div>
              <DetailJson value={error.details} />
            </article>
          ))}
        </div>
      )}
    </Panel>
  );
}

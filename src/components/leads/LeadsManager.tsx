import {
  CalendarClock,
  CalendarDays,
  ChevronLeft,
  ChevronRight,
  CircleAlert,
  Eye,
  ExternalLink,
  FileDown,
  Loader2,
  MessageCircle,
  Paperclip,
  Pencil,
  RotateCcw,
  Search,
  SlidersHorizontal,
  Timer,
  Trash2,
  Users,
  X,
} from "lucide-react";
import { type FormEvent, useEffect, useMemo, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { Panel } from "@/components/dashboard/Panel";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { LeadCreateDialog } from "@/components/leads/LeadCreateDialog";
import { LeadProposalDocuments } from "@/components/leads/LeadProposalDocuments";
import {
  LEAD_PROGRESS_STAGES,
  type AccessProfile,
  type CompleteLeadRegistrationInput,
  type CreateLeadInput,
  type LeadActivity,
  type LeadTimelineEvent,
  type LeadQualificationInput,
  type LeadProgressStage,
  type ManagedLead,
} from "@/lib/lead-access";
import { displayBrokerName } from "@/lib/broker-names";
import { isAdministradorAdmin } from "@/lib/admin-access";
import { useAdministradorOperationalSettings } from "@/lib/operational-settings";
import { useDashboardData, type PropertyRow } from "@/lib/api";
import { supabase } from "@/lib/supabase";
import { displayText } from "@/lib/display-text";

const NO_PROPERTY_INTEREST = "NÃO TEM IMÓVEL DE INTERESSE AINDA";
const SIMPLIFIED_LEAD_FLOW = true;
const leadOrigins = [
  "DF Imóveis",
  "W Imóveis",
  "WhatsApp",
  "Telefone",
  "Instagram",
  "Facebook",
  "Site",
  "Indicação",
  "Ligação",
  "Outro",
];
const stages = [
  "Todos",
  "Aguardando atendimento",
  "Aguardando redistribuicao pelo Administrador",
  "Em atendimento",
  "Corretor",
  "Standby",
  "Aguardando imóvel similar",
  "Visita agendada",
  "Visita realizada",
  "Proposta",
  "Comprou",
  "Não teve interesse",
  "Telefone não existe",
  "Financiamento",
];
const colors: Record<string, string> = {
  "Aguardando atendimento": "text-rose-300 bg-rose-300/10",
  "Aguardando redistribuicao pelo Administrador": "text-amber-200 bg-amber-400/15",
  "Em atendimento": "text-sky-300 bg-sky-300/10",
  Corretor: "text-indigo-200 bg-indigo-300/10",
  Standby: "text-slate-300 bg-slate-300/10",
  "Aguardando imóvel similar": "text-yellow-200 bg-yellow-400/10",
  "Visita agendada": "text-amber-300 bg-amber-300/10",
  "Visita realizada": "text-violet-300 bg-violet-300/10",
  Proposta: "text-copper bg-copper/10",
  Comprou: "text-emerald-400 bg-emerald-400/10",
  "Não teve interesse": "text-rose-300 bg-rose-300/10",
  "Telefone não existe": "text-red-500 bg-red-500/10",
  Financiamento: "text-copper bg-copper/10",
};

function stageLabel(stage: string) {
  return stage === "Aguardando redistribuicao pelo Administrador"
    ? "Aguardando redistribuição pelo Administrador"
    : stage;
}

function isOutsideLeadQueueHours(now = new Date()) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Sao_Paulo",
    hour: "2-digit",
    hourCycle: "h23",
  }).formatToParts(now);
  const hour = Number(parts.find((part) => part.type === "hour")?.value ?? 0);

  return hour < 9 || hour >= 18;
}

function canReleasePendingLead(allyson: boolean, lead: ManagedLead) {
  if (!allyson || lead.assignmentStatus !== "pending") return false;

  const availableAt = lead.assignmentAvailableAt
    ? new Date(lead.assignmentAvailableAt).getTime()
    : Number.NaN;

  return isOutsideLeadQueueHours() || (Number.isFinite(availableAt) && availableAt > Date.now());
}

const registrationFieldLabels: Record<string, string> = {
  name: "Nome",
  phone: "Telefone",
  email: "E-mail",
  property_interest: "Imóvel de interesse",
  lead_type: "Finalidade",
  channel: "Origem",
  desired_property_value: "Média de valor do imóvel desejado",
  desired_location: "Localização desejada",
};

function registrationFieldLabel(field: string) {
  const normalized = field.trim().toLowerCase();
  return (
    registrationFieldLabels[normalized] ??
    normalized.replace(/_/g, " ").replace(/^./, (character) => character.toLocaleUpperCase("pt-BR"))
  );
}

export function LeadsManager({
  data = [],
  loading,
  error,
  onRetry,
  profile,
  brokers = [],
  onCreateLead,
  creating = false,
  onAssignLead,
  assigning = false,
  onCompleteRegistration,
  completingRegistration = false,
  onDeleteLead,
  deleting = false,
  onUpdateLeadProgress,
  updatingProgress = false,
  onExtendAttendance,
  extendingAttendance = false,
  onAddLeadObservation,
  addingLeadObservation = false,
  onEditLeadObservation,
  editingLeadObservation = false,
  onDeleteLeadObservation,
  deletingLeadObservation = false,
  onRestartExhaustedLead,
  restartingExhaustedLead = false,
  onStartSimilarPropertyOffer,
  startingSimilarPropertyOffer = false,
  onDismissSimilarPropertyMatches,
  dismissingSimilarPropertyMatches = false,
  activities = [],
  timelineEvents = [],
  onImportSheetLeads,
  importing = false,
}: {
  data?: ManagedLead[];
  loading: boolean;
  error?: Error | null;
  onRetry: () => void;
  profile?: AccessProfile;
  brokers?: AccessProfile[];
  onCreateLead?: (input: CreateLeadInput) => Promise<unknown>;
  creating?: boolean;
  onAssignLead?: (input: { leadId: string; ownerId: string }) => Promise<unknown>;
  assigning?: boolean;
  onCompleteRegistration?: (input: CompleteLeadRegistrationInput) => Promise<unknown>;
  completingRegistration?: boolean;
  onDeleteLead?: (leadId: string) => Promise<unknown>;
  deleting?: boolean;
  onUpdateLeadProgress?: (input: {
    leadId: string;
    stage: LeadProgressStage;
    visitScheduledAt?: string;
    companionUserId?: string;
    visitExecutorIds?: string[];
    note?: string;
    qualification?: LeadQualificationInput;
  }) => Promise<unknown>;
  updatingProgress?: boolean;
  onExtendAttendance?: (input: { leadId: string; note: string }) => Promise<unknown>;
  extendingAttendance?: boolean;
  onAddLeadObservation?: (input: { leadId: string; note: string }) => Promise<unknown>;
  addingLeadObservation?: boolean;
  onEditLeadObservation?: (input: { activityId: string; note: string }) => Promise<unknown>;
  editingLeadObservation?: boolean;
  onDeleteLeadObservation?: (activityId: string) => Promise<unknown>;
  deletingLeadObservation?: boolean;
  onRestartExhaustedLead?: (leadId: string) => Promise<unknown>;
  restartingExhaustedLead?: boolean;
  onStartSimilarPropertyOffer?: (input: { leadId: string; propertyId: string }) => Promise<unknown>;
  startingSimilarPropertyOffer?: boolean;
  onDismissSimilarPropertyMatches?: (leadId: string) => Promise<unknown>;
  dismissingSimilarPropertyMatches?: boolean;
  activities?: LeadActivity[];
  timelineEvents?: LeadTimelineEvent[];
  onImportSheetLeads?: () => Promise<number>;
  importing?: boolean;
}) {
  const [query, setQuery] = useState("");
  const [stage, setStage] = useState("Todos");
  const [brokerFilter, setBrokerFilter] = useState("Todos");
  const [redistributionOnly, setRedistributionOnly] = useState(false);
  const [page, setPage] = useState(1);
  const [viewingId, setViewingId] = useState<string>();
  const [deletingLead, setDeletingLead] = useState<ManagedLead>();
  const [deleteError, setDeleteError] = useState("");
  const [importMessage, setImportMessage] = useState("");
  const [restartMessage, setRestartMessage] = useState<{
    kind: "success" | "error";
    text: string;
  }>();
  const [restartingLeadId, setRestartingLeadId] = useState<string>();
  const [releasingLeadId, setReleasingLeadId] = useState<string>();
  const allyson = isAdministradorAdmin(profile);
  const operationalSettings = useAdministradorOperationalSettings(allyson);
  const { data: dashboard } = useDashboardData();
  const [propertyLinks, setPropertyLinks] = useState<Record<string, string>>({});
  const [viewRestored, setViewRestored] = useState(false);
  const restoredViewKey = useRef("");
  const filtersInitialized = useRef(false);
  const administrativeNotices = useMemo(() => {
    const notices = new Map<string, LeadActivity>();
    if (!allyson) return notices;
    for (const activity of activities) {
      if (!isAdministrativeObservation(activity) || notices.has(activity.leadId)) continue;
      notices.set(activity.leadId, activity);
    }
    return notices;
  }, [activities, allyson]);
  const canEditLeads = Boolean(
    onAssignLead || onCompleteRegistration || onUpdateLeadProgress || onExtendAttendance,
  );
  const canDeleteLeads = Boolean(onDeleteLead);
  const exhaustedLeadsCount = data.filter((lead) => lead.assignmentStatus === "exhausted").length;
  const viewing = useMemo(() => data.find((lead) => lead.id === viewingId), [data, viewingId]);
  const filtered = useMemo(
    () =>
      data
        .filter((lead) => {
          const term = query.trim().toLocaleLowerCase("pt-BR");
          const phoneTerm = query.replace(/\D/g, "");
          const leadPhones = [lead.telefone, ...lead.telefonesAdicionais];
          const brokerOnlySearch = term.length >= 3 && "sonialima".startsWith(term);
          const matchesText = (
            brokerOnlySearch
              ? [displayBrokerName(lead.corretor)]
              : [
                  lead.nome,
                  lead.segundoNome,
                  lead.imovel,
                  lead.canal,
                  lead.corretor,
                  displayBrokerName(lead.corretor),
                  lead.email,
                  lead.telefone,
                  ...lead.telefonesAdicionais,
                  lead.id,
                ]
          ).some((value) => value?.toLocaleLowerCase("pt-BR").includes(term));
          const matchesPhone =
            phoneTerm.length > 0 &&
            leadPhones.some((phone) => phone?.replace(/\D/g, "").includes(phoneTerm));

          const matchesBroker = brokerFilter === "Todos" || lead.ownerId === brokerFilter;

          return (
            (term.length > 0 || stage === "Todos" || lead.estagio === stage) &&
            (matchesText || matchesPhone) &&
            matchesBroker &&
            (!redistributionOnly || lead.assignmentStatus === "exhausted")
          );
        })
        .sort((left, right) =>
          String(right.atualizadoEm ?? "").localeCompare(String(left.atualizadoEm ?? ""), "pt-BR"),
        ),
    [data, query, stage, brokerFilter, redistributionOnly],
  );
  const pageSize = 10;
  const pages = Math.max(1, Math.ceil(filtered.length / pageSize));
  const rows = filtered.slice((page - 1) * pageSize, page * pageSize);
  const propertyUrl = (lead: ManagedLead) => {
    const interest = lead.imovel?.trim().toLocaleLowerCase("pt-BR");
    if (!interest || interest === NO_PROPERTY_INTEREST.toLocaleLowerCase("pt-BR")) return undefined;
    const property = dashboard?.imoveis.find((item) =>
      [item.titulo, item.endereco].some(
        (value) => value?.trim().toLocaleLowerCase("pt-BR") === interest,
      ),
    );
    return property?.id ? propertyLinks[property.id] : undefined;
  };
  useEffect(() => {
    void supabase
      .from("crm_property_public_links")
      .select("property_id, url")
      .then(({ data: links }) =>
        setPropertyLinks(
          Object.fromEntries((links ?? []).map((link) => [String(link.property_id), link.url])),
        ),
      );
  }, []);
  useEffect(() => {
    if (typeof window === "undefined") return;
    const key = `sonialima:leads-view:${profile?.id ?? "anonymous"}`;
    if (restoredViewKey.current === key || !data.length) return;
    restoredViewKey.current = key;
    try {
      const saved = JSON.parse(sessionStorage.getItem(key) ?? "null") as {
        query?: string;
        stage?: string;
        page?: number;
        viewingId?: string;
      } | null;
      if (saved) {
        setQuery(saved.query ?? "");
        setStage(saved.stage ?? "Todos");
        setPage(saved.page ?? 1);
        const rememberedLead = data.find((lead) => lead.id === saved.viewingId);
        if (rememberedLead) setViewingId(rememberedLead.id);
      }
    } catch {
      sessionStorage.removeItem(key);
    } finally {
      setViewRestored(true);
    }
  }, [data, profile?.id]);
  useEffect(() => {
    if (typeof window === "undefined" || !viewRestored) return;
    sessionStorage.setItem(
      `sonialima:leads-view:${profile?.id ?? "anonymous"}`,
      JSON.stringify({ query, stage, page, viewingId }),
    );
  }, [page, profile?.id, query, stage, viewingId, viewRestored]);
  useEffect(() => {
    if (!viewRestored) return;
    if (!filtersInitialized.current) {
      filtersInitialized.current = true;
      return;
    }
    setPage(1);
  }, [query, stage, redistributionOnly, viewRestored]);
  useEffect(() => {
    if (page > pages) setPage(pages);
  }, [page, pages]);
  useEffect(() => {
    if (!data.length || typeof window === "undefined") return;
    const leadId = new URLSearchParams(window.location.search).get("focusLeadId");
    if (!leadId) return;
    const lead = data.find((item) => item.id === leadId);
    if (lead) setViewingId(lead.id);
  }, [data]);
  const closeViewing = () => {
    setViewingId(undefined);
    if (typeof window === "undefined") return;
    const url = new URL(window.location.href);
    url.searchParams.delete("focusLeadId");
    window.history.replaceState({}, "", `${url.pathname}${url.search}${url.hash}`);
  };
  const importLeads = async () => {
    if (!onImportSheetLeads) return;
    setImportMessage("");
    try {
      const imported = await onImportSheetLeads();
      setImportMessage(
        imported
          ? `${imported} leads importados da planilha.`
          : "Todos os leads da planilha já foram importados.",
      );
    } catch (error) {
      setImportMessage(
        error instanceof Error ? error.message : "Não foi possível importar os leads.",
      );
    }
  };
  const deleteLead = async () => {
    if (!deletingLead || !onDeleteLead) return;
    setDeleteError("");
    try {
      await onDeleteLead(deletingLead.id);
      setDeletingLead(undefined);
      if (viewingId === deletingLead.id) setViewingId(undefined);
    } catch (error) {
      setDeleteError(error instanceof Error ? error.message : "Não foi possível excluir o lead.");
    }
  };
  const restartLeadQueue = async (lead: ManagedLead) => {
    if (!onRestartExhaustedLead) return;
    setRestartMessage(undefined);
    setRestartingLeadId(lead.id);
    try {
      await onRestartExhaustedLead(lead.id);
      setRestartMessage({
        kind: "success",
        text: `A esteira de ${lead.nome} foi iniciada novamente.`,
      });
    } catch (error) {
      setRestartMessage({
        kind: "error",
        text: error instanceof Error ? error.message : "Não foi possível reiniciar a esteira.",
      });
    } finally {
      setRestartingLeadId(undefined);
    }
  };

  const releaseScheduledLead = async (lead: ManagedLead) => {
    setRestartMessage(undefined);
    setReleasingLeadId(lead.id);
    try {
      const { error } = await supabase.rpc("allyson_release_scheduled_lead", {
        p_lead_id: lead.id,
      });
      if (error) throw error;
      setRestartMessage({
        kind: "success",
        text: `A liberação de ${lead.nome} foi antecipada.`,
      });
      onRetry();
    } catch (error) {
      setRestartMessage({
        kind: "error",
        text: error instanceof Error ? error.message : "Não foi possível liberar o lead.",
      });
    } finally {
      setReleasingLeadId(undefined);
    }
  };
  return (
    <>
      <section className="mb-8 anim-float-in">
        <div className="flex items-center gap-2 text-[11px] uppercase tracking-[0.24em] text-muted-foreground">
          <span className="h-1.5 w-1.5 rounded-full bg-copper shadow-[0_0_10px_var(--copper)]" />
          Central de relacionamento
        </div>
        <h1 className="mt-2 text-3xl font-semibold tracking-tight">
          Leads <span className="text-gradient-copper">imobiliários</span>
        </h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Oportunidades sincronizadas automaticamente com a operação comercial.
        </p>
      </section>
      <Panel
        title="Pipeline de leads"
        subtitle={`${filtered.length} oportunidade${filtered.length === 1 ? "" : "s"} encontrada${filtered.length === 1 ? "" : "s"}`}
      >
        <div className="mb-5 flex flex-wrap gap-2">
          <div className="relative min-w-[240px] flex-1">
            <Search
              className="absolute left-3 top-1/2 -translate-y-1/2 text-muted-foreground"
              size={16}
            />
            <input
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder="Buscar nome, telefone, e-mail, imóvel, canal ou corretor"
              className="w-full rounded-lg border border-white/10 bg-white/[0.03] py-2.5 pl-10 pr-9 text-sm outline-none focus:border-copper/50"
            />
            {query && (
              <button
                aria-label="Limpar busca"
                onClick={() => setQuery("")}
                className="absolute right-3 top-1/2 -translate-y-1/2 text-muted-foreground"
              >
                <X size={15} />
              </button>
            )}
          </div>
          <label className="flex items-center gap-2 rounded-lg border border-white/10 bg-white/[0.03] px-3">
            <SlidersHorizontal size={15} className="text-copper" />
            <select
              aria-label="Filtrar por estágio"
              value={stage}
              onChange={(event) => setStage(event.target.value)}
              className="bg-transparent py-2 text-sm outline-none"
            >
              {stages.map((item) => (
                <option key={item} value={item}>
                  {stageLabel(item)}
                </option>
              ))}
            </select>
          </label>
          {profile && brokers.length > 0 && (
            <label className="flex items-center gap-2 rounded-lg border border-white/10 bg-white/[0.03] px-3">
              <Users size={15} className="text-copper" />
              <select
                aria-label="Filtrar por corretor"
                value={brokerFilter}
                onChange={(event) => setBrokerFilter(event.target.value)}
                className="bg-transparent py-2 text-sm outline-none"
              >
                <option value="Todos">Todos corretores</option>
                {brokers.map((b) => (
                  <option key={b.id} value={b.id}>
                    {displayBrokerName(b.fullName)}
                  </option>
                ))}
              </select>
            </label>
          )}
          {allyson && onRestartExhaustedLead && (
            <Button
              type="button"
              variant={redistributionOnly ? "default" : "outline"}
              aria-pressed={redistributionOnly}
              onClick={() => {
                setRedistributionOnly((current) => !current);
                setQuery("");
                setStage("Todos");
                setBrokerFilter("Todos");
              }}
              title="Mostrar leads que precisam de uma nova rodada de distribuição"
            >
              <RotateCcw size={16} />
              Redistribuir ({exhaustedLeadsCount})
            </Button>
          )}
          {profile && onCreateLead && (
            <div className="ml-auto flex flex-wrap items-center justify-end gap-2">
              {allyson ? (
                <Button
                  type="button"
                  aria-pressed={Boolean(operationalSettings.query.data?.deferNewLeadsToNextDayNine)}
                  variant={
                    operationalSettings.query.data?.deferNewLeadsToNextDayNine
                      ? "default"
                      : "outline"
                  }
                  onClick={() =>
                    operationalSettings.deferredLeadsMutation.mutate(
                      !operationalSettings.query.data?.deferNewLeadsToNextDayNine,
                    )
                  }
                  disabled={
                    operationalSettings.query.isLoading ||
                    !operationalSettings.query.data ||
                    operationalSettings.deferredLeadsMutation.isPending
                  }
                  title="Quando ativo, todo novo lead entra na esteira somente às 9h do dia seguinte."
                >
                  {operationalSettings.deferredLeadsMutation.isPending ? (
                    <Loader2 size={16} className="animate-spin" />
                  ) : (
                    <CalendarClock size={16} />
                  )}
                  {operationalSettings.query.data?.deferNewLeadsToNextDayNine
                    ? "Amanhã às 9h: ativo"
                    : "Enviar amanhã às 9h"}
                </Button>
              ) : null}
              {profile.role === "admin" && onImportSheetLeads && (
                <Button variant="outline" onClick={() => void importLeads()} disabled={importing}>
                  {importing ? (
                    <Loader2 size={16} className="animate-spin" />
                  ) : (
                    <FileDown size={16} />
                  )}
                  Importar planilha
                </Button>
              )}
              <LeadCreateDialog
                owner={profile}
                isAdmin={isAdministradorAdmin(profile)}
                brokers={brokers}
                onCreate={onCreateLead}
                creating={creating}
              />
            </div>
          )}
          {importMessage && (
            <p
              className={`w-full text-xs ${importMessage.includes("não foi possível") || importMessage.includes("Apenas") ? "text-red-300" : "text-emerald-300"}`}
            >
              {importMessage}
            </p>
          )}
          {operationalSettings.deferredLeadsMutation.error ? (
            <p className="w-full text-xs text-red-300">
              Não foi possível alterar o horário dos novos leads:{" "}
              {operationalSettings.deferredLeadsMutation.error.message}
            </p>
          ) : null}
          {allyson && operationalSettings.query.error ? (
            <p className="w-full text-xs text-red-300">
              Não foi possível carregar o controle de envio às 9h:{" "}
              {operationalSettings.query.error.message}
            </p>
          ) : null}
          {restartMessage ? (
            <p
              className={`w-full text-xs ${restartMessage.kind === "error" ? "text-red-300" : "text-emerald-300"}`}
            >
              {restartMessage.text}
            </p>
          ) : null}
        </div>
        <div className="space-y-3 lg:hidden">
          {loading ? (
            Array.from({ length: 4 }).map((_, index) => (
              <div key={index} className="rounded-xl border border-white/5 p-4">
                <div className="skeleton h-5 w-2/3" />
                <div className="skeleton mt-3 h-4 w-full" />
                <div className="skeleton mt-2 h-4 w-4/5" />
              </div>
            ))
          ) : error ? (
            <div className="rounded-xl border border-white/5 px-4 py-10 text-center">
              <p className="text-sm text-muted-foreground">Não foi possível carregar os leads.</p>
              <p className="mt-2 break-words text-xs text-red-300">{displayText(error.message)}</p>
              <Button variant="outline" size="sm" className="mt-3" onClick={onRetry}>
                Tentar novamente
              </Button>
            </div>
          ) : rows.length === 0 ? (
            <div className="rounded-xl border border-white/5 px-4 py-10 text-center text-sm text-muted-foreground">
              Nenhum lead corresponde aos filtros atuais.
            </div>
          ) : (
            rows.map((lead, index) => (
              <article
                key={lead.id ?? `${lead.nome}-${index}`}
                className="rounded-xl border border-white/5 bg-white/[0.02] p-4"
              >
                <div className="flex min-w-0 items-start justify-between gap-3">
                  <div className="min-w-0">
                    <h3 className="break-words font-medium text-foreground">
                      {lead.nome}
                      {lead.segundoNome ? ` / ${lead.segundoNome}` : ""}
                    </h3>
                    <p className="mt-0.5 break-all font-mono text-[10px] text-muted-foreground">
                      {lead.id ?? "Sem identificador"}
                    </p>
                  </div>
                  <span
                    className={`shrink-0 rounded-full px-2 py-1 text-[10px] font-medium ${colors[lead.estagio] ?? colors["Em atendimento"]}`}
                  >
                    {stageLabel(lead.estagio)}
                  </span>
                </div>

                {administrativeNotices.get(lead.id) ? (
                  <AdministrativeNotice activity={administrativeNotices.get(lead.id)!} />
                ) : null}

                {!SIMPLIFIED_LEAD_FLOW && <div className="mt-2">
                  <LeadDeadlineTimer
                    availableAt={lead.assignmentAvailableAt}
                    deadline={lead.assignmentDeadlineAt}
                    assignmentStatus={lead.assignmentStatus}
                    stage={lead.estagio}
                    visitScheduledAt={lead.visitaAgendadaEm}
                    qualificationDeadline={lead.postAcceptanceQualificationDeadlineAt}
                    qualificationCompleted={Boolean(lead.postAcceptanceQualificationCompletedAt)}
                    qualificationExpired={Boolean(lead.postAcceptanceQualificationExpiredAt)}
                  />
                </div>}
                <PropertyMatchOffers
                  lead={lead}
                  onStart={onStartSimilarPropertyOffer}
                  starting={startingSimilarPropertyOffer}
                  onDismiss={onDismissSimilarPropertyMatches}
                  dismissing={dismissingSimilarPropertyMatches}
                />

                <dl className="mt-4 grid grid-cols-2 gap-x-3 gap-y-3 text-xs">
                  <MobileLeadDetail
                    label="Imóvel"
                    value={lead.imovel || "—"}
                    url={propertyUrl(lead)}
                  />
                  <MobileLeadDetail label="Finalidade" value={lead.tipoLead || "—"} />
                  <MobileLeadDetail label="Origem" value={lead.canal || "—"} />
                  <MobileLeadDetail
                    label="Corretor"
                    value={displayBrokerName(lead.corretor) || "—"}
                  />
                  <MobileLeadDetail label="E-mail" value={lead.email || "—"} />
                  <MobileLeadDetail
                    label="Valor"
                    value={
                      lead.valor
                        ? lead.valor.toLocaleString("pt-BR", {
                            style: "currency",
                            currency: "BRL",
                            maximumFractionDigits: 0,
                          })
                        : "—"
                    }
                  />
                  <MobileLeadDetail label="Observação" value={lead.observacoes || "—"} />
                </dl>

                {lead.telefone && (
                  <a
                    href={whatsAppLink(lead.telefone)}
                    target="_blank"
                    rel="noreferrer"
                    className="mt-4 flex w-full items-center justify-center gap-2 rounded-lg border border-emerald-400/30 bg-emerald-400/10 px-3 py-2.5 text-sm text-emerald-300 transition hover:bg-emerald-400/20"
                    title={`Abrir conversa com ${lead.nome}`}
                  >
                    <MessageCircle size={15} /> {lead.telefone}
                  </a>
                )}

                <div className="mt-4 flex flex-wrap items-center gap-2 border-t border-white/5 pt-3">
                  <Button variant="outline" size="sm" onClick={() => setViewingId(lead.id)}>
                    {canEditLeads ? <Pencil size={15} /> : <Eye size={15} />}
                    {canEditLeads ? "Editar" : "Visualizar"}
                  </Button>
                  {lead.estagio === "Proposta" && canEditLeads && (
                    <Button variant="outline" size="sm" onClick={() => setViewingId(lead.id)}>
                      <Paperclip size={15} /> Documentos
                    </Button>
                  )}
                  {lead.assignmentStatus === "exhausted" && onRestartExhaustedLead ? (
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => void restartLeadQueue(lead)}
                      disabled={restartingExhaustedLead}
                      title="Iniciar uma nova esteira com duas voltas"
                    >
                      {restartingLeadId === lead.id ? (
                        <Loader2 size={15} className="animate-spin" />
                      ) : (
                        <RotateCcw size={15} />
                      )}
                      Redistribuir
                    </Button>
                  ) : null}
                  {canReleasePendingLead(allyson, lead) ? (
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => void releaseScheduledLead(lead)}
                      disabled={releasingLeadId === lead.id}
                      title="Liberar agora para o corretor aceitar fora do horário"
                      className="border-sky-500/30 text-sky-300 hover:bg-sky-500/10 hover:text-sky-200"
                    >
                      {releasingLeadId === lead.id ? (
                        <Loader2 size={15} className="animate-spin" />
                      ) : (
                        <Timer size={15} />
                      )}
                      Liberar agora
                    </Button>
                  ) : null}
                  {(onAssignLead || canDeleteLeads) && (
                    <>
                      {onAssignLead && (
                        <Button variant="outline" size="sm" onClick={() => setViewingId(lead.id)}>
                          Transferir
                        </Button>
                      )}
                      {canDeleteLeads && (
                        <Button
                          variant="ghost"
                          size="sm"
                          onClick={() => setDeletingLead(lead)}
                          className="ml-auto text-red-300 hover:bg-red-400/10 hover:text-red-200"
                        >
                          <Trash2 size={15} /> Excluir
                        </Button>
                      )}
                    </>
                  )}
                </div>
              </article>
            ))
          )}
        </div>
        <div className="hidden overflow-x-auto rounded-xl border border-white/5 lg:block">
          <table className="w-full min-w-[1560px] text-sm">
            <thead>
              <tr className="bg-white/[0.02] text-left text-[10px] uppercase tracking-wider text-muted-foreground">
                <th className="min-w-[210px] px-4 py-3 font-medium">Lead</th>
                {["Imóvel", "Finalidade", "Estágio", "Origem", "Corretor"].map((label) => (
                  <th key={label} className="min-w-[130px] whitespace-nowrap px-4 py-3 font-medium">
                    {label}
                  </th>
                ))}
                <th className="min-w-[190px] whitespace-nowrap px-4 py-3 font-medium">Telefone</th>
                <th className="min-w-[120px] whitespace-nowrap px-4 py-3 font-medium">Valor</th>
                <th className="min-w-[180px]" />
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <Skeleton />
              ) : error ? (
                <tr>
                  <td colSpan={9} className="px-4 py-12 text-center">
                    <p className="text-sm text-muted-foreground">
                      Não foi possível carregar os leads.
                    </p>
                    <p className="mt-2 text-xs text-red-300">{displayText(error.message)}</p>
                    <Button variant="outline" size="sm" className="mt-3" onClick={onRetry}>
                      Tentar novamente
                    </Button>
                  </td>
                </tr>
              ) : rows.length === 0 ? (
                <tr>
                  <td colSpan={9} className="px-4 py-12 text-center text-sm text-muted-foreground">
                    Nenhum lead corresponde aos filtros atuais.
                  </td>
                </tr>
              ) : (
                rows.map((lead, index) => (
                  <tr
                    key={lead.id ?? `${lead.nome}-${index}`}
                    className="border-t border-white/5 transition hover:bg-white/[0.025]"
                  >
                    <td className="min-w-[210px] px-4 py-3">
                      <div className="font-medium">
                        {lead.nome}
                        {lead.segundoNome ? ` / ${lead.segundoNome}` : ""}
                      </div>
                      <div className="mt-0.5 font-mono text-[10px] text-muted-foreground">
                        {lead.id ?? "Sem identificador"}
                      </div>
                      {lead.observacoes ? (
                        <p className="mt-2 max-w-[280px] whitespace-pre-wrap text-xs leading-relaxed text-amber-100/80">
                          {lead.observacoes}
                        </p>
                      ) : null}
                      {administrativeNotices.get(lead.id) ? (
                        <AdministrativeNotice activity={administrativeNotices.get(lead.id)!} />
                      ) : null}
                    </td>
                    <td className="min-w-[150px] px-4 py-3 text-muted-foreground">
                      <PropertyInterest value={lead.imovel} url={propertyUrl(lead)} />
                    </td>
                    <td className="min-w-[130px] whitespace-nowrap px-4 py-3 text-muted-foreground">
                      {lead.tipoLead || "—"}
                    </td>
                    <td className="min-w-[170px] px-4 py-3">
                      <div className="flex min-w-[150px] flex-col items-start gap-1.5">
                        <span
                          className={`whitespace-nowrap rounded-full px-2 py-1 text-[10px] font-medium ${colors[lead.estagio] ?? colors["Em atendimento"]}`}
                        >
                          {stageLabel(lead.estagio)}
                        </span>
                        {!SIMPLIFIED_LEAD_FLOW && <LeadDeadlineTimer
                          availableAt={lead.assignmentAvailableAt}
                          deadline={lead.assignmentDeadlineAt}
                          assignmentStatus={lead.assignmentStatus}
                          stage={lead.estagio}
                          visitScheduledAt={lead.visitaAgendadaEm}
                          qualificationDeadline={lead.postAcceptanceQualificationDeadlineAt}
                          qualificationCompleted={Boolean(
                            lead.postAcceptanceQualificationCompletedAt,
                          )}
                          qualificationExpired={Boolean(lead.postAcceptanceQualificationExpiredAt)}
                        />}
                        <PropertyMatchOffers
                          lead={lead}
                          onStart={onStartSimilarPropertyOffer}
                          starting={startingSimilarPropertyOffer}
                          onDismiss={onDismissSimilarPropertyMatches}
                          dismissing={dismissingSimilarPropertyMatches}
                        />
                      </div>
                    </td>
                    <td className="min-w-[145px] px-4 py-3 text-muted-foreground">
                      {lead.canal || "—"}
                    </td>
                    <td className="min-w-[150px] whitespace-nowrap px-4 py-3 text-muted-foreground">
                      {displayBrokerName(lead.corretor) || "—"}
                    </td>
                    <td className="min-w-[190px] whitespace-nowrap px-4 py-3">
                      {lead.telefone ? (
                        <a
                          href={whatsAppLink(lead.telefone)}
                          target="_blank"
                          rel="noreferrer"
                          className="inline-flex items-center gap-2 rounded-lg border border-emerald-400/30 bg-emerald-400/10 px-2.5 py-1.5 text-xs text-emerald-300 transition hover:bg-emerald-400/20"
                          title={`Abrir conversa com ${lead.nome}`}
                        >
                          <MessageCircle size={14} /> {lead.telefone}
                        </a>
                      ) : (
                        "—"
                      )}
                    </td>
                    <td className="min-w-[120px] whitespace-nowrap px-4 py-3 font-medium tabular-nums">
                      {lead.valor
                        ? lead.valor.toLocaleString("pt-BR", {
                            style: "currency",
                            currency: "BRL",
                            maximumFractionDigits: 0,
                          })
                        : "—"}
                    </td>
                    <td className="min-w-[180px] px-4 py-3 text-right">
                      <div className="flex justify-end gap-1 whitespace-nowrap">
                        <Button
                          variant="ghost"
                          size="icon"
                          aria-label={`Editar ${lead.nome}`}
                          onClick={() => setViewingId(lead.id)}
                        >
                          <Pencil size={15} />
                        </Button>
                        {lead.estagio === "Proposta" && canEditLeads && (
                          <Button
                            variant="ghost"
                            size="icon"
                            aria-label={`Documentos da proposta de ${lead.nome}`}
                            title="Documentos da proposta"
                            onClick={() => setViewingId(lead.id)}
                          >
                            <Paperclip size={15} />
                          </Button>
                        )}
                        {lead.assignmentStatus === "exhausted" && onRestartExhaustedLead ? (
                          <Button
                            variant="outline"
                            size="icon"
                            aria-label={`Girar novamente a esteira de ${lead.nome}`}
                            title="Girar novamente na esteira"
                            onClick={() => void restartLeadQueue(lead)}
                            disabled={restartingExhaustedLead}
                          >
                            {restartingLeadId === lead.id ? (
                              <Loader2 size={15} className="animate-spin" />
                            ) : (
                              <RotateCcw size={15} />
                            )}
                          </Button>
                        ) : null}
                        {canReleasePendingLead(allyson, lead) ? (
                          <Button
                            variant="outline"
                            size="icon"
                            aria-label={`Liberar agora a esteira de ${lead.nome}`}
                            title="Liberar agora para o corretor aceitar fora do horário"
                            onClick={() => void releaseScheduledLead(lead)}
                            disabled={releasingLeadId === lead.id}
                            className="border-sky-500/30 text-sky-300 hover:bg-sky-500/10 hover:text-sky-200"
                          >
                            {releasingLeadId === lead.id ? (
                              <Loader2 size={15} className="animate-spin" />
                            ) : (
                              <Timer size={15} />
                            )}
                          </Button>
                        ) : null}
                        {(onAssignLead || canDeleteLeads) && (
                          <>
                            {onAssignLead && (
                              <Button
                                variant="outline"
                                size="sm"
                                aria-label={`Transferir ${lead.nome} para outro corretor`}
                                onClick={() => setViewingId(lead.id)}
                              >
                                Transferir
                              </Button>
                            )}
                            {canDeleteLeads && (
                              <Button
                                variant="ghost"
                                size="icon"
                                aria-label={`Excluir ${lead.nome}`}
                                title="Excluir lead"
                                onClick={() => setDeletingLead(lead)}
                                className="text-red-300 hover:bg-red-400/10 hover:text-red-200"
                              >
                                <Trash2 size={15} />
                              </Button>
                            )}
                          </>
                        )}
                      </div>
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
        <div className="mt-4 flex items-center justify-between gap-3 text-xs text-muted-foreground">
          <span>
            Mostrando {filtered.length ? (page - 1) * pageSize + 1 : 0}–
            {Math.min(page * pageSize, filtered.length)} de {filtered.length}
          </span>
          <div className="flex items-center gap-1">
            <Button
              variant="ghost"
              size="icon"
              disabled={page === 1}
              onClick={() => setPage((value) => value - 1)}
            >
              <ChevronLeft />
            </Button>
            <span className="px-2">
              Página {page} de {pages}
            </span>
            <Button
              variant="ghost"
              size="icon"
              disabled={page === pages}
              onClick={() => setPage((value) => value + 1)}
            >
              <ChevronRight />
            </Button>
          </div>
        </div>
      </Panel>
      <LeadViewDialog
        lead={viewing}
        propertyUrl={viewing ? propertyUrl(viewing) : undefined}
        propertyLinks={propertyLinks}
        properties={dashboard?.imoveis ?? []}
        onOpenChange={(open) => !open && closeViewing()}
        brokers={brokers}
        currentUserId={profile?.id}
        canAssign={Boolean(onAssignLead)}
        onAssign={onAssignLead}
        assigning={assigning}
        onCompleteRegistration={onCompleteRegistration}
        completingRegistration={completingRegistration}
        onUpdateProgress={onUpdateLeadProgress}
        updatingProgress={updatingProgress}
        onExtendAttendance={onExtendAttendance}
        extendingAttendance={extendingAttendance}
        onAddLeadObservation={onAddLeadObservation}
        addingLeadObservation={addingLeadObservation}
        onEditLeadObservation={onEditLeadObservation}
        editingLeadObservation={editingLeadObservation}
        onDeleteLeadObservation={onDeleteLeadObservation}
        deletingLeadObservation={deletingLeadObservation}
        onRestartExhaustedLead={onRestartExhaustedLead}
        restartingExhaustedLead={restartingExhaustedLead}
        timelineEvents={timelineEvents}
        showSystemTimelineEvents={allyson}
      />
      <Dialog
        open={Boolean(deletingLead)}
        onOpenChange={(open) => !open && setDeletingLead(undefined)}
      >
        <DialogContent className="glass-strong border-white/10 text-foreground sm:max-w-md">
          <DialogHeader>
            <DialogTitle>Excluir lead?</DialogTitle>
            <DialogDescription>
              {deletingLead?.nome} será removido do CRM e, se estiver vinculado, da planilha. Esta
              ação não pode ser desfeita.
            </DialogDescription>
          </DialogHeader>
          {deleteError && <p className="text-sm text-red-300">{deleteError}</p>}
          <div className="mt-3 flex justify-end gap-2">
            <Button
              variant="outline"
              onClick={() => setDeletingLead(undefined)}
              disabled={deleting}
            >
              Cancelar
            </Button>
            <Button
              onClick={() => void deleteLead()}
              disabled={deleting}
              className="bg-red-500 text-white hover:bg-red-600"
            >
              {deleting && <Loader2 size={15} className="animate-spin" />}
              Excluir definitivamente
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </>
  );
}
function LeadViewDialog({
  lead,
  propertyUrl,
  propertyLinks,
  properties,
  onOpenChange,
  brokers,
  currentUserId,
  canAssign,
  onAssign,
  assigning,
  onCompleteRegistration,
  completingRegistration,
  onUpdateProgress,
  updatingProgress,
  onExtendAttendance,
  extendingAttendance,
  onAddLeadObservation,
  addingLeadObservation,
  onEditLeadObservation,
  editingLeadObservation,
  onDeleteLeadObservation,
  deletingLeadObservation,
  onRestartExhaustedLead,
  restartingExhaustedLead,
  timelineEvents,
  showSystemTimelineEvents,
}: {
  lead?: ManagedLead;
  propertyUrl?: string;
  propertyLinks: Record<string, string>;
  properties: PropertyRow[];
  onOpenChange: (open: boolean) => void;
  brokers: AccessProfile[];
  currentUserId?: string;
  canAssign: boolean;
  onAssign?: (input: { leadId: string; ownerId: string }) => Promise<unknown>;
  assigning: boolean;
  onCompleteRegistration?: (input: CompleteLeadRegistrationInput) => Promise<unknown>;
  completingRegistration: boolean;
  onUpdateProgress?: (input: {
    leadId: string;
    stage: LeadProgressStage;
    visitScheduledAt?: string;
    companionUserId?: string;
    visitExecutorIds?: string[];
    note?: string;
    qualification?: LeadQualificationInput;
  }) => Promise<unknown>;
  updatingProgress: boolean;
  onExtendAttendance?: (input: { leadId: string; note: string }) => Promise<unknown>;
  extendingAttendance: boolean;
  onAddLeadObservation?: (input: { leadId: string; note: string }) => Promise<unknown>;
  addingLeadObservation: boolean;
  onEditLeadObservation?: (input: { activityId: string; note: string }) => Promise<unknown>;
  editingLeadObservation: boolean;
  onDeleteLeadObservation?: (activityId: string) => Promise<unknown>;
  deletingLeadObservation: boolean;
  onRestartExhaustedLead?: (leadId: string) => Promise<unknown>;
  restartingExhaustedLead: boolean;
  timelineEvents: LeadTimelineEvent[];
  showSystemTimelineEvents: boolean;
}) {
  const [ownerId, setOwnerId] = useState(lead?.ownerId ?? "");
  const [assignError, setAssignError] = useState("");
  const [progressStage, setProgressStage] = useState<LeadProgressStage>("Em atendimento");
  const [visitDate, setVisitDate] = useState("");
  const [visitTime, setVisitTime] = useState("");
  const [visitCompanionId, setVisitCompanionId] = useState("");
  const [visitExecutorIds, setVisitExecutorIds] = useState<string[]>(lead?.visitExecutorIds ?? []);
  const [progressError, setProgressError] = useState("");
  const [stepNote, setStepNote] = useState("");
  const [visitFollowUpNote, setVisitFollowUpNote] = useState("");
  const [attendanceNote, setAttendanceNote] = useState("");
  const [attendanceError, setAttendanceError] = useState("");
  const [administrativeNote, setAdministrativeNote] = useState("");
  const [administrativeNoteError, setAdministrativeNoteError] = useState("");
  const [hasPropertyToSell, setHasPropertyToSell] = useState<"" | "sim" | "nao">("");
  const [propertyToSellLocation, setPropertyToSellLocation] = useState("");
  const [propertyToSellValue, setPropertyToSellValue] = useState("");
  const [needsFinancing, setNeedsFinancing] = useState<"" | "sim" | "nao">("");
  const [willUseFgts, setWillUseFgts] = useState<"" | "sim" | "nao">("");
  const [bankingPresented, setBankingPresented] = useState<"" | "sim" | "nao">("");
  const [visitPropertyCaptured, setVisitPropertyCaptured] = useState<"" | "sim" | "nao">("");
  const [restartError, setRestartError] = useState("");
  const [registrationSuccess, setRegistrationSuccess] = useState("");
  const calendarInput = useRef<HTMLInputElement>(null);
  const visitScheduledAt = toDateTimeValue(visitDate, visitTime);
  const visitScheduleChanged =
    progressStage === "Visita agendada" &&
    Boolean(visitScheduledAt) &&
    Math.floor(new Date(visitScheduledAt).getTime() / 60_000) !==
      Math.floor(new Date(lead?.visitaAgendadaEm ?? "").getTime() / 60_000);
  const visitExecutorsChanged =
    progressStage === "Visita agendada" &&
    lead?.tipoLead === "Aluguel" &&
    JSON.stringify(visitExecutorIds) !== JSON.stringify(lead.visitExecutorIds ?? []);
  const hasProgressChanges =
    progressStage !== lead?.estagio ||
    visitScheduleChanged ||
    visitExecutorsChanged ||
    (progressStage === "Visita agendada" && Boolean(visitCompanionId));
  const [dialogNow, setDialogNow] = useState(() => Date.now());
  const progressDraftKey = lead?.id ? `sonialima:lead-progress-draft:${lead.id}` : "";
  const scheduledVisitTime = lead?.visitaAgendadaEm
    ? new Date(lead.visitaAgendadaEm).getTime()
    : Number.NaN;
  const visitHasStarted = !Number.isFinite(scheduledVisitTime) || scheduledVisitTime <= dialogNow;
  const selectableProgressStages = LEAD_PROGRESS_STAGES;

  useEffect(() => {
    if (!lead?.visitaAgendadaEm) return;
    const timer = window.setInterval(() => setDialogNow(Date.now()), 1_000);
    return () => window.clearInterval(timer);
  }, [lead?.visitaAgendadaEm]);

  useEffect(() => {
    setOwnerId(lead?.ownerId ?? "");
    setAssignError("");
    const savedLeadStage = LEAD_PROGRESS_STAGES.includes(lead?.estagio as LeadProgressStage)
      ? (lead?.estagio as LeadProgressStage)
      : "Em atendimento";
    const leadVisitTime = lead?.visitaAgendadaEm
      ? new Date(lead.visitaAgendadaEm).getTime()
      : Number.NaN;
    const leadVisitIsFuture = Number.isFinite(leadVisitTime) && leadVisitTime > Date.now();
    setProgressStage(
      leadVisitIsFuture && (savedLeadStage === "Visita realizada" || savedLeadStage === "Proposta")
        ? "Visita agendada"
        : savedLeadStage,
    );
    const [date, time] = splitDateTimeValue(toDateTimeLocal(lead?.visitaAgendadaEm));
    setVisitDate(date);
    setVisitTime(time);
    setVisitCompanionId("");
    setVisitExecutorIds(lead?.visitExecutorIds ?? []);
    setProgressError("");
    setStepNote("");
    setVisitFollowUpNote("");
    setAttendanceNote("");
    setAttendanceError("");
    setAdministrativeNote("");
    setAdministrativeNoteError("");
    setHasPropertyToSell(
      lead?.hasPropertyToSell === undefined ? "" : lead.hasPropertyToSell ? "sim" : "nao",
    );
    setPropertyToSellLocation(lead?.propertyToSellLocation ?? "");
    setPropertyToSellValue(lead?.propertyToSellValue ? String(lead.propertyToSellValue) : "");
    setNeedsFinancing(
      lead?.needsFinancing === undefined ? "" : lead.needsFinancing ? "sim" : "nao",
    );
    setWillUseFgts(lead?.willUseFgts === undefined ? "" : lead.willUseFgts ? "sim" : "nao");
    setBankingPresented(
      lead?.bankingCorrespondentPresented === undefined
        ? ""
        : lead.bankingCorrespondentPresented
          ? "sim"
          : "nao",
    );
    setVisitPropertyCaptured(
      lead?.visitPropertyCaptured === undefined ? "" : lead.visitPropertyCaptured ? "sim" : "nao",
    );
    setRestartError("");
    setRegistrationSuccess("");
    if (lead?.id) {
      try {
        const saved = JSON.parse(
          sessionStorage.getItem(`sonialima:lead-progress-draft:${lead.id}`) ?? "null",
        ) as {
          progressStage?: LeadProgressStage;
          visitDate?: string;
          visitTime?: string;
          stepNote?: string;
          visitFollowUpNote?: string;
          attendanceNote?: string;
        } | null;
        if (
          saved?.progressStage &&
          !(
            leadVisitIsFuture &&
            (saved.progressStage === "Visita realizada" || saved.progressStage === "Proposta")
          )
        ) {
          setProgressStage(saved.progressStage);
        }
        if (saved?.visitDate) setVisitDate(saved.visitDate);
        if (saved?.visitTime) setVisitTime(saved.visitTime);
        setStepNote(saved?.stepNote ?? "");
        setVisitFollowUpNote(saved?.visitFollowUpNote ?? "");
        setAttendanceNote(saved?.attendanceNote ?? "");
      } catch {
        sessionStorage.removeItem(`sonialima:lead-progress-draft:${lead.id}`);
      }
    }
  }, [
    lead?.bankingCorrespondentPresented,
    lead?.estagio,
    lead?.hasPropertyToSell,
    lead?.id,
    lead?.needsFinancing,
    lead?.ownerId,
    lead?.propertyToSellLocation,
    lead?.propertyToSellValue,
    lead?.visitPropertyCaptured,
    lead?.visitExecutorId,
    lead?.visitExecutorIds,
    lead?.visitaAgendadaEm,
    lead?.willUseFgts,
  ]);

  async function saveAdministrativeObservation() {
    if (!lead || !onAddLeadObservation) return;
    setAdministrativeNoteError("");
    try {
      await onAddLeadObservation({ leadId: lead.id, note: administrativeNote });
      setAdministrativeNote("");
    } catch (reason) {
      setAdministrativeNoteError(
        reason instanceof Error ? reason.message : "NÃ£o foi possÃ­vel salvar a observaÃ§Ã£o.",
      );
    }
  }

  useEffect(() => {
    if (!progressDraftKey) return;
    sessionStorage.setItem(
      progressDraftKey,
      JSON.stringify({
        progressStage,
        visitDate,
        visitTime,
        stepNote,
        visitFollowUpNote,
        attendanceNote,
      }),
    );
  }, [
    attendanceNote,
    progressDraftKey,
    progressStage,
    stepNote,
    visitDate,
    visitFollowUpNote,
    visitTime,
  ]);

  const assign = async () => {
    if (!lead || !onAssign || !ownerId) return;
    setAssignError("");
    try {
      await onAssign({ leadId: lead.id, ownerId });
    } catch (error) {
      setAssignError(error instanceof Error ? error.message : "Não foi possível atribuir o lead.");
    }
  };

  const updateProgress = async () => {
    if (!lead || !onUpdateProgress) return;
    setProgressError("");
    if (!SIMPLIFIED_LEAD_FLOW && progressStage === "Visita agendada" && !visitScheduledAt) {
      setProgressError("Informe uma data e um horário válidos para a visita.");
      return;
    }
    if (
      !SIMPLIFIED_LEAD_FLOW &&
      progressStage === "Visita agendada" &&
      lead.tipoLead === "Aluguel" &&
      visitExecutorIds.length === 0
    ) {
      setProgressError("Selecione ao menos um corretor para realizar a visita de aluguel.");
      return;
    }
    if (
      !SIMPLIFIED_LEAD_FLOW &&
      !visitHasStarted &&
      (progressStage === "Visita realizada" || progressStage === "Proposta")
    ) {
      setProgressError("A visita ainda não começou. Aguarde o horário agendado para avançar.");
      return;
    }
    const qualificationPending =
      Boolean(lead.postAcceptanceQualificationDeadlineAt) &&
      !lead.postAcceptanceQualificationCompletedAt &&
      !lead.postAcceptanceQualificationExpiredAt;
    const changingStage = progressStage !== lead.estagio;
    const requiresVisitAnswer =
      lead.commercialQualificationRequired &&
      lead.estagio === "Visita realizada" &&
      progressStage !== "Visita realizada" &&
      !visitPropertyCaptured;
    const shouldSaveVisitAnswer =
      Boolean(visitPropertyCaptured) &&
      (progressStage === "Visita realizada" || lead.estagio === "Visita realizada");
    if (!SIMPLIFIED_LEAD_FLOW && qualificationPending && changingStage) {
      setProgressError("Conclua a qualificação obrigatória antes de alterar a etapa do lead.");
      return;
    }
    if (
      !SIMPLIFIED_LEAD_FLOW &&
      lead.commercialQualificationRequired &&
      changingStage &&
      (!hasPropertyToSell || !needsFinancing || !willUseFgts || !bankingPresented)
    ) {
      setProgressError("Responda todas as perguntas da qualificação comercial.");
      return;
    }
    if (
      !SIMPLIFIED_LEAD_FLOW &&
      lead.commercialQualificationRequired &&
      changingStage &&
      hasPropertyToSell === "sim" &&
      (!propertyToSellLocation.trim() || Number(propertyToSellValue) <= 0)
    ) {
      setProgressError("Informe a localização e o valor do imóvel que o lead pretende vender.");
      return;
    }
    if (!SIMPLIFIED_LEAD_FLOW && requiresVisitAnswer && !visitPropertyCaptured) {
      setProgressError("Informe se o imóvel do cliente foi captado durante a visita.");
      return;
    }
    const qualification: LeadQualificationInput = {
      ...(hasPropertyToSell === "nao" ? { hasPropertyToSell: false } : {}),
      ...(hasPropertyToSell === "sim" &&
      propertyToSellLocation.trim() &&
      Number(propertyToSellValue) > 0
        ? {
            hasPropertyToSell: true,
            propertyToSellLocation,
            propertyToSellValue: Number(propertyToSellValue),
          }
        : {}),
      ...(needsFinancing ? { needsFinancing: needsFinancing === "sim" } : {}),
      ...(willUseFgts ? { willUseFgts: willUseFgts === "sim" } : {}),
      ...(bankingPresented ? { bankingCorrespondentPresented: bankingPresented === "sim" } : {}),
      ...(shouldSaveVisitAnswer ? { visitPropertyCaptured: visitPropertyCaptured === "sim" } : {}),
    };
    try {
      await onUpdateProgress({
        leadId: lead.id,
        stage: progressStage,
        visitScheduledAt: progressStage === "Visita agendada" ? visitScheduledAt : undefined,
        companionUserId:
          progressStage === "Visita agendada" && lead.tipoLead !== "Aluguel"
            ? visitCompanionId || undefined
            : undefined,
        visitExecutorIds:
          progressStage === "Visita agendada" && lead.tipoLead === "Aluguel"
            ? visitExecutorIds
            : undefined,
        note: stepNote,
        qualification: Object.keys(qualification).length ? qualification : undefined,
      });
      if (progressDraftKey) sessionStorage.removeItem(progressDraftKey);
    } catch (error) {
      setProgressError(
        error instanceof Error ? error.message : "Não foi possível atualizar a etapa.",
      );
    }
  };

  const acceptAttendance = async () => {
    if (!lead || !onUpdateProgress) return;
    setProgressError("");
    try {
      await onUpdateProgress({ leadId: lead.id, stage: "Em atendimento" });
      setProgressStage("Em atendimento");
    } catch (error) {
      setProgressError(error instanceof Error ? error.message : "Não foi possível assumir o lead.");
    }
  };

  const beginReschedule = () => {
    setProgressStage("Visita agendada");
    window.setTimeout(() => openCalendar(calendarInput.current), 0);
  };

  const completeVisitFollowUp = async () => {
    if (!lead || !onUpdateProgress) return;
    if (!visitHasStarted) {
      setProgressError("A visita ainda não começou. Aguarde o horário agendado para concluir.");
      return;
    }
    if (!visitFollowUpNote.trim()) {
      setProgressError("Descreva como foi a visita antes de concluir.");
      return;
    }
    if (!visitPropertyCaptured) {
      setProgressError("Informe se o imóvel do cliente foi captado durante a visita.");
      return;
    }
    setProgressError("");
    try {
      await onUpdateProgress({
        leadId: lead.id,
        stage: "Visita realizada",
        note: visitFollowUpNote,
        qualification: {
          hasPropertyToSell: lead.hasPropertyToSell ?? false,
          propertyToSellLocation: lead.propertyToSellLocation,
          propertyToSellValue: lead.propertyToSellValue,
          needsFinancing: lead.needsFinancing ?? false,
          willUseFgts: lead.willUseFgts ?? false,
          bankingCorrespondentPresented: lead.bankingCorrespondentPresented ?? false,
          visitPropertyCaptured: visitPropertyCaptured === "sim",
        },
      });
      setProgressStage("Visita realizada");
      setVisitFollowUpNote("");
      if (progressDraftKey) sessionStorage.removeItem(progressDraftKey);
    } catch (error) {
      setProgressError(
        error instanceof Error ? error.message : "Não foi possível registrar a visita.",
      );
    }
  };

  const extendAttendance = async () => {
    if (!lead || !onExtendAttendance) return;
    setAttendanceError("");
    try {
      await onExtendAttendance({ leadId: lead.id, note: attendanceNote });
      setAttendanceNote("");
      if (progressDraftKey) sessionStorage.removeItem(progressDraftKey);
    } catch (error) {
      setAttendanceError(
        error instanceof Error ? error.message : "Não foi possível renovar o atendimento.",
      );
    }
  };

  const restartExhaustedQueue = async () => {
    if (!lead || !onRestartExhaustedLead) return;
    setRestartError("");
    try {
      await onRestartExhaustedLead(lead.id);
    } catch (error) {
      setRestartError(
        error instanceof Error ? error.message : "Não foi possível reiniciar a esteira.",
      );
    }
  };

  return (
    <Dialog open={Boolean(lead)} onOpenChange={onOpenChange}>
      <DialogContent className="glass-strong max-h-[calc(100dvh-2rem)] overflow-y-auto border-white/10 text-foreground">
        <DialogHeader>
          <DialogTitle>
            {lead?.nome}
            {lead?.segundoNome ? ` / ${lead.segundoNome}` : ""}
          </DialogTitle>
          <DialogDescription>Detalhes do lead sincronizado pela API.</DialogDescription>
        </DialogHeader>
        {lead?.registrationMissingFields.length ? (
          <div className="space-y-3">
            <section className="rounded-xl border border-amber-400/30 bg-amber-400/10 p-4">
              <div className="flex items-center gap-2 text-sm font-semibold text-amber-100">
                <CircleAlert size={17} /> Cadastro incompleto
              </div>
              <p className="mt-1 text-xs text-amber-100/80">
                Complete os campos obrigatórios que ainda estão faltando:
              </p>
              <ul className="mt-3 flex flex-wrap gap-2">
                {lead.registrationMissingFields.map((field) => (
                  <li
                    key={field}
                    className="rounded-full border border-amber-300/20 bg-black/10 px-2.5 py-1 text-xs font-medium text-amber-50"
                  >
                    {registrationFieldLabel(field)}
                  </li>
                ))}
              </ul>
            </section>
          </div>
        ) : null}
        {registrationSuccess ? (
          <p className="rounded-lg border border-emerald-400/20 bg-emerald-400/10 px-3 py-2 text-sm text-emerald-200">
            {registrationSuccess}
          </p>
        ) : null}
        <dl className="grid grid-cols-2 gap-4 text-sm">
          <Detail label="Imóvel" value={lead?.imovel} url={propertyUrl} />
          <Detail label="Finalidade" value={lead?.tipoLead} />
          <Detail
            label="Valor desejado"
            value={
              lead?.valorDesejado
                ? lead.valorDesejado.toLocaleString("pt-BR", { style: "currency", currency: "BRL" })
                : undefined
            }
          />
          <Detail label="Localização desejada" value={lead?.localizacaoDesejada} />
          <Detail label="Estágio" value={lead?.estagio} />
          <Detail label="Origem" value={lead?.canal} />
          {lead?.sourceListingId ? (
            <Detail label="Código do anúncio" value={lead.sourceListingId} />
          ) : null}
          <Detail label="Corretor" value={displayBrokerName(lead?.corretor)} />
          <Detail
            label="E-mail"
            value={lead?.email}
            url={lead?.email ? `mailto:${lead.email}` : undefined}
          />
          <Detail label="Segundo nome" value={lead?.segundoNome} />
          <Detail
            label="Valor"
            value={
              lead?.valor
                ? lead.valor.toLocaleString("pt-BR", { style: "currency", currency: "BRL" })
                : undefined
            }
          />
        </dl>
        {lead && onCompleteRegistration ? (
          <CompleteLeadRegistrationForm
            key={lead.id}
            lead={lead}
            properties={properties}
            propertyLinks={propertyLinks}
            saving={completingRegistration}
            onComplete={onCompleteRegistration}
            onSaved={() => setRegistrationSuccess("Lead atualizado com sucesso.")}
          />
        ) : null}
        {lead?.estagio === "Proposta" && onUpdateProgress && (
          <LeadProposalDocuments leadId={lead.id} leadName={lead.nome} />
        )}
        {/* Fluxo simplificado: sem financiamento ou qualificação obrigatória. */}
        {lead?.assignmentStatus === "exhausted" && onRestartExhaustedLead ? (
          <section className="mt-5 rounded-xl border border-amber-400/30 bg-amber-400/10 p-4">
            <h3 className="text-sm font-semibold text-amber-100">Esteira esgotada</h3>
            <p className="mt-1 text-xs text-amber-100/80">
              A esteira completou duas voltas por todos os corretores elegíveis sem aceite. Uma nova
              execução começa pelo corretor da vez na fila e terá mais duas voltas.
            </p>
            {restartError ? <p className="mt-2 text-xs text-red-300">{restartError}</p> : null}
            <Button
              size="sm"
              className="mt-3 bg-copper text-white"
              onClick={() => void restartExhaustedQueue()}
              disabled={restartingExhaustedLead}
            >
              {restartingExhaustedLead ? <Loader2 size={14} className="animate-spin" /> : null}
              Girar lead novamente na esteira
            </Button>
          </section>
        ) : null}
        {(lead?.telefone ||
          lead?.telefonesAdicionais.length ||
          lead?.assignmentStatus === "pending") && (
          <div className="mt-5 flex flex-wrap gap-2 border-t border-white/10 pt-4">
            {lead &&
              [lead.telefone, ...lead.telefonesAdicionais].filter(Boolean).map((phone, index) => (
                <a
                  key={`${phone}-${index}`}
                  href={whatsAppLink(phone!)}
                  target="_blank"
                  rel="noreferrer"
                  className="inline-flex h-9 items-center gap-2 rounded-lg border border-emerald-400/30 bg-emerald-400/10 px-3 text-xs font-medium text-emerald-300 transition hover:bg-emerald-400/20"
                >
                  <MessageCircle size={14} />
                  {phone}
                </a>
              ))}
            {lead?.assignmentStatus === "pending" && lead.ownerId === currentUserId && (
              <Button
                size="sm"
                className="bg-copper text-white"
                onClick={() => void acceptAttendance()}
              >
                {lead.ownerEmail?.trim().toLocaleLowerCase("pt-BR") === "unassigned-institutional@example.invalid"
                  ? "Aceitar lead"
                  : "Estou em atendimento"}
              </Button>
            )}
            {lead?.assignmentStatus === "pending" && lead.ownerId !== currentUserId ? (
              <p className="w-full text-xs text-amber-200">
                Este lead aguarda o aceite de {lead.corretor}. Para assumir o controle diretamente,
                transfira-o para o corretor desejado.
              </p>
            ) : null}
          </div>
        )}
        {!SIMPLIFIED_LEAD_FLOW && lead?.estagio === "Em atendimento" &&
          lead.ownerEmail?.trim().toLocaleLowerCase("pt-BR") !== "unassigned-institutional@example.invalid" &&
          onExtendAttendance && (
            <section className="mt-5 border-t border-white/10 pt-4">
              <h3 className="text-sm font-medium text-foreground">Ainda em atendimento</h3>
              <p className="mt-1 text-xs text-muted-foreground">
                Registre o motivo para manter este lead por mais 24 horas.
              </p>
              <textarea
                value={attendanceNote}
                onChange={(event) => setAttendanceNote(event.target.value)}
                placeholder="Explique por que o atendimento ainda está em andamento."
                className="mt-3 min-h-24 w-full resize-y rounded-lg border border-white/10 bg-white/[0.03] px-3 py-2 text-sm text-foreground outline-none focus:border-copper/50"
              />
              {attendanceError && <p className="mt-2 text-xs text-red-300">{attendanceError}</p>}
              <Button
                size="sm"
                className="mt-3 bg-copper text-white"
                onClick={() => void extendAttendance()}
                disabled={extendingAttendance || !attendanceNote.trim()}
              >
                {extendingAttendance && <Loader2 size={14} className="animate-spin" />}
                Ainda em atendimento · +24h
              </Button>
            </section>
          )}
        {canAssign && onAssign && (
          <div className="mt-5 border-t border-white/10 pt-4">
            <label className="block text-xs text-muted-foreground">
              Transferir lead para
              <div className="mt-1.5 flex gap-2">
                <select
                  value={ownerId}
                  onChange={(event) => setOwnerId(event.target.value)}
                  className="min-w-0 flex-1 rounded-lg border border-white/10 bg-white/[0.03] px-3 py-2 text-sm text-foreground outline-none focus:border-copper/50"
                >
                  {brokers.map((broker) => (
                    <option key={broker.id} value={broker.id}>
                      {displayBrokerName(broker.fullName)}
                    </option>
                  ))}
                </select>
                <Button
                  size="sm"
                  className="bg-copper text-white"
                  onClick={() => void assign()}
                  disabled={assigning || !ownerId}
                >
                  {assigning && <Loader2 size={14} className="animate-spin" />}
                  {ownerId === lead?.ownerId && lead?.assignmentStatus === "pending"
                    ? "Atribuir direto"
                    : "Transferir"}
                </Button>
              </div>
            </label>
            {brokers.length === 0 && (
              <p className="mt-2 text-xs text-red-300">
                Cadastre ao menos um corretor para transferir.
              </p>
            )}
            {assignError && (
              <p role="alert" className="mt-2 text-xs text-red-300">
                {assignError}
              </p>
            )}
          </div>
        )}
        {!onUpdateProgress && lead && (
          <section className="mt-5 border-t border-white/10 pt-4">
            <h3 className="text-sm font-medium text-foreground">Etapa do lead</h3>
            <div className="mt-3 grid gap-3 sm:grid-cols-2">
              <ReadOnlyLeadField label="Etapa atual" value={lead.estagio || "—"} />
              <ReadOnlyLeadField
                label="Corretor responsável"
                value={displayBrokerName(lead.corretor) || "—"}
              />
            </div>
          </section>
        )}
        {onUpdateProgress && lead && (
          <section className="mt-5 border-t border-white/10 pt-4">
            <h3 className="text-sm font-medium text-foreground">Atualizar atendimento</h3>
            <p className="mt-1 text-xs text-muted-foreground">
              Registre a etapa atual desta oportunidade.
            </p>
            {!SIMPLIFIED_LEAD_FLOW && (lead?.visitaAgendadaEm || lead?.estagio === "Visita agendada") && (
              <Button
                type="button"
                variant="outline"
                size="sm"
                className="mt-3"
                onClick={beginReschedule}
              >
                <CalendarClock size={14} />
                Remarcar visita
              </Button>
            )}
            {!SIMPLIFIED_LEAD_FLOW && lead?.estagio === "Visita agendada" &&
              lead.visitaAgendadaEm &&
              new Date(lead.visitaAgendadaEm).getTime() <= dialogNow && (
                <section className="mt-4 rounded-xl border border-amber-300/20 bg-amber-300/[0.04] p-3">
                  <h4 className="text-sm font-medium text-amber-200">Como foi a visita?</h4>
                  <p className="mt-1 text-xs text-muted-foreground">
                    O horário da visita chegou. Registre o resultado para avançar o lead.
                  </p>
                  <textarea
                    value={visitFollowUpNote}
                    onChange={(event) => setVisitFollowUpNote(event.target.value)}
                    placeholder="Conte como foi a visita, o interesse do cliente e os próximos passos."
                    className="mt-3 min-h-24 w-full resize-y rounded-lg border border-white/10 bg-white/[0.03] px-3 py-2 text-sm text-foreground outline-none focus:border-copper/50"
                  />
                  <div className="mt-3">
                    <YesNoChoice
                      label="O imóvel do cliente foi captado durante a visita?"
                      value={visitPropertyCaptured}
                      onChange={setVisitPropertyCaptured}
                    />
                  </div>
                  <Button
                    size="sm"
                    className="mt-3 bg-copper text-white hover:bg-copper/90"
                    onClick={() => void completeVisitFollowUp()}
                    disabled={
                      updatingProgress || !visitFollowUpNote.trim() || !visitPropertyCaptured
                    }
                  >
                    {updatingProgress && <Loader2 size={14} className="animate-spin" />}
                    Registrar visita realizada
                  </Button>
                </section>
              )}
            <div className="mt-3 grid gap-3 sm:grid-cols-2">
              <label className="block text-xs text-muted-foreground">
                Etapa
                <select
                  value={progressStage}
                  onChange={(event) => setProgressStage(event.target.value as LeadProgressStage)}
                  disabled={false}
                  className="mt-1.5 w-full rounded-lg border border-white/10 bg-white/[0.03] px-3 py-2 text-sm text-foreground outline-none focus:border-copper/50"
                >
                  {selectableProgressStages.map((stage) => (
                    <option key={stage} value={stage}>
                      {stage}
                    </option>
                  ))}
                </select>
              </label>
              <label className="block text-xs text-muted-foreground">
                Corretor responsável
                <div className="mt-1.5 flex min-h-10 items-center rounded-lg border border-white/10 bg-white/[0.03] px-3 py-2 text-sm text-foreground">
                  {displayBrokerName(lead.corretor) || "—"}
                </div>
              </label>
              {progressStage === "Visita agendada" && (
                <div className="grid grid-cols-[minmax(0,1fr)_auto_minmax(96px,0.55fr)] items-end gap-2 sm:col-span-2">
                  <label className="block min-w-0 text-xs text-muted-foreground">
                    Data da visita
                    <input
                      value={visitDate}
                      onChange={(event) => setVisitDate(formatBrDate(event.target.value))}
                      inputMode="numeric"
                      placeholder="22/02/2026"
                      maxLength={10}
                      className="mt-1.5 w-full rounded-lg border border-white/10 bg-white/[0.03] px-3 py-2 text-sm text-foreground outline-none focus:border-copper/50"
                    />
                  </label>
                  <button
                    type="button"
                    aria-label="Abrir calendário"
                    title="Abrir calendário"
                    onClick={() => openCalendar(calendarInput.current)}
                    className="mb-0.5 grid h-10 w-10 place-items-center rounded-lg border border-white/10 bg-white/[0.03] text-copper transition hover:border-copper/50"
                  >
                    <CalendarDays size={17} />
                  </button>
                  <input
                    ref={calendarInput}
                    type="date"
                    tabIndex={-1}
                    aria-hidden="true"
                    value={brDateToIso(visitDate) ?? ""}
                    onChange={(event) => setVisitDate(isoDateToBr(event.target.value))}
                    className="sr-only"
                  />
                  <label className="block text-xs text-muted-foreground">
                    Hora
                    <input
                      type="time"
                      value={visitTime}
                      onChange={(event) => setVisitTime(event.target.value)}
                      className="mt-1.5 w-full rounded-lg border border-white/10 bg-white/[0.03] px-3 py-2 text-sm text-foreground outline-none focus:border-copper/50"
                    />
                  </label>
                  <label className="col-span-3 block text-xs text-muted-foreground">
                    {lead.tipoLead === "Aluguel"
                      ? "Corretores que farão a visita *"
                      : "Corretor acompanhante (opcional)"}
                    {lead.tipoLead === "Aluguel" ? (
                      <div className="mt-1.5 grid gap-2 rounded-lg border border-white/10 bg-white/[0.03] p-2 sm:grid-cols-2">
                        {brokers.map((broker) => {
                          const checked = visitExecutorIds.includes(broker.id);
                          return (
                            <label
                              key={broker.id}
                              className={`flex cursor-pointer items-center gap-2 rounded-md border px-3 py-2 text-sm transition ${checked ? "border-copper/60 bg-copper/15 text-foreground" : "border-white/5 text-muted-foreground hover:border-white/15"}`}
                            >
                              <input
                                type="checkbox"
                                checked={checked}
                                onChange={() =>
                                  setVisitExecutorIds((current) =>
                                    checked
                                      ? current.filter((id) => id !== broker.id)
                                      : [...current, broker.id],
                                  )
                                }
                                className="accent-copper"
                              />
                              {broker.fullName || broker.email}
                            </label>
                          );
                        })}
                      </div>
                    ) : (
                      <select
                        value={visitCompanionId}
                        onChange={(event) => setVisitCompanionId(event.target.value)}
                        className="mt-1.5 w-full rounded-lg border border-white/10 bg-white/[0.03] px-3 py-2 text-sm text-foreground outline-none focus:border-copper/50"
                      >
                        <option value="">Sem acompanhante</option>
                        {brokers
                          .filter((broker) => broker.id !== lead.ownerId)
                          .map((broker) => (
                            <option key={broker.id} value={broker.id}>
                              {broker.fullName || broker.email}
                            </option>
                          ))}
                      </select>
                    )}
                    {lead.tipoLead === "Aluguel" && visitExecutorIds.length ? (
                      <span className="mt-1.5 block text-amber-300">
                        O lead continuará na carteira de {lead.corretor || "seu responsável"}; todos
                        os corretores selecionados ocuparão a agenda neste mesmo horário.
                      </span>
                    ) : visitCompanionId ? (
                      <span className="mt-1.5 block text-amber-300">
                        O acompanhante entrará nas duas agendas após aprovação de Administrador ou
                        acessocrm.
                      </span>
                    ) : null}
                  </label>
                </div>
              )}
            </div>
            {!SIMPLIFIED_LEAD_FLOW && lead.estagio === "Em atendimento" ? (
              <section className="mt-4 rounded-xl border border-amber-300/20 bg-amber-300/[0.04] p-4">
                <h4 className="text-sm font-semibold text-amber-100">
                  Qualificação comercial obrigatória
                </h4>
                <p className="mt-1 text-xs text-muted-foreground">
                  Para concluir o atendimento nesta etapa, registre as informações comerciais
                  abaixo.
                </p>
                <div className="mt-4 space-y-4">
                  <YesNoChoice
                    label="O lead possui imóvel para venda?"
                    value={hasPropertyToSell}
                    onChange={setHasPropertyToSell}
                  />
                  {hasPropertyToSell === "sim" ? (
                    <div className="grid gap-3 sm:grid-cols-2">
                      <label className="text-xs text-muted-foreground">
                        Localização do imóvel *
                        <input
                          value={propertyToSellLocation}
                          onChange={(event) => setPropertyToSellLocation(event.target.value)}
                          className="mt-1.5 w-full rounded-lg border border-white/10 bg-white/[0.03] px-3 py-2 text-sm text-foreground outline-none focus:border-copper/50"
                        />
                      </label>
                      <label className="text-xs text-muted-foreground">
                        Valor estimado do imóvel *
                        <input
                          type="number"
                          min="1"
                          value={propertyToSellValue}
                          onChange={(event) => setPropertyToSellValue(event.target.value)}
                          className="mt-1.5 w-full rounded-lg border border-white/10 bg-white/[0.03] px-3 py-2 text-sm text-foreground outline-none focus:border-copper/50"
                        />
                      </label>
                    </div>
                  ) : null}
                  <YesNoChoice
                    label="O lead necessita de financiamento?"
                    value={needsFinancing}
                    onChange={setNeedsFinancing}
                  />
                  <YesNoChoice
                    label="O lead pretende utilizar o FGTS?"
                    value={willUseFgts}
                    onChange={setWillUseFgts}
                  />
                  <YesNoChoice
                    label="A empresa já foi apresentada como correspondente bancária?"
                    value={bankingPresented}
                    onChange={setBankingPresented}
                  />
                </div>
              </section>
            ) : null}
            {!SIMPLIFIED_LEAD_FLOW && (progressStage === "Visita realizada" || lead.estagio === "Visita realizada") ? (
              <section className="mt-4 rounded-xl border border-violet-300/20 bg-violet-300/[0.04] p-4">
                <h4 className="text-sm font-semibold text-violet-100">Resultado da visita</h4>
                <div className="mt-3">
                  <YesNoChoice
                    label="O imóvel do cliente foi captado durante a visita?"
                    value={visitPropertyCaptured}
                    onChange={setVisitPropertyCaptured}
                  />
                </div>
              </section>
            ) : null}
            <label className="mt-3 block text-xs text-muted-foreground">
              {!SIMPLIFIED_LEAD_FLOW && progressStage === "Visita realizada"
                ? "Observação da visita *"
                : progressStage === "Standby"
                  ? "Motivo do standby *"
                  : progressStage === "Aguardando imóvel similar"
                    ? "Observação do imóvel aguardado *"
                    : "Observação desta etapa"}
              <textarea
                value={stepNote}
                onChange={(event) => setStepNote(event.target.value)}
                placeholder={
                  progressStage === "Visita realizada"
                    ? "Descreva o que aconteceu na visita."
                    : progressStage === "Standby"
                      ? "Explique por que este lead ficará em standby."
                      : progressStage === "Aguardando imóvel similar"
                        ? "Descreva o perfil, localização ou detalhe do imóvel que o cliente aguarda."
                        : "Registre um detalhe importante desta atualização."
                }
                className="mt-1.5 min-h-24 w-full resize-y rounded-lg border border-white/10 bg-white/[0.03] px-3 py-2 text-sm text-foreground outline-none focus:border-copper/50"
              />
            </label>
            {(["Standby", "Não teve interesse", "Aguardando imóvel similar"] as string[]).includes(
              progressStage,
            ) && (
              <p className="mt-3 rounded-lg border border-copper/20 bg-copper/[0.06] px-3 py-2 text-xs text-muted-foreground">
                Ao salvar, o corretor responsável será avisado quando entrar um imóvel na mesma
                região por até R$ 50 mil acima do valor desejado pelo lead.
              </p>
            )}
            {progressError && (
              <p role="alert" className="mt-2 text-xs text-red-300">
                {progressError}
              </p>
            )}
            <Button
              size="sm"
              className="mt-3 bg-copper text-white hover:bg-copper/90"
              onClick={() => void updateProgress()}
              disabled={updatingProgress || !hasProgressChanges}
            >
              {updatingProgress && <Loader2 size={14} className="animate-spin" />}
              {progressStage === "Standby"
                ? "Colocar em standby"
                : progressStage === "Aguardando imóvel similar"
                  ? "Aguardar imóvel similar"
                  : "Salvar etapa"}
            </Button>
          </section>
        )}
        {lead && onAddLeadObservation && (
          <section className="mt-5 border-t border-white/10 pt-4">
            <h3 className="text-sm font-medium text-foreground">
              {"Adicionar observa\u00e7\u00e3o"}
            </h3>
            <p className="mt-1 text-xs text-muted-foreground">
              {
                "A observa\u00e7\u00e3o ser\u00e1 adicionada ao hist\u00f3rico sem alterar a etapa do lead."
              }
            </p>
            <textarea
              value={administrativeNote}
              onChange={(event) => setAdministrativeNote(event.target.value)}
              placeholder={"Escreva uma observa\u00e7\u00e3o sobre este lead."}
              className="mt-3 min-h-24 w-full rounded-lg border border-white/10 bg-white/[0.03] px-3 py-2 text-sm text-foreground outline-none focus:border-copper/50"
            />
            {administrativeNoteError && (
              <p role="alert" className="mt-2 text-xs text-red-300">
                {administrativeNoteError}
              </p>
            )}
            <Button
              size="sm"
              className="mt-3"
              disabled={addingLeadObservation || !administrativeNote.trim()}
              onClick={() => void saveAdministrativeObservation()}
            >
              {addingLeadObservation && <Loader2 size={14} className="animate-spin" />}
              {"Salvar observa\u00e7\u00e3o"}
            </Button>
          </section>
        )}
        <LeadActivityHistory
          activities={timelineEvents.filter((activity) => activity.leadId === lead?.id)}
          showSystemEvents={showSystemTimelineEvents}
          onEdit={onEditLeadObservation}
          editing={editingLeadObservation}
          onDelete={onDeleteLeadObservation}
          deleting={deletingLeadObservation}
        />
      </DialogContent>
    </Dialog>
  );
}

type CompleteLeadRegistrationDraft = {
  nome: string;
  segundoNome: string;
  telefone: string;
  telefone2: string;
  telefone3: string;
  email: string;
  imovel: string;
  tipoLead: string;
  valorDesejado: string;
  localizacaoDesejada: string;
  canal: string;
  observacoes: string;
};

function CompleteLeadRegistrationForm({
  lead,
  properties,
  propertyLinks,
  saving,
  onComplete,
  onSaved,
}: {
  lead: ManagedLead;
  properties: PropertyRow[];
  propertyLinks: Record<string, string>;
  saving: boolean;
  onComplete: (input: CompleteLeadRegistrationInput) => Promise<unknown>;
  onSaved: () => void;
}) {
  const draftKey = `sonialima:lead-edit-draft:${lead.id}`;
  const [form, setForm] = useState<CompleteLeadRegistrationDraft>(() => {
    const initial: CompleteLeadRegistrationDraft = {
      nome: lead.nome,
      segundoNome: lead.segundoNome ?? "",
      telefone: lead.telefone ?? "",
      telefone2: lead.telefonesAdicionais[0] ?? "",
      telefone3: lead.telefonesAdicionais[1] ?? "",
      email: lead.email ?? "",
      imovel: lead.imovel ?? "",
      tipoLead: lead.tipoLead ?? "",
      valorDesejado: lead.valorDesejado ? String(lead.valorDesejado) : "",
      localizacaoDesejada: lead.localizacaoDesejada ?? "",
      canal: lead.canal ?? "",
      observacoes: lead.observacoes ?? "",
    };
    try {
      const saved = JSON.parse(
        sessionStorage.getItem(draftKey) ?? "null",
      ) as Partial<CompleteLeadRegistrationDraft> | null;
      return saved ? { ...initial, ...saved } : initial;
    } catch {
      return initial;
    }
  });
  const [error, setError] = useState("");
  const [showPropertyOptions, setShowPropertyOptions] = useState(false);
  const propertyPicker = useRef<HTMLLabelElement>(null);
  const inputClass =
    "mt-1.5 h-10 w-full rounded-lg border border-white/10 bg-white/[0.03] px-3 text-sm text-foreground outline-none focus:border-copper/50";

  const updateField = (field: keyof typeof form, value: string) => {
    setForm((current) => ({ ...current, [field]: value }));
  };
  useEffect(() => {
    sessionStorage.setItem(draftKey, JSON.stringify(form));
  }, [draftKey, form]);
  useEffect(() => {
    const closeOptions = (event: PointerEvent) => {
      if (!propertyPicker.current?.contains(event.target as Node)) setShowPropertyOptions(false);
    };
    document.addEventListener("pointerdown", closeOptions);
    return () => document.removeEventListener("pointerdown", closeOptions);
  }, []);

  const normalizedPropertyQuery = form.imovel.trim().toLocaleLowerCase("pt-BR");
  const filteredProperties = properties.filter(
    (property) =>
      !normalizedPropertyQuery ||
      [property.titulo, property.endereco, property.bairro, property.cidade].some((value) =>
        value?.toLocaleLowerCase("pt-BR").includes(normalizedPropertyQuery),
      ),
  );

  const save = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setError("");
    try {
      await onComplete({
        leadId: lead.id,
        nome: form.nome,
        segundoNome: form.segundoNome,
        telefone: form.telefone,
        telefonesAdicionais: [form.telefone2, form.telefone3]
          .map((phone) => phone.trim())
          .filter(Boolean),
        email: form.email,
        imovel: form.imovel,
        tipoLead: form.tipoLead as CompleteLeadRegistrationInput["tipoLead"],
        valorDesejado: Number(form.valorDesejado),
        localizacaoDesejada: form.localizacaoDesejada,
        canal: form.canal,
        observacoes: form.observacoes,
      });
      sessionStorage.removeItem(draftKey);
      onSaved();
    } catch (saveError) {
      setError(
        saveError instanceof Error ? saveError.message : "Não foi possível completar o cadastro.",
      );
    }
  };

  return (
    <form
      onSubmit={(event) => void save(event)}
      className="rounded-xl border border-white/10 bg-white/[0.02] p-4"
    >
      <h3 className="text-sm font-semibold text-foreground">Editar dados do lead</h3>
      <p className="mt-1 text-xs text-muted-foreground">
        Revise os dados atuais e preencha o que estiver faltando.
      </p>
      <div className="mt-4 grid gap-3 sm:grid-cols-2">
        <label className="text-xs text-muted-foreground">
          Nome *
          <input
            required
            value={form.nome}
            onChange={(event) => updateField("nome", event.target.value)}
            className={inputClass}
          />
        </label>
        <label className="text-xs text-muted-foreground">
          Segundo nome (opcional)
          <input
            value={form.segundoNome}
            onChange={(event) => updateField("segundoNome", event.target.value)}
            className={inputClass}
            placeholder="Acrescente sem apagar o nome original"
          />
        </label>
        <label className="text-xs text-muted-foreground">
          Telefone *
          <input
            required
            type="tel"
            value={form.telefone}
            onChange={(event) => updateField("telefone", event.target.value)}
            className={inputClass}
          />
        </label>
        <label className="text-xs text-muted-foreground">
          Telefone 2 (opcional)
          <input
            type="tel"
            value={form.telefone2}
            onChange={(event) => updateField("telefone2", event.target.value)}
            className={inputClass}
          />
        </label>
        <label className="text-xs text-muted-foreground">
          Telefone 3 (opcional)
          <input
            type="tel"
            value={form.telefone3}
            onChange={(event) => updateField("telefone3", event.target.value)}
            className={inputClass}
          />
        </label>
        <label className="text-xs text-muted-foreground">
          E-mail (opcional)
          <input
            type="email"
            value={form.email}
            onChange={(event) => updateField("email", event.target.value)}
            className={inputClass}
          />
        </label>
        <label ref={propertyPicker} className="relative text-xs text-muted-foreground">
          Imóvel de interesse *
          <input
            required
            value={form.imovel}
            onChange={(event) => {
              updateField("imovel", event.target.value);
              setShowPropertyOptions(true);
            }}
            onFocus={() => setShowPropertyOptions(true)}
            className={inputClass}
            placeholder="Digite o endereço para buscar"
            autoComplete="off"
          />
          {showPropertyOptions && (
            <div className="absolute z-50 mt-1 max-h-72 w-full overflow-y-auto rounded-xl border border-white/10 bg-popover p-1.5 text-popover-foreground shadow-2xl">
              <button
                type="button"
                className="w-full rounded-lg border-b border-white/10 px-2 py-2 text-left text-sm font-semibold text-copper hover:bg-white/[0.06]"
                onClick={() => {
                  updateField("imovel", NO_PROPERTY_INTEREST);
                  setShowPropertyOptions(false);
                }}
              >
                {NO_PROPERTY_INTEREST}
              </button>
              {filteredProperties.map((property) => (
                <div
                  key={property.id ?? `${property.titulo}:${property.endereco ?? ""}`}
                  className="flex items-center gap-2 rounded-lg px-2 py-2 hover:bg-white/[0.06]"
                >
                  <button
                    type="button"
                    className="min-w-0 flex-1 text-left"
                    onClick={() => {
                      updateField("imovel", property.titulo.trim());
                      setShowPropertyOptions(false);
                    }}
                  >
                    <span className="block truncate text-sm font-medium text-foreground">
                      {property.endereco || property.titulo}
                    </span>
                    <span className="mt-0.5 block truncate text-[11px] text-muted-foreground">
                      {[property.bairro, property.cidade].filter(Boolean).join(" · ") ||
                        "Bairro não informado"}
                    </span>
                    <span className="mt-0.5 block text-[11px] font-medium text-emerald-300">
                      {property.valor
                        ? property.valor.toLocaleString("pt-BR", {
                            style: "currency",
                            currency: "BRL",
                            maximumFractionDigits: 0,
                          })
                        : "Valor não informado"}
                    </span>
                  </button>
                  {propertyLinks[property.id ?? ""] ? (
                    <a
                      href={propertyLinks[property.id ?? ""]}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="inline-flex shrink-0 items-center gap-1 rounded-md border border-copper/30 px-2 py-1.5 text-[11px] font-medium text-copper hover:bg-copper/10"
                      onClick={(event) => event.stopPropagation()}
                    >
                      <ExternalLink size={13} /> Abrir
                    </a>
                  ) : (
                    <span className="shrink-0 px-2 text-[10px] text-muted-foreground">
                      Sem link
                    </span>
                  )}
                </div>
              ))}
              {filteredProperties.length === 0 && (
                <p className="px-3 py-3 text-xs text-muted-foreground">Nenhum imóvel encontrado.</p>
              )}
            </div>
          )}
        </label>
        <label className="text-xs text-muted-foreground">
          Finalidade *
          <select
            required
            value={form.tipoLead}
            onChange={(event) => updateField("tipoLead", event.target.value)}
            className={inputClass}
          >
            <option value="">Selecione</option>
            <option value="Venda">Venda</option>
            <option value="Aluguel">Aluguel</option>
          </select>
        </label>
        <label className="text-xs text-muted-foreground">
          Valor desejado *
          <input
            required
            type="number"
            min="1"
            step="0.01"
            value={form.valorDesejado}
            onChange={(event) => updateField("valorDesejado", event.target.value)}
            className={inputClass}
          />
        </label>
        <label className="text-xs text-muted-foreground sm:col-span-2">
          Localização desejada *
          <input
            required
            value={form.localizacaoDesejada}
            onChange={(event) => updateField("localizacaoDesejada", event.target.value)}
            className={inputClass}
          />
        </label>
        <label className="text-xs text-muted-foreground">
          Origem
          <select
            value={form.canal}
            onChange={(event) => updateField("canal", event.target.value)}
            className={inputClass}
          >
            <option value="">Selecione</option>
            {leadOrigins.map((origin) => (
              <option key={origin}>{origin}</option>
            ))}
          </select>
        </label>
        <label className="text-xs text-muted-foreground sm:col-span-2">
          Observações
          <textarea
            value={form.observacoes}
            onChange={(event) => updateField("observacoes", event.target.value)}
            className="mt-1.5 min-h-24 w-full rounded-lg border border-white/10 bg-white/[0.03] px-3 py-2 text-sm text-foreground outline-none focus:border-copper/50"
          />
        </label>
      </div>
      {error ? (
        <p role="alert" className="mt-3 text-xs text-red-300">
          {error}
        </p>
      ) : null}
      <Button type="submit" size="sm" className="mt-4 bg-copper text-white" disabled={saving}>
        {saving ? <Loader2 size={14} className="animate-spin" /> : null}
        {saving ? "Salvando..." : "Salvar alterações"}
      </Button>
    </form>
  );
}

function LeadActivityHistory({
  activities,
  showSystemEvents,
  onEdit,
  editing,
  onDelete,
  deleting,
}: {
  activities: LeadTimelineEvent[];
  showSystemEvents: boolean;
  onEdit?: (input: { activityId: string; note: string }) => Promise<unknown>;
  editing: boolean;
  onDelete?: (activityId: string) => Promise<unknown>;
  deleting: boolean;
}) {
  const visibleActivities = showSystemEvents
    ? activities
    : activities.filter(isBrokerAuthoredLeadActivity);
  const [editingId, setEditingId] = useState<string>();
  const [draft, setDraft] = useState("");
  const [actionError, setActionError] = useState("");

  async function save(activity: LeadTimelineEvent) {
    if (!onEdit || !draft.trim()) return;
    setActionError("");
    try {
      await onEdit({ activityId: activity.sourceId, note: draft.trim() });
      setEditingId(undefined);
      setDraft("");
    } catch (reason) {
      setActionError(reason instanceof Error ? reason.message : "Não foi possível editar o aviso.");
    }
  }

  async function remove(activity: LeadTimelineEvent) {
    if (
      !onDelete ||
      !window.confirm(
        "Remover este aviso ativo? O registro permanecerá na linha do tempo permanente.",
      )
    )
      return;
    setActionError("");
    try {
      await onDelete(activity.sourceId);
    } catch (reason) {
      setActionError(reason instanceof Error ? reason.message : "Não foi possível apagar o aviso.");
    }
  }

  return (
    <section className="mt-5 border-t border-white/10 pt-4">
      <h3 className="text-sm font-medium text-foreground">Linha do tempo permanente</h3>
      <p className="mt-1 text-xs text-muted-foreground">
        Todo o caminho deste lead é preservado, incluindo fila, aceite, transferências e alterações.
      </p>
      {visibleActivities.length === 0 ? (
        <p className="mt-2 text-xs text-muted-foreground">
          Ainda não há atualizações registradas para este lead.
        </p>
      ) : (
        <ol className="mt-3 space-y-3">
          {visibleActivities.map((activity) => {
            const administrative = isAdministrativeObservation(activity);
            const editableAdministrative =
              administrative &&
              activity.eventType === "activity" &&
              activity.sourceTable === "crm_lead_activities";
            return (
              <li
                key={activity.id}
                className={
                  administrative
                    ? "rounded-lg border border-yellow-400/30 bg-yellow-400/10 p-3"
                    : "rounded-lg border border-white/8 bg-white/[0.02] p-3"
                }
              >
                <div className="flex flex-wrap items-center justify-between gap-x-3 gap-y-1">
                  <span
                    className={
                      administrative
                        ? "text-xs font-medium text-yellow-300"
                        : "text-xs font-medium text-copper"
                    }
                  >
                    {administrative ? "Aviso" : activity.stage}
                  </span>
                  <div className="flex items-center gap-2">
                    <time className="text-[10px] text-muted-foreground">
                      {new Date(activity.createdAt).toLocaleString("pt-BR")}
                    </time>
                    {editableAdministrative && onEdit && onDelete ? (
                      <>
                        <button
                          type="button"
                          className="rounded p-1 text-yellow-200 transition hover:bg-yellow-400/15"
                          aria-label="Editar aviso"
                          title="Editar aviso"
                          onClick={() => {
                            setEditingId(activity.id);
                            setDraft(activity.note ?? "");
                            setActionError("");
                          }}
                        >
                          <Pencil size={13} />
                        </button>
                        <button
                          type="button"
                          className="rounded p-1 text-red-300 transition hover:bg-red-400/15"
                          aria-label="Apagar aviso"
                          title="Apagar aviso"
                          disabled={deleting}
                          onClick={() => void remove(activity)}
                        >
                          <Trash2 size={13} />
                        </button>
                      </>
                    ) : null}
                  </div>
                </div>
                {!administrative ? (
                  <p className="mt-1 text-xs text-muted-foreground">Por {activity.authorName}</p>
                ) : null}
                {activity.scheduledFor &&
                  activity.eventType === "activity" &&
                  activity.sourceTable === "crm_lead_activities" &&
                  activity.stage.trim().toLocaleLowerCase("pt-BR") === "visita agendada" && (
                    <p className="mt-2 text-xs font-medium text-amber-300">
                      Visita marcada para {new Date(activity.scheduledFor).toLocaleString("pt-BR")}
                    </p>
                  )}
                {editingId === activity.id ? (
                  <div className="mt-2">
                    <textarea
                      value={draft}
                      onChange={(event) => setDraft(event.target.value)}
                      className="min-h-20 w-full rounded-lg border border-yellow-400/30 bg-black/20 px-3 py-2 text-sm text-yellow-50 outline-none focus:border-yellow-300"
                    />
                    <div className="mt-2 flex gap-2">
                      <Button
                        size="sm"
                        disabled={editing || !draft.trim()}
                        onClick={() => void save(activity)}
                      >
                        {editing ? <Loader2 size={13} className="animate-spin" /> : null}
                        Salvar
                      </Button>
                      <Button variant="outline" size="sm" onClick={() => setEditingId(undefined)}>
                        Cancelar
                      </Button>
                    </div>
                  </div>
                ) : activity.note ? (
                  <p
                    className={
                      administrative
                        ? "mt-2 whitespace-pre-wrap text-sm font-medium leading-relaxed text-yellow-100"
                        : "mt-2 whitespace-pre-wrap text-sm leading-relaxed text-foreground/90"
                    }
                  >
                    {administrative ? `${administrativeAuthor(activity)}: ` : ""}
                    {activity.note}
                  </p>
                ) : null}
              </li>
            );
          })}
        </ol>
      )}
      {actionError ? <p className="mt-3 text-xs text-red-300">{actionError}</p> : null}
    </section>
  );
}

function isBrokerAuthoredLeadActivity(activity: LeadTimelineEvent) {
  if (activity.eventType !== "activity" || activity.sourceTable !== "crm_lead_activities") {
    return false;
  }

  const author = activity.authorName.trim().toLocaleLowerCase("pt-BR");
  if (!author || author === "sistema" || author === "sistema (gestão)") return false;

  const stage = activity.stage.trim().toLocaleLowerCase("pt-BR");
  const note = (activity.note ?? "").trim().toLocaleLowerCase("pt-BR");
  if (
    stage === "lead aceito" ||
    stage === "qualificacao expirada" ||
    stage === "qualificacao concluida" ||
    stage === "qualificacao: concluida" ||
    stage === "qualificacao: penalidade"
  ) {
    return false;
  }
  if (note.startsWith("atendimento iniciado; qualificacao obrigatoria ate ")) return false;

  return true;
}

function isAdministrativeObservation(activity: LeadActivity) {
  return (
    displayText(activity.stage).toLocaleLowerCase("pt-BR") === "observacao" ||
    displayText(activity.stage).toLocaleLowerCase("pt-BR") === "observação"
  );
}

function administrativeAuthor(activity: LeadActivity) {
  return displayBrokerName(activity.authorName) || "Sistema";
}

function AdministrativeNotice({ activity }: { activity: LeadActivity }) {
  return (
    <p className="mt-2 max-w-[320px] whitespace-pre-wrap rounded-md border border-yellow-400/30 bg-yellow-400/10 px-2.5 py-2 text-xs font-medium leading-relaxed text-yellow-100">
      {administrativeAuthor(activity)}: {activity.note}
    </p>
  );
}

function YesNoChoice({
  label,
  value,
  onChange,
}: {
  label: string;
  value: "" | "sim" | "nao";
  onChange: (value: "sim" | "nao") => void;
}) {
  return (
    <fieldset>
      <legend className="text-xs font-medium text-foreground">{label} *</legend>
      <div className="mt-2 flex gap-2">
        {(["sim", "nao"] as const).map((option) => (
          <button
            key={option}
            type="button"
            onClick={() => onChange(option)}
            className={`rounded-lg border px-4 py-2 text-xs font-medium transition ${
              value === option
                ? "border-copper bg-copper/15 text-copper"
                : "border-white/10 bg-white/[0.03] text-muted-foreground hover:border-white/20"
            }`}
          >
            {option === "sim" ? "Sim" : "Não"}
          </button>
        ))}
      </div>
    </fieldset>
  );
}
function toDateTimeLocal(value?: string) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000);
  return local.toISOString().slice(0, 16);
}
function whatsAppLink(phone: string) {
  const digits = phone.replace(/\D/g, "");
  const normalized = digits.length <= 11 ? `55${digits}` : digits;
  return `https://wa.me/${normalized}`;
}
function splitDateTimeValue(value: string): [string, string] {
  if (!value) return ["", ""];
  const [date, time] = value.split("T");
  return [isoDateToBr(date), time?.slice(0, 5) ?? ""];
}
function formatBrDate(value: string) {
  const digits = value.replace(/\D/g, "").slice(0, 8);
  if (digits.length <= 2) return digits;
  if (digits.length <= 4) return `${digits.slice(0, 2)}/${digits.slice(2)}`;
  return `${digits.slice(0, 2)}/${digits.slice(2, 4)}/${digits.slice(4)}`;
}
function brDateToIso(value: string) {
  const match = value.match(/^(\d{2})\/(\d{2})\/(\d{4})$/);
  if (!match) return undefined;
  const [, day, month, year] = match;
  const candidate = new Date(`${year}-${month}-${day}T12:00:00`);
  if (
    candidate.getFullYear() !== Number(year) ||
    candidate.getMonth() + 1 !== Number(month) ||
    candidate.getDate() !== Number(day)
  ) {
    return undefined;
  }
  return `${year}-${month}-${day}`;
}
function isoDateToBr(value: string) {
  const match = value.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  return match ? `${match[3]}/${match[2]}/${match[1]}` : "";
}
function toDateTimeValue(date: string, time: string) {
  const isoDate = brDateToIso(date);
  return isoDate && /^\d{2}:\d{2}$/.test(time) ? `${isoDate}T${time}` : "";
}
function openCalendar(input: HTMLInputElement | null) {
  if (!input) return;
  try {
    const picker = input as HTMLInputElement & { showPicker?: () => void };
    if (picker.showPicker) picker.showPicker();
    else input.click();
  } catch {
    input.click();
  }
}
function LeadDeadlineTimer({
  availableAt,
  deadline,
  assignmentStatus,
  stage,
  visitScheduledAt,
  qualificationDeadline,
  qualificationCompleted,
  qualificationExpired,
}: {
  availableAt?: string;
  deadline?: string;
  assignmentStatus?: "pending" | "accepted" | "exhausted";
  stage: string;
  visitScheduledAt?: string;
  qualificationDeadline?: string;
  qualificationCompleted?: boolean;
  qualificationExpired?: boolean;
}) {
  const [now, setNow] = useState(() => Date.now());
  const isVisit = stage === "Visita agendada" && Boolean(visitScheduledAt);
  const isPendingOffer = assignmentStatus === "pending" && stage === "Aguardando atendimento";
  const isActiveAttendance =
    assignmentStatus === "accepted" && stage === "Em atendimento" && Boolean(deadline);
  const qualificationDeadlineTime = qualificationDeadline
    ? new Date(qualificationDeadline).getTime()
    : Number.NaN;
  const isQualifying =
    Number.isFinite(qualificationDeadlineTime) &&
    qualificationDeadlineTime > now &&
    !qualificationCompleted &&
    !qualificationExpired;

  useEffect(() => {
    if (
      !(isPendingOffer && (availableAt || deadline)) &&
      !isActiveAttendance &&
      !isVisit &&
      !isQualifying
    )
      return;
    const interval = window.setInterval(() => setNow(Date.now()), 1_000);
    return () => window.clearInterval(interval);
  }, [availableAt, deadline, isActiveAttendance, isPendingOffer, isQualifying, isVisit]);

  const availableAtTime = availableAt ? new Date(availableAt).getTime() : Number.NaN;
  if (isPendingOffer && Number.isFinite(availableAtTime) && availableAtTime > now) {
    const scheduledLabel = new Intl.DateTimeFormat("pt-BR", {
      timeZone: "America/Sao_Paulo",
      day: "2-digit",
      month: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
    })
      .format(new Date(availableAtTime))
      .replace(",", " às");
    return (
      <span
        className="inline-flex items-center gap-1 whitespace-nowrap text-[10px] font-medium text-sky-300"
        title={`A esteira começa em ${new Date(availableAtTime).toLocaleString("pt-BR", { timeZone: "America/Sao_Paulo" })}`}
      >
        <CalendarClock size={11} />
        Programado para {scheduledLabel}
      </span>
    );
  }

  // Queue offers, active attendance and post-acceptance qualification each
  // keep their own countdown. In particular, a pending offer must not vanish
  // as soon as its scheduled availability time is reached.
  const activeDeadline = isQualifying
    ? qualificationDeadline!
    : isPendingOffer
      ? deadline
      : isActiveAttendance
        ? deadline!
        : undefined;
  if (!isVisit && !activeDeadline) return null;
  const target = new Date(isVisit ? visitScheduledAt! : activeDeadline!).getTime();
  if (Number.isNaN(target)) return null;
  const difference =
    !isVisit && isPendingOffer
      ? leadQueueMillisecondsBetween(now, target)
      : !isVisit && isActiveAttendance
        ? commercialMillisecondsBetween(now, target)
        : target - now;
  const expired = target <= now;
  const paused = !expired && !isVisit && (isPendingOffer || isActiveAttendance) && difference === 0;
  const duration = formatCountdown(Math.abs(difference));
  const label = isVisit
    ? expired
      ? `Em visita há ${duration}`
      : `Visita em ${duration}`
    : expired
      ? isQualifying
        ? "Qualificação expirada"
        : isPendingOffer
          ? "Prazo de aceite encerrado"
          : "Prazo encerrado"
      : paused
        ? `${duration} restantes · pausado`
        : `${duration} restantes${isPendingOffer ? " para aceitar" : isQualifying ? " (Qualif.)" : ""}`;

  return (
    <span
      className={`inline-flex whitespace-nowrap items-center gap-1 text-[10px] font-medium tabular-nums ${
        expired ? "text-rose-300" : isQualifying ? "text-blue-300" : "text-amber-300"
      }`}
      title={`${isVisit ? "Visita" : isQualifying ? "Qualificação" : "Prazo"}: ${new Date(isVisit ? visitScheduledAt! : activeDeadline!).toLocaleString("pt-BR")}`}
    >
      <Timer size={11} />
      {label}
    </span>
  );
}

function leadQueueMillisecondsBetween(start: number, end: number) {
  if (end <= start) return end - start;
  let cursor = new Date(start);
  const target = new Date(end);
  let total = 0;
  while (cursor < target) {
    const opening = new Date(cursor);
    opening.setHours(9, 0, 0, 0);
    const closing = new Date(cursor);
    closing.setHours(18, 0, 0, 0);
    const intervalStart = Math.max(cursor.getTime(), opening.getTime());
    const intervalEnd = Math.min(target.getTime(), closing.getTime());
    if (intervalEnd > intervalStart) total += intervalEnd - intervalStart;
    const nextDay = new Date(cursor);
    nextDay.setDate(nextDay.getDate() + 1);
    nextDay.setHours(0, 0, 0, 0);
    cursor = nextDay;
  }
  return total;
}

function formatCountdown(milliseconds: number) {
  const seconds = Math.floor(milliseconds / 1_000);
  const days = Math.floor(seconds / 86_400);
  const hours = Math.floor((seconds % 86_400) / 3_600);
  const minutes = Math.floor((seconds % 3_600) / 60);
  const remainderSeconds = seconds % 60;
  const clock = `${String(hours).padStart(2, "0")}:${String(minutes).padStart(2, "0")}:${String(remainderSeconds).padStart(2, "0")}`;
  return days ? `${days}d ${clock}` : clock;
}

function commercialMillisecondsBetween(start: number, end: number) {
  if (end <= start) return end - start;
  let cursor = new Date(start);
  const target = new Date(end);
  let total = 0;
  while (cursor < target) {
    const day = cursor.getDay();
    if (day !== 0 && day !== 6) {
      const opening = new Date(cursor);
      opening.setHours(8, 30, 0, 0);
      const closing = new Date(cursor);
      closing.setHours(18, 30, 0, 0);
      const intervalStart = Math.max(cursor.getTime(), opening.getTime());
      const intervalEnd = Math.min(target.getTime(), closing.getTime());
      if (intervalEnd > intervalStart) total += intervalEnd - intervalStart;
    }
    const nextDay = new Date(cursor);
    nextDay.setDate(nextDay.getDate() + 1);
    nextDay.setHours(0, 0, 0, 0);
    cursor = nextDay;
  }
  return total;
}

function PropertyInterest({ value, url }: { value?: string; url?: string }) {
  return (
    <span className="inline-flex items-center gap-2">
      <span>{value || "—"}</span>
      {url ? (
        <a
          href={url}
          target="_blank"
          rel="noreferrer"
          title="Abrir imóvel"
          className="text-copper hover:text-copper/80"
        >
          <ExternalLink size={14} />
        </a>
      ) : null}
    </span>
  );
}
function Detail({ label, value, url }: { label: string; value?: string; url?: string }) {
  return (
    <div>
      <dt className="text-xs text-muted-foreground">{label}</dt>
      <dd className="mt-1 font-medium">
        <PropertyInterest value={value} url={url} />
      </dd>
    </div>
  );
}
function ReadOnlyLeadField({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="text-xs text-muted-foreground">{label}</p>
      <div className="mt-1.5 flex min-h-10 items-center rounded-lg border border-white/10 bg-white/[0.03] px-3 py-2 text-sm font-medium text-foreground">
        {value}
      </div>
    </div>
  );
}
function MobileLeadDetail({ label, value, url }: { label: string; value: string; url?: string }) {
  return (
    <div className="min-w-0">
      <dt className="text-[10px] uppercase tracking-wider text-muted-foreground">{label}</dt>
      <dd className="mt-1 break-words font-medium text-foreground">
        <PropertyInterest value={value} url={url} />
      </dd>
    </div>
  );
}
function PropertyMatchOffers({
  lead,
  onStart,
  starting,
  onDismiss,
  dismissing,
}: {
  lead: ManagedLead;
  onStart?: (input: { leadId: string; propertyId: string }) => Promise<unknown>;
  starting: boolean;
  onDismiss?: (leadId: string) => Promise<unknown>;
  dismissing: boolean;
}) {
  const [open, setOpen] = useState(false);
  const [offerError, setOfferError] = useState("");
  if (lead.estagio === "Corretor") return null;

  const visible = lead.propertyMatches.filter(
    (match) => !match.offerStartedAt && !match.dismissedAt,
  );
  const pending = visible.filter((match) => !match.expiredAt);
  const paused =
    !visible.length && lead.propertyMatches.some((match) => Boolean(match.dismissedAt));
  const deadline = pending
    .map((match) => match.expiresAt)
    .sort((left, right) => left.localeCompare(right))[0];
  if (paused) {
    return (
      <p className="mt-2 inline-flex rounded-lg border border-sky-300/20 bg-sky-300/[.07] px-2.5 py-2 text-xs font-medium text-sky-200">
        Imóveis analisados. Prazo pausado até surgir um novo imóvel similar.
      </p>
    );
  }
  if (!visible.length) return null;
  return (
    <>
      <div className="mt-2 flex max-w-full flex-wrap items-center gap-2 rounded-lg border border-amber-300/25 bg-amber-300/[.08] px-2.5 py-2">
        <div className="min-w-0">
          <p className="truncate text-xs font-semibold text-amber-200">
            {visible.length === 1
              ? "1 imóvel similar encontrado"
              : `${visible.length} imóveis similares encontrados`}
          </p>
          {deadline ? <SimilarPropertyDeadlineTimer deadline={deadline} /> : null}
        </div>
        <Button
          type="button"
          size="sm"
          variant="outline"
          className="h-8 shrink-0 text-xs"
          onClick={() => {
            setOfferError("");
            setOpen(true);
          }}
        >
          <Eye size={13} /> Abrir imóveis similares
        </Button>
        {onDismiss && visible.length ? (
          <Button
            type="button"
            size="sm"
            variant="outline"
            className="h-8 shrink-0 text-xs"
            disabled={dismissing}
            onClick={() => {
              setOfferError("");
              void onDismiss(lead.id).catch((error) =>
                setOfferError(
                  displayText(
                    error instanceof Error
                      ? error.message
                      : "Não foi possível encerrar as sugestões.",
                  ),
                ),
              );
            }}
          >
            {dismissing ? <Loader2 size={13} className="animate-spin" /> : null}
            Os imóveis não servem
          </Button>
        ) : null}
        {offerError ? <p className="w-full text-xs text-rose-300">{offerError}</p> : null}
      </div>

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="glass-strong max-h-[calc(100dvh-2rem)] overflow-y-auto border-white/10 text-foreground sm:max-w-xl">
          <DialogHeader>
            <DialogTitle>Imóveis similares para {lead.nome}</DialogTitle>
            <DialogDescription>
              Consulte os imóveis encontrados e inicie uma nova oferta quando desejar.
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-3">
            {visible.map((match) => (
              <div
                key={match.propertyId}
                className="rounded-lg border border-amber-300/25 bg-amber-300/[.08] p-3"
              >
                <p className="text-xs font-semibold text-amber-200">Imóvel similar encontrado</p>
                <p className="mt-1 break-words text-sm text-foreground">{match.title}</p>
                <div className="mt-3 flex flex-wrap gap-2">
                  {match.url ? (
                    <Button asChild type="button" size="sm" variant="outline">
                      <a href={match.url} target="_blank" rel="noreferrer">
                        <ExternalLink size={14} /> Ver imóvel
                      </a>
                    </Button>
                  ) : null}
                  {onStart ? (
                    <Button
                      type="button"
                      size="sm"
                      disabled={starting}
                      onClick={() => {
                        setOfferError("");
                        void onStart({ leadId: lead.id, propertyId: match.propertyId })
                          .then(() => setOpen(false))
                          .catch((error) =>
                            setOfferError(
                              displayText(
                                error instanceof Error
                                  ? error.message
                                  : "Não foi possível iniciar a nova oferta.",
                              ),
                            ),
                          );
                      }}
                    >
                      {starting ? <Loader2 size={14} className="animate-spin" /> : null}
                      Iniciar nova oferta
                    </Button>
                  ) : null}
                </div>
              </div>
            ))}
            {offerError ? <p className="text-sm text-rose-300">{offerError}</p> : null}
          </div>
        </DialogContent>
      </Dialog>
    </>
  );
}

function SimilarPropertyDeadlineTimer({ deadline }: { deadline: string }) {
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    const interval = window.setInterval(() => setNow(Date.now()), 1_000);
    return () => window.clearInterval(interval);
  }, []);

  const target = new Date(deadline).getTime();
  if (!Number.isFinite(target)) return null;
  const expired = target <= now;
  const remaining = weekdayMillisecondsBetween(now, target);
  return (
    <span
      className={`mt-1 flex items-center gap-1 text-[10px] ${expired ? "text-rose-300" : "text-amber-200"}`}
    >
      <Timer size={11} />
      {expired ? "Prazo encerrado" : `${formatCountdown(remaining)} restantes`}
    </span>
  );
}

function weekdayMillisecondsBetween(start: number, end: number) {
  if (end <= start) return 0;
  let cursor = new Date(start);
  const target = new Date(end);
  let total = 0;
  while (cursor < target) {
    if (cursor.getDay() !== 0 && cursor.getDay() !== 6) {
      const endOfDay = new Date(cursor);
      endOfDay.setHours(24, 0, 0, 0);
      total += Math.max(0, Math.min(target.getTime(), endOfDay.getTime()) - cursor.getTime());
    }
    const nextDay = new Date(cursor);
    nextDay.setDate(nextDay.getDate() + 1);
    nextDay.setHours(0, 0, 0, 0);
    cursor = nextDay;
  }
  return total;
}
function Skeleton() {
  return (
    <>
      {Array.from({ length: 8 }).map((_, row) => (
        <tr key={row} className="border-t border-white/5">
          {Array.from({ length: 9 }).map((__, cell) => (
            <td key={cell} className="px-4 py-4">
              <div className="skeleton h-4 w-full" />
            </td>
          ))}
        </tr>
      ))}
    </>
  );
}

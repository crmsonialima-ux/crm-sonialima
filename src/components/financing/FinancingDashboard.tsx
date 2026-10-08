import {
  BadgeCheck,
  Banknote,
  Building2,
  Check,
  CheckCircle2,
  ChevronRight,
  CircleAlert,
  Clock3,
  FileCheck2,
  FileText,
  History,
  Landmark,
  Loader2,
  LockKeyhole,
  RefreshCw,
  RotateCcw,
  Search,
  ShieldCheck,
  Trash2,
  UserRound,
  X,
  XCircle,
} from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { Button } from "@/components/ui/button";
import { Panel } from "@/components/dashboard/Panel";
import { useAuth } from "@/components/auth/AuthProvider";
import {
  FINANCING_STAGES,
  financingProgress,
  isFinancingUnavailableError,
  type FinancingProcess,
  type FinancingStage,
  useDeleteFinancingProcess,
  useFinancingPermission,
  useFinancingProcesses,
  useUpdateFinancingProcess,
} from "@/lib/financing";
import { isAdministradorAdmin } from "@/lib/admin-access";
import { displayText } from "@/lib/display-text";

const stageLabels = Object.fromEntries(FINANCING_STAGES.map((item) => [item.key, item.label]));
const statusLabels: Record<string, string> = {
  pending: "Pendente",
  in_progress: "Em andamento",
  awaiting_documents: "Aguardando documentação",
  awaiting_conformity: "Aguardando conformidade",
  awaiting_registry: "Aguardando registro",
  inspection_not_requested: "Vistoria não solicitada",
  release_nonconform: "Liberação não conforme",
  credit_denied: "Credito negado",
  report_denied: "Laudo negado",
  completed: "Concluido",
};
const actionLabels: Record<string, string> = {
  financing_started: "Financiamento iniciado",
  checklist_sent: "Checklist inicial atualizado",
  document_status: "Documento atualizado",
  documentation_complete: "Checklist documental concluido",
  credit_decision: "Decisao de credito registrada",
  inspection_request: "Pedido de vistoria atualizado",
  report_result: "Resultado do laudo registrado",
  conformity_start: "Entrada na conformidade registrada",
  conformity_result: "Resultado da conformidade registrado",
  conformity_restart: "Nova tentativa de conformidade iniciada",
  committee_date: "Envio ao comite registrado",
  minutes_issued: "Minuta emitida",
  notary_complete: "Cartório de Notas concluido",
  registry_details: "Dados do registro preenchidos",
  registry_phase: "Fase do registro alterada",
  release_entry: "Entrada da conformidade de liberação registrada",
  release_decision: "Resultado da liberação registrado",
};

type FormValues = Record<string, string>;

function currency(value?: number) {
  return value?.toLocaleString("pt-BR", { style: "currency", currency: "BRL" }) ?? "—";
}

function dateTime(value?: string) {
  if (!value) return "—";
  return new Date(value).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" });
}

function formatHistoryValue(value: unknown) {
  if (value === null || value === undefined) return "Não informado";
  if (typeof value === "boolean") return value ? "Sim" : "Não";
  if (typeof value === "object") {
    return Object.entries(value as Record<string, unknown>)
      .filter(([, item]) => item !== null && item !== "")
      .map(([key, item]) => `${displayText(key.replaceAll("_", " "))}: ${String(item)}`)
      .join(" · ");
  }
  return displayText(String(value));
}

function statusTone(status: string) {
  if (status === "completed") return "border-emerald-400/30 bg-emerald-400/10 text-emerald-200";
  if (status.includes("denied")) return "border-rose-400/30 bg-rose-400/10 text-rose-200";
  if (status === "pending") return "border-amber-400/30 bg-amber-400/10 text-amber-200";
  return "border-sky-400/30 bg-sky-400/10 text-sky-200";
}

export function FinancingDashboard() {
  const { session, profile } = useAuth();
  const processes = useFinancingProcesses(Boolean(session));
  const permission = useFinancingPermission(Boolean(session));
  const updater = useUpdateFinancingProcess();
  const deleter = useDeleteFinancingProcess();
  const [query, setQuery] = useState("");
  const [brokerId, setBrokerId] = useState("all");
  const [selectedId, setSelectedId] = useState<string>();
  const [form, setForm] = useState<FormValues>({});
  const [viewStage, setViewStage] = useState<FinancingStage>();
  const [error, setError] = useState("");
  const [success, setSuccess] = useState("");
  const data = useMemo(() => processes.data ?? [], [processes.data]);
  const isOperator = profile?.email === "crmsoniaallyson@gmail.com" || profile?.email === "unassigned-operator@example.invalid";
  const canDelete = isAdministradorAdmin(profile);

  useEffect(() => {
    const requested = new URLSearchParams(window.location.search).get("process") ?? undefined;
    if (requested && data.some((item) => item.id === requested)) setSelectedId(requested);
    else if (!selectedId && data[0]) setSelectedId(data[0].id);
  }, [data, selectedId]);

  const selected = data.find((item) => item.id === selectedId);
  useEffect(() => {
    if (!selected) return;
    const activeAttempt = selected.conformityAttempts.find((attempt) => attempt.active);
    setForm({
      approvedValue: selected.creditApprovedValue ? String(selected.creditApprovedValue) : "",
      creditBank: selected.creditBank ?? "",
      financingValue: selected.creditFinancingValue ? String(selected.creditFinancingValue) : "",
      creditReason: selected.creditDenialReason ?? "",
      reportValue: selected.reportPropertyValue ? String(selected.reportPropertyValue) : "",
      reportReason: selected.reportDenialReason ?? "",
      conformityEntry: activeAttempt?.entryDate ?? "",
      conformityReturn: activeAttempt?.returnDate ?? "",
      conformityReason: activeAttempt?.nonconformityReason ?? "",
      committeeDate: selected.committeeSentDate ?? "",
      notaryName: selected.notaryName ?? "",
      deedDate: selected.deedDate ?? "",
      signingDate: selected.deedSigningDate ?? "",
      registryProtocol: selected.registryProtocol ?? "",
      registryDelivery: selected.registryExpectedDelivery ?? "",
      registryPhase: selected.registryPhase ?? "examination",
      releaseEntry: selected.releaseConformityEntryDate ?? "",
      releaseDate: selected.creditReleaseDate ?? "",
      releaseReason: selected.releaseDenialReason ?? "",
      note: "",
    });
    setError("");
    setSuccess("");
    setViewStage(undefined);
  }, [selected]);

  const brokers = useMemo(
    () =>
      [...new Map(data.map((item) => [item.brokerId, item.brokerName])).entries()].sort((a, b) =>
        a[1].localeCompare(b[1], "pt-BR"),
      ),
    [data],
  );
  const filtered = data.filter((item) => {
    const normalized = query.trim().toLocaleLowerCase("pt-BR");
    return (
      (brokerId === "all" || item.brokerId === brokerId) &&
      (!normalized ||
        `${item.leadName} ${item.brokerName} ${item.propertyInterest ?? ""}`
          .toLocaleLowerCase("pt-BR")
          .includes(normalized))
    );
  });
  const stats = [
    ["Total", data.length, Landmark],
    ["Pendentes", data.filter((item) => item.status === "pending").length, Clock3],
    [
      "Em andamento",
      data.filter((item) => !["pending", "completed"].includes(item.status)).length,
      RefreshCw,
    ],
    ["Documentacao", data.filter((item) => item.status === "awaiting_documents").length, FileText],
    [
      "Conformidade",
      data.filter((item) => item.status === "awaiting_conformity").length,
      ShieldCheck,
    ],
    ["Registro", data.filter((item) => item.status === "awaiting_registry").length, Building2],
    ["Concluidos", data.filter((item) => item.status === "completed").length, BadgeCheck],
  ] as const;

  const update = async (action: string, payload: Record<string, unknown>) => {
    if (!selected || updater.isPending) return;
    setError("");
    setSuccess("");
    try {
      await updater.mutateAsync({
        processId: selected.id,
        action,
        payload,
        expectedVersion: selected.version,
        note: form.note,
      });
      setSuccess("Alteração salva e registrada no histórico.");
      setForm((current) => ({ ...current, note: "" }));
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Não foi possível salvar a etapa.");
    }
  };

  const deleteSelected = async () => {
    if (!selected || !canDelete || deleter.isPending) return;
    const confirmed = window.confirm(
      `Excluir ${selected.leadName} da aba de financiamentos? O lead continuara no CRM, mas todo o historico deste processo de financiamento sera removido.`,
    );
    if (!confirmed) return;
    setError("");
    setSuccess("");
    try {
      await deleter.mutateAsync(selected.id);
      setSelectedId(undefined);
      window.history.replaceState(null, "", "/financiamento");
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Nao foi possivel excluir o processo.");
    }
  };

  if (processes.isLoading) return <LoadingState />;
  if (processes.error && isFinancingUnavailableError(processes.error)) {
    return <UnavailableState />;
  }
  if (processes.error) {
    return (
      <ErrorState
        message={displayText((processes.error as Error).message)}
        retry={() => void processes.refetch()}
      />
    );
  }

  return (
    <div className="space-y-5">
      <header className="flex flex-col justify-between gap-4 lg:flex-row lg:items-end">
        <div>
          <p className="text-[11px] uppercase tracking-[0.28em] text-copper">Credito imobiliario</p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight text-foreground sm:text-3xl">
            Financiamento
          </h1>
          <p className="mt-1 max-w-2xl text-sm text-muted-foreground">
            Fluxo progressivo, auditavel e integrado aos leads da Sônia Lima.
          </p>
        </div>
        <span className="inline-flex w-fit items-center gap-2 rounded-full border border-white/10 bg-white/[0.03] px-3 py-1.5 text-xs text-muted-foreground">
          {isOperator ? (
            <ShieldCheck size={14} className="text-copper" />
          ) : (
            <LockKeyhole size={14} />
          )}
          {isOperator ? "Operacao autorizada" : "Acompanhamento somente leitura"}
        </span>
      </header>

      <section className="grid grid-cols-2 gap-3 md:grid-cols-4 xl:grid-cols-7">
        {stats.map(([label, value, Icon]) => (
          <div key={label} className="glass rounded-2xl p-4">
            <Icon size={17} className="text-copper" />
            <strong className="mt-3 block text-2xl text-foreground">{value}</strong>
            <span className="text-[11px] text-muted-foreground">{label}</span>
          </div>
        ))}
      </section>

      {!data.length ? (
        <Panel
          title="Nenhum financiamento"
          subtitle="Os processos surgem somente quando o corretor responsável marca o lead."
        >
          <div className="grid min-h-52 place-items-center text-center">
            <div>
              <Landmark className="mx-auto text-muted-foreground" size={34} />
              <p className="mt-3 text-sm text-muted-foreground">
                Ainda não há financiamentos para exibir.
              </p>
            </div>
          </div>
        </Panel>
      ) : (
        <div className="grid min-w-0 gap-5 xl:grid-cols-[360px_minmax(0,1fr)]">
          <Panel
            title="Processos"
            subtitle={`${filtered.length} financiamento(s)`}
            className="min-w-0"
          >
            <div className="relative">
              <Search
                className="absolute left-3 top-1/2 -translate-y-1/2 text-muted-foreground"
                size={16}
              />
              <input
                value={query}
                onChange={(event) => setQuery(event.target.value)}
                placeholder="Buscar lead, corretor ou imóvel"
                className="h-10 w-full rounded-xl border border-white/10 bg-white/[0.03] pl-9 pr-3 text-sm text-foreground outline-none focus:border-copper/50"
              />
            </div>
            <div className="mt-3 flex gap-2 overflow-x-auto pb-2">
              <FilterChip active={brokerId === "all"} onClick={() => setBrokerId("all")}>
                Todos
              </FilterChip>
              {brokers.map(([id, name]) => (
                <FilterChip key={id} active={brokerId === id} onClick={() => setBrokerId(id)}>
                  {name}
                </FilterChip>
              ))}
            </div>
            <div className="mt-2 max-h-[68dvh] space-y-2 overflow-y-auto pr-1">
              {filtered.map((item) => (
                <button
                  key={item.id}
                  onClick={() => {
                    setSelectedId(item.id);
                    window.history.replaceState(null, "", `/financiamento?process=${item.id}`);
                    setTimeout(() => {
                      document.getElementById("process-detail")?.scrollIntoView({ behavior: "smooth" });
                    }, 50);
                  }}
                  className={`w-full rounded-xl border p-3 text-left transition ${selectedId === item.id ? "border-copper/50 bg-copper/[0.08]" : "border-white/8 bg-white/[0.02] hover:bg-white/[0.05]"}`}
                >
                  <span className="flex items-start justify-between gap-3">
                    <span className="min-w-0">
                      <strong className="block truncate text-sm text-foreground">
                        {item.leadName}
                      </strong>
                      <span className="mt-0.5 block truncate text-[11px] text-muted-foreground">
                        {item.brokerName}
                      </span>
                    </span>
                    <ChevronRight size={16} className="mt-1 shrink-0 text-muted-foreground" />
                  </span>
                  <span
                    className={`mt-3 inline-flex rounded-full border px-2 py-1 text-[10px] ${statusTone(item.status)}`}
                  >
                    {statusLabels[item.status]}
                  </span>
                </button>
              ))}
            </div>
          </Panel>
          {selected ? (
            <ProcessDetail
              process={selected}
              isOperator={Boolean(isOperator)}
              canDelete={canDelete}
              form={form}
              setForm={setForm}
              pending={updater.isPending || deleter.isPending}
              error={error}
              success={success}
              update={update}
              viewStage={viewStage}
              setViewStage={setViewStage}
              onDelete={deleteSelected}
            />
          ) : null}
        </div>
      )}
    </div>
  );
}

function ProcessDetail({
  process,
  isOperator,
  canDelete,
  form,
  setForm,
  pending,
  error,
  success,
  update,
  viewStage,
  setViewStage,
  onDelete,
}: {
  process: FinancingProcess;
  isOperator: boolean;
  canDelete: boolean;
  form: FormValues;
  setForm: (value: FormValues | ((current: FormValues) => FormValues)) => void;
  pending: boolean;
  error: string;
  success: string;
  update: (action: string, payload: Record<string, unknown>) => Promise<void>;
  viewStage: FinancingStage | undefined;
  setViewStage: (value: FinancingStage | undefined) => void;
  onDelete: () => Promise<void>;
}) {
  const progress = financingProgress(process.currentStage);
  const activeAttempt = process.conformityAttempts.find((attempt) => attempt.active);
  const set = (key: string, value: string) => setForm((current) => ({ ...current, [key]: value }));
  return (
    <div id="process-detail" className="min-w-0 space-y-5">
      <Panel title={process.leadName} subtitle={`Responsável: ${process.brokerName}`}>
        {canDelete ? (
          <div className="mb-4 flex justify-end">
            <Button
              variant="destructive"
              size="sm"
              disabled={pending}
              onClick={() => void onDelete()}
            >
              {pending ? <Loader2 className="animate-spin" size={15} /> : <Trash2 size={15} />}
              Excluir de financiamentos
            </Button>
          </div>
        ) : null}
        <div className="grid gap-3 text-sm sm:grid-cols-2 lg:grid-cols-5">
          <Summary label="Imóvel" value={process.propertyInterest ?? "Não informado"} />
          <Summary label="Valor aprovado" value={currency(process.creditApprovedValue)} />
          <Summary label="Banco" value={process.creditBank ?? "—"} />
          <Summary label="Valor financiamento" value={currency(process.creditFinancingValue)} />
          <Summary label="Entrada no fluxo" value={dateTime(process.activatedAt)} />
        </div>
        <div className="mt-5">
          <div className="flex justify-between text-xs text-muted-foreground">
            <span>{stageLabels[process.currentStage]}</span>
            <strong className="text-copper">{progress}%</strong>
          </div>
          <div className="mt-2 h-2 overflow-hidden rounded-full bg-white/5">
            <div
              className="h-full rounded-full bg-gradient-to-r from-wine via-copper to-amber-200 transition-all"
              style={{ width: `${progress}%` }}
            />
          </div>
          <div className="mt-4 flex gap-2 overflow-x-auto pb-2">
            {FINANCING_STAGES.map((stage, index) => {
              const currentIndex = FINANCING_STAGES.findIndex(
                (item) => item.key === process.currentStage,
              );
              const complete = index < currentIndex || process.currentStage === "completed";
              const current = stage.key === process.currentStage;
              return (
                <button
                  key={stage.key}
                  disabled={!isOperator}
                  onClick={() => {
                    if (isOperator) setViewStage(stage.key);
                  }}
                  className={`min-w-28 rounded-xl border p-2 text-[10px] text-left transition-colors ${viewStage === stage.key || (!viewStage && current) ? "border-copper/40 bg-copper/10 text-copper font-medium" : complete ? "border-emerald-400/25 bg-emerald-400/8 text-emerald-200" : "border-white/8 bg-white/[0.02] text-muted-foreground hover:bg-white/[0.05]"}`}
                >
                  <span className="mb-1 flex items-center gap-1">
                    {complete ? (
                      <Check size={11} />
                    ) : current ? (
                      <Clock3 size={11} />
                    ) : (
                      <LockKeyhole size={11} />
                    )}
                    {index + 1}
                  </span>
                  {stage.label}
                </button>
              );
            })}
          </div>
        </div>
      </Panel>

      <Panel title="Etapa atual" subtitle={stageLabels[viewStage ?? process.currentStage]}>
        {!isOperator ? (
          <p className="rounded-xl border border-white/10 bg-white/[0.03] p-4 text-sm text-muted-foreground">
            O acompanhamento esta disponivel em modo leitura. As etapas operacionais sao exclusivas
            do operador de financiamento.
          </p>
        ) : (
          <div className="space-y-4">

            {viewStage && viewStage !== process.currentStage ? (
              <div className="mb-4 rounded-xl border border-rose-400/25 bg-rose-400/10 p-4">
                <strong className="text-sm text-rose-100">Modo de edição: etapa não atual</strong>
                <p className="mt-1 text-xs text-rose-100/70">
                  Você está editando uma etapa diferente da etapa atual do financiamento.
                  Caso queira retornar o status geral do financiamento para esta etapa, clique abaixo.
                </p>
                <Button
                  variant="destructive"
                  className="mt-3"
                  disabled={pending}
                  onClick={() => void update("revert_to_stage", { target_stage: viewStage })}
                >
                  {pending ? <Loader2 className="animate-spin mr-2 h-4 w-4" /> : <RotateCcw size={16} className="mr-2" />}
                  Reverter status para {stageLabels[viewStage] ?? "esta etapa"}
                </Button>
              </div>
            ) : null}
            <CurrentStep
              process={process}
              activeAttempt={activeAttempt}
              form={form}
              set={set}
              pending={pending}
              update={update}
              viewStage={viewStage}
            />
            {process.registryPhase &&
            process.currentStage !== "registry_phase" &&
            process.currentStage !== "completed" ? (
              <RegistryPhaseControl
                value={form.registryPhase}
                set={set}
                pending={pending}
                update={update}
              />
            ) : null}
            <label className="block text-xs text-muted-foreground">
              Observação desta alteração (opcional)
              <textarea
                value={form.note}
                onChange={(event) => set("note", event.target.value)}
                className="mt-1.5 min-h-20 w-full resize-y rounded-xl border border-white/10 bg-white/[0.03] p-3 text-sm text-foreground outline-none focus:border-copper/50"
                placeholder="Contexto que deve permanecer na auditoria."
              />
            </label>
          </div>
        )}
        {error ? (
          <p
            role="alert"
            className="mt-3 rounded-lg border border-rose-400/20 bg-rose-400/10 px-3 py-2 text-sm text-rose-200"
          >
            {error}
          </p>
        ) : null}
        {success ? (
          <p className="mt-3 rounded-lg border border-emerald-400/20 bg-emerald-400/10 px-3 py-2 text-sm text-emerald-200">
            {success}
          </p>
        ) : null}
      </Panel>

      {process.conformityAttempts.length ? (
        <Panel
          title="Ciclos de conformidade"
          subtitle={`${process.conformityAttempts.length} tentativa(s) preservada(s)`}
        >
          <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            {process.conformityAttempts.map((attempt) => (
              <article
                key={attempt.id}
                className={`rounded-xl border p-4 ${attempt.active ? "border-copper/35 bg-copper/[0.06]" : "border-white/8 bg-white/[0.02]"}`}
              >
                <div className="flex items-center justify-between gap-2">
                  <strong className="text-sm text-foreground">
                    Tentativa {attempt.attemptNumber}
                  </strong>
                  <span className="text-[10px] uppercase tracking-wider text-muted-foreground">
                    {attempt.active ? "Atual" : "Encerrada"}
                  </span>
                </div>
                <dl className="mt-3 space-y-1 text-xs text-muted-foreground">
                  <div>
                    Entrada:{" "}
                    <span className="text-foreground">{attempt.entryDate ?? "Pendente"}</span>
                  </div>
                  <div>
                    Resultado:{" "}
                    <span className="text-foreground">
                      {attempt.result === "conform"
                        ? "Conforme"
                        : attempt.result === "nonconform"
                          ? "Inconforme"
                          : "Pendente"}
                    </span>
                  </div>
                  {attempt.returnDate ? (
                    <div>
                      Retorno: <span className="text-foreground">{attempt.returnDate}</span>
                    </div>
                  ) : null}
                </dl>
                {attempt.nonconformityReason ? (
                  <p className="mt-3 rounded-lg bg-rose-400/8 p-2 text-xs text-rose-100/80">
                    {attempt.nonconformityReason}
                  </p>
                ) : null}
              </article>
            ))}
          </div>
        </Panel>
      ) : null}

      <div className="grid min-w-0 gap-5 lg:grid-cols-2">
        <Panel
          title="Checklist documental"
          subtitle={`${process.documents.filter((item) => item.status === "received").length}/${process.documents.length} recebidos`}
        >
          <div className="space-y-2">
            {process.documents.map((document) => (
              <button
                key={document.id}
                disabled={!isOperator || pending || process.documentationComplete}
                onClick={() =>
                  void update("document_status", {
                    document_id: document.id,
                    status: document.status === "received" ? "pending" : "received",
                  })
                }
                className={`flex w-full items-center justify-between rounded-xl border p-3 text-left text-sm transition ${document.status === "received" ? "border-emerald-400/30 bg-emerald-400/10 text-emerald-100" : "border-rose-400/25 bg-rose-400/8 text-rose-100"}`}
              >
                <span>{document.label}</span>
                {document.status === "received" ? (
                  <CheckCircle2 size={17} />
                ) : (
                  <CircleAlert size={17} />
                )}
              </button>
            ))}
          </div>
        </Panel>
        <Panel title="Histórico imutável" subtitle={`${process.history.length} evento(s)`}>
          <div className="max-h-[480px] space-y-3 overflow-y-auto pr-1">
            {process.history.map((item) => (
              <article key={item.id} className="relative border-l border-copper/30 pl-4">
                <span className="absolute -left-1.5 top-1 h-3 w-3 rounded-full border border-copper bg-background" />
                <div className="flex flex-wrap items-start justify-between gap-2">
                  <strong className="text-xs text-foreground">
                    {actionLabels[item.action] ?? displayText(item.action)}
                  </strong>
                  <time className="text-[10px] text-muted-foreground">
                    {dateTime(item.createdAt)}
                  </time>
                </div>
                <p className="mt-1 text-[11px] text-muted-foreground">
                  {item.actorName}
                  {item.attemptNumber ? ` · Tentativa ${item.attemptNumber}` : ""}
                </p>
                {item.oldValue !== null && item.oldValue !== undefined ? (
                  <p className="mt-1 text-[11px] text-muted-foreground">
                    Antes: {formatHistoryValue(item.oldValue)}
                  </p>
                ) : null}
                {item.newValue !== null && item.newValue !== undefined ? (
                  <p className="text-[11px] text-foreground/80">
                    Depois: {formatHistoryValue(item.newValue)}
                  </p>
                ) : null}
                {item.note ? (
                  <p className="mt-1 rounded-lg bg-white/[0.03] p-2 text-[11px] text-muted-foreground">
                    {item.note}
                  </p>
                ) : null}
              </article>
            ))}
          </div>
        </Panel>
      </div>
    </div>
  );
}

function CurrentStep({
  process,
  activeAttempt,
  form,
  set,
  pending,
  update,
  viewStage,
}: {
  process: FinancingProcess;
  activeAttempt?: FinancingProcess["conformityAttempts"][number];
  form: FormValues;
  set: (key: string, value: string) => void;
  pending: boolean;
  update: (action: string, payload: Record<string, unknown>) => Promise<void>;
  viewStage?: FinancingStage;
}) {
  const stage = viewStage ?? process.currentStage;
  if (stage === "checklist")
    return (
      <Decision
        title="Checklist inicial enviado?"
        pending={pending}
        yes={() => update("checklist_sent", { sent: true })}
        no={() => update("checklist_sent", { sent: false })}
      />
    );
  if (stage === "documentation")
    return (
      <div>
        <p className="mb-3 text-sm text-muted-foreground">
          Marque os documentos recebidos. Voce pode concluir esta etapa mesmo sem todos os documentos em mãos se for adequado.
        </p>
        <Decision
          title="Documentação enviada para aprovação?"
          pending={pending}
          yes={() => update("documentation_complete", { complete: true })}
          no={() => update("documentation_complete", { complete: false })}
        />
      </div>
    );
  if (stage === "credit")
    return (
      <DecisionForm
        title="Aprovação do crédito"
        positiveLabel="Aprovado"
        negativeLabel="Negado"
        value={form.approvedValue}
        additionalTextValue={form.creditBank}
        reason={form.creditReason}
        setValue={(value) => set("approvedValue", value)}
        setAdditionalTextValue={(value) => set("creditBank", value)}
        setReason={(value) => set("creditReason", value)}
        valueLabel="Valor total aprovado (R$)"
        additionalTextLabel="Banco"
        valueType="number"
        pending={pending}
        onPositive={() =>
          update("credit_decision", {
            approved: true,
            approved_value: form.approvedValue,
            bank: form.creditBank,
          })
        }
        onNegative={() => update("credit_decision", { approved: false, reason: form.creditReason })}
      />
    );
  if (stage === "inspection") {
    const checklist = [
      { key: "property", label: "Documentação do imóvel" },
      { key: "seller_id", label: "Documento de identificação do vendedor" },
      { key: "seller_civil_status", label: "Documento de estado civil do vendedor" },
      { key: "seller_bank", label: "Dados bancarios vendedor" },
    ];
    return (
      <div className="space-y-4">
        <div className="space-y-2 rounded-xl border border-white/10 bg-white/[0.03] p-4">
          <strong className="block text-sm text-foreground">Checklist de Vistoria</strong>
          <div className="mt-2 space-y-2">
            {checklist.map(({ key, label }) => {
              const checked = process.inspectionChecklist[key];
              return (
                <button
                  key={key}
                  disabled={pending}
                  onClick={() => update("inspection_checklist", { [key]: !checked })}
                  className={`flex w-full items-center justify-between rounded-lg border p-2.5 text-left text-sm transition ${
                    checked
                      ? "border-emerald-400/30 bg-emerald-400/10 text-emerald-100"
                      : "border-white/10 bg-white/[0.02] text-muted-foreground hover:bg-white/[0.05]"
                  }`}
                >
                  <span>{label}</span>
                  {checked && <CheckCircle2 size={16} />}
                </button>
              );
            })}
          </div>
        </div>
        <Decision
          title="Pedido de vistoria/avaliação realizado?"
          pending={pending}
          yes={() => update("inspection_request", { requested: true })}
          no={() => update("inspection_request", { requested: false })}
        />
      </div>
    );
  }
  if (stage === "report")
    return (
      <DecisionForm
        title="Recebimento do laudo"
        positiveLabel="Aprovado"
        negativeLabel="Negado"
        value={form.reportValue}
        reason={form.reportReason}
        setValue={(value) => set("reportValue", value)}
        setReason={(value) => set("reportReason", value)}
        valueLabel="Valor da avaliação do imóvel (R$)"
        pending={pending}
        onPositive={() =>
          update("report_result", { result: "approved", property_value: form.reportValue })
        }
        onNegative={() => update("report_result", { result: "denied", reason: form.reportReason })}
      />
    );
  if (stage === "conformity") {
    if (!activeAttempt?.entryDate)
      return (
        <DateAction
          label={`Data de entrada da conformidade · Tentativa ${activeAttempt?.attemptNumber ?? 1}`}
          value={form.conformityEntry}
          setValue={(value) => set("conformityEntry", value)}
          button="Registrar entrada"
          pending={pending}
          action={() => update("conformity_start", { entry_date: form.conformityEntry })}
        />
      );
    if (activeAttempt.result === "nonconform")
      return (
        <div className="rounded-xl border border-rose-400/25 bg-rose-400/8 p-4">
          <strong className="text-sm text-rose-100">Conformidade inconforme</strong>
          <p className="mt-1 text-xs text-rose-100/70">{activeAttempt.nonconformityReason}</p>
          <Button
            className="mt-3 bg-copper text-white"
            disabled={pending}
            onClick={() => void update("conformity_restart", {})}
          >
            {pending ? <Loader2 className="animate-spin" /> : <RefreshCw />}Reiniciar conformidade
          </Button>
        </div>
      );
    return (
      <div className="grid gap-3 sm:grid-cols-2">
        <label className="text-xs text-muted-foreground">
          Data de retorno (obrigatoria se conforme)
          <input
            type="date"
            value={form.conformityReturn}
            onChange={(e) => set("conformityReturn", e.target.value)}
            className="form-input"
          />
        </label>
        <label className="text-xs text-muted-foreground">
          Motivo (obrigatorio se inconforme)
          <textarea
            value={form.conformityReason}
            onChange={(e) => set("conformityReason", e.target.value)}
            className="form-input min-h-20"
          />
        </label>
        <label className="text-xs text-muted-foreground sm:col-span-2">
          Valor do financiamento (R$)
          <input
            type="number"
            value={form.financingValue || ""}
            onChange={(e) => set("financingValue", e.target.value)}
            className="form-input"
            placeholder="Obrigatório caso esteja conforme"
          />
        </label>
        <div className="flex gap-2 sm:col-span-2">
          <SaveButton
            pending={pending}
            onClick={() =>
              update("conformity_result", { result: "conform", return_date: form.conformityReturn, financing_value: form.financingValue })
            }
          >
            Conforme
          </SaveButton>
          <Button
            variant="outline"
            disabled={pending}
            onClick={() =>
              void update("conformity_result", {
                result: "nonconform",
                reason: form.conformityReason,
              })
            }
          >
            Inconforme
          </Button>
        </div>
      </div>
    );
  }
  if (stage === "committee")
    return (
      <DateAction
        label="Data de envio ao comite"
        value={form.committeeDate}
        setValue={(value) => set("committeeDate", value)}
        button="Registrar comite"
        pending={pending}
        action={() => update("committee_date", { date: form.committeeDate })}
      />
    );
  if (stage === "minutes")
    return (
      <Decision
        title="Minuta emitida?"
        pending={pending}
        yes={() => update("minutes_issued", { issued: true })}
      />
    );
  if (stage === "notary")
    return (
      <div className="grid gap-3 sm:grid-cols-3">
        <Field
          label="Nome do cartório"
          value={form.notaryName}
          setValue={(value) => set("notaryName", value)}
        />
        <DateField
          label="Data da escritura"
          value={form.deedDate}
          setValue={(value) => set("deedDate", value)}
        />
        <DateField
          label="Data da assinatura"
          value={form.signingDate}
          setValue={(value) => set("signingDate", value)}
        />
        <SaveButton
          pending={pending}
          className="sm:col-span-3"
          onClick={() =>
            update("notary_complete", {
              notary_name: form.notaryName,
              deed_date: form.deedDate,
              signing_date: form.signingDate,
            })
          }
        >
          Concluir Cartório de Notas
        </SaveButton>
      </div>
    );
  if (stage === "registry_details")
    return (
      <div className="grid gap-3 sm:grid-cols-2">
        <Field
          label="Numero do protocolo de registro"
          value={form.registryProtocol}
          setValue={(value) => set("registryProtocol", value)}
        />
        <DateField
          label="Previsao de entrega"
          value={form.registryDelivery}
          setValue={(value) => set("registryDelivery", value)}
        />
        <SaveButton
          pending={pending}
          className="sm:col-span-2"
          onClick={() =>
            update("registry_details", {
              protocol: form.registryProtocol,
              expected_delivery: form.registryDelivery,
            })
          }
        >
          Salvar dados do registro
        </SaveButton>
      </div>
    );
  if (stage === "registry_phase")
    return (
      <RegistryPhaseControl
        value={form.registryPhase}
        set={set}
        pending={pending}
        update={update}
      />
    );
  if (stage === "release_conformity") {
    if (!process.releaseConformityEntryDate)
      return (
        <DateAction
          label="Data de entrada da conformidade de liberação"
          value={form.releaseEntry}
          setValue={(value) => set("releaseEntry", value)}
          button="Registrar entrada"
          pending={pending}
          action={() => update("release_entry", { entry_date: form.releaseEntry })}
        />
      );
    return (
      <DecisionForm
        title="Conformidade de liberação de credito"
        positiveLabel="Conforme"
        negativeLabel="Não conforme"
        value={form.releaseDate}
        reason={form.releaseReason}
        setValue={(value) => set("releaseDate", value)}
        setReason={(value) => set("releaseReason", value)}
        valueLabel="Data do credito/liberação"
        valueType="date"
        pending={pending}
        onPositive={() =>
          update("release_decision", { conform: true, credit_release_date: form.releaseDate })
        }
        onNegative={() =>
          update("release_decision", { conform: false, reason: form.releaseReason })
        }
      />
    );
  }
  return (
    <div className="rounded-xl border border-emerald-400/30 bg-emerald-400/10 p-5 text-center">
      <BadgeCheck className="mx-auto text-emerald-300" size={34} />
      <strong className="mt-3 block text-emerald-100">Financiamento concluido</strong>
      <p className="mt-1 text-sm text-emerald-100/70">
        Credito liberado em{" "}
        {process.creditReleaseDate
          ? new Date(`${process.creditReleaseDate}T12:00:00`).toLocaleDateString("pt-BR")
          : "data registrada"}
        .
      </p>
    </div>
  );
}

function RegistryPhaseControl({
  value,
  set,
  pending,
  update,
}: {
  value: string;
  set: (key: string, value: string) => void;
  pending: boolean;
  update: (action: string, payload: Record<string, unknown>) => Promise<void>;
}) {
  const tone =
    value === "ready"
      ? "border-emerald-400/40"
      : value === "registering"
        ? "border-sky-400/40"
        : "border-amber-400/40";
  return (
    <div className={`rounded-xl border ${tone} p-4`}>
      <label className="text-xs text-muted-foreground">
        Fase do Registro
        <select
          value={value}
          onChange={(e) => set("registryPhase", e.target.value)}
          className="form-input"
        >
          <option value="examination">Em exame</option>
          <option value="registering">Registrando</option>
          <option value="ready">Pronto</option>
        </select>
      </label>
      <SaveButton
        pending={pending}
        className="mt-3"
        onClick={() => update("registry_phase", { phase: value })}
      >
        Atualizar fase
      </SaveButton>
    </div>
  );
}

function DecisionForm({
  title,
  positiveLabel,
  negativeLabel,
  value,
  secondaryValue,
  additionalTextValue,
  reason,
  setValue,
  setSecondaryValue,
  setAdditionalTextValue,
  setReason,
  valueLabel,
  secondaryValueLabel,
  additionalTextLabel,
  valueType = "text",
  pending,
  onPositive,
  onNegative,
}: {
  title: string;
  positiveLabel: string;
  negativeLabel: string;
  value: string;
  secondaryValue?: string;
  additionalTextValue?: string;
  reason: string;
  setValue: (value: string) => void;
  setSecondaryValue?: (value: string) => void;
  setAdditionalTextValue?: (value: string) => void;
  setReason: (value: string) => void;
  valueLabel: string;
  secondaryValueLabel?: string;
  additionalTextLabel?: string;
  valueType?: "number" | "date" | "text";
  pending: boolean;
  onPositive: () => Promise<void>;
  onNegative: () => Promise<void>;
}) {
  return (
    <div>
      <h3 className="text-sm font-semibold text-foreground">{title}</h3>
      <div className="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <label className="text-xs text-muted-foreground">
          {valueLabel}
          <input
            type={valueType}
            min={valueType === "number" ? "0.01" : undefined}
            step={valueType === "number" ? "0.01" : undefined}
            value={value}
            onChange={(e) => setValue(e.target.value)}
            className="form-input"
          />
        </label>
        {secondaryValueLabel && setSecondaryValue && (
          <label className="text-xs text-muted-foreground">
            {secondaryValueLabel}
            <input
              type={valueType}
              min={valueType === "number" ? "0.01" : undefined}
              step={valueType === "number" ? "0.01" : undefined}
              value={secondaryValue || ""}
              onChange={(e) => setSecondaryValue(e.target.value)}
              className="form-input"
            />
          </label>
        )}
        {additionalTextLabel && setAdditionalTextValue && (
          <label className="text-xs text-muted-foreground">
            {additionalTextLabel}
            <input
              type="text"
              value={additionalTextValue || ""}
              onChange={(e) => setAdditionalTextValue(e.target.value)}
              className="form-input"
              placeholder="Nome do banco"
            />
          </label>
        )}
        <label className={`text-xs text-muted-foreground ${secondaryValueLabel ? "" : "lg:col-span-2"}`}>
          Motivo / observação da negativa
          <textarea
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            className="form-input min-h-20"
          />
        </label>
      </div>
      <div className="mt-4 flex gap-2">
        <SaveButton pending={pending} onClick={onPositive}>
          <CheckCircle2 size={16} />
          {positiveLabel}
        </SaveButton>
        <SaveButton pending={pending} onClick={onNegative} variant="destructive">
          <XCircle size={16} />
          {negativeLabel}
        </SaveButton>
      </div>
    </div>
  );
}

function Decision({
  title,
  pending,
  yes,
  no,
}: {
  title: string;
  pending: boolean;
  yes: () => Promise<void>;
  no?: () => Promise<void>;
}) {
  return (
    <div>
      <h3 className="text-sm font-semibold text-foreground">{title}</h3>
      <div className="mt-3 flex gap-2">
        <SaveButton pending={pending} onClick={yes}>
          <Check size={15} />
          Sim
        </SaveButton>
        {no ? (
          <Button variant="outline" disabled={pending} onClick={() => void no()}>
            <X size={15} />
            Nao
          </Button>
        ) : null}
      </div>
    </div>
  );
}
function DateAction({
  label,
  value,
  setValue,
  button,
  pending,
  action,
}: {
  label: string;
  value: string;
  setValue: (value: string) => void;
  button: string;
  pending: boolean;
  action: () => Promise<void>;
}) {
  return (
    <div className="max-w-sm">
      <DateField label={label} value={value} setValue={setValue} />
      <SaveButton pending={pending} className="mt-3" onClick={action}>
        {button}
      </SaveButton>
    </div>
  );
}
function Field({
  label,
  value,
  setValue,
}: {
  label: string;
  value: string;
  setValue: (value: string) => void;
}) {
  return (
    <label className="text-xs text-muted-foreground">
      {label}
      <input value={value} onChange={(e) => setValue(e.target.value)} className="form-input" />
    </label>
  );
}
function DateField({
  label,
  value,
  setValue,
}: {
  label: string;
  value: string;
  setValue: (value: string) => void;
}) {
  return (
    <label className="text-xs text-muted-foreground">
      {label}
      <input
        type="date"
        value={value}
        onChange={(e) => setValue(e.target.value)}
        className="form-input"
      />
    </label>
  );
}
function SaveButton({
  pending,
  onClick,
  className = "",
  variant,
  children,
}: {
  pending: boolean;
  onClick: () => Promise<void>;
  className?: string;
  variant?: React.ComponentProps<typeof Button>["variant"];
  children: React.ReactNode;
}) {
  return (
    <Button
      variant={variant}
      className={`${variant === "destructive" ? "" : "bg-copper text-white hover:bg-copper/90"} ${className}`}
      disabled={pending}
      onClick={() => void onClick()}
    >
      {pending ? <Loader2 className="animate-spin" /> : null}
      {children}
    </Button>
  );
}
function FilterChip({
  active,
  onClick,
  children,
}: {
  active: boolean;
  onClick: () => void;
  children: React.ReactNode;
}) {
  return (
    <button
      onClick={onClick}
      className={`shrink-0 rounded-full border px-3 py-1.5 text-xs transition ${active ? "border-copper/50 bg-copper/15 text-copper" : "border-white/10 text-muted-foreground hover:bg-white/5"}`}
    >
      {children}
    </button>
  );
}
function Summary({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-xl border border-white/8 bg-white/[0.02] p-3">
      <dt className="text-[10px] uppercase tracking-wider text-muted-foreground">{label}</dt>
      <dd className="mt-1 break-words text-sm text-foreground">{value}</dd>
    </div>
  );
}
function LoadingState() {
  return (
    <div className="grid min-h-[60dvh] place-items-center">
      <Loader2 className="animate-spin text-copper" size={30} />
    </div>
  );
}
function ErrorState({ message, retry }: { message: string; retry: () => void }) {
  return (
    <Panel title="Não foi possível carregar" subtitle={message}>
      <Button variant="outline" onClick={retry}>
        <RefreshCw />
        Tentar novamente
      </Button>
    </Panel>
  );
}
function UnavailableState() {
  return (
    <Panel
      title="Módulo pronto para ativação"
      subtitle="A interface local está pronta; a migration ainda não foi aplicada ao Supabase online."
    >
      <div className="rounded-xl border border-amber-400/25 bg-amber-400/8 p-4 text-sm text-amber-100">
        <CircleAlert className="mb-2" size={20} />
        <p>
          Conforme combinado, nenhuma mudanca foi aplicada ao banco em uso. A ativacao ocorrera
          somente quando voce autorizar a publicacao e a migration.
        </p>
      </div>
    </Panel>
  );
}

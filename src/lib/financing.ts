import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/lib/supabase";
import { displayText } from "@/lib/display-text";

export type FinancingStage =
  | "checklist"
  | "documentation"
  | "credit"
  | "inspection"
  | "report"
  | "conformity"
  | "committee"
  | "minutes"
  | "notary"
  | "registry_details"
  | "registry_phase"
  | "release_conformity"
  | "completed";

export type FinancingStatus =
  | "pending"
  | "in_progress"
  | "awaiting_documents"
  | "awaiting_conformity"
  | "awaiting_registry"
  | "inspection_not_requested"
  | "release_nonconform"
  | "credit_denied"
  | "report_denied"
  | "completed";

export type FinancingDocument = {
  id: string;
  documentKey: string;
  label: string;
  position: number;
  status: "pending" | "received";
  receivedAt?: string;
};

export type ConformityAttempt = {
  id: string;
  attemptNumber: number;
  entryDate?: string;
  result?: "conform" | "nonconform";
  returnDate?: string;
  nonconformityReason?: string;
  active: boolean;
  startedAt: string;
  decidedAt?: string;
  restartedAt?: string;
};

export type FinancingHistoryItem = {
  id: string;
  stage: string;
  action: string;
  fieldName?: string;
  oldValue?: unknown;
  newValue?: unknown;
  actorName: string;
  note?: string;
  attemptNumber?: number;
  createdAt: string;
};

export type FinancingProcess = {
  id: string;
  leadId: string;
  leadName: string;
  leadPhone?: string;
  propertyInterest?: string;
  leadValue: number;
  brokerId: string;
  brokerName: string;
  operatorId: string;
  currentStage: FinancingStage;
  status: FinancingStatus;
  activatedAt: string;
  checklistSent: boolean;
  checklistSentAt?: string;
  documentationComplete: boolean;
  documentationCompletedAt?: string;
  creditApproved?: boolean;
  creditApprovedValue?: number;
  creditBank?: string;
  creditFinancingValue?: number;
  creditDenialReason?: string;
  inspectionRequested?: boolean;
  reportResult?: "approved" | "denied";
  reportPropertyValue?: number;
  reportDenialReason?: string;
  committeeSentDate?: string;
  minutesIssued: boolean;
  minutesIssuedAt?: string;
  notaryName?: string;
  deedDate?: string;
  deedSigningDate?: string;
  registryOpenedAt?: string;
  registryProtocol?: string;
  registryExpectedDelivery?: string;
  registryPhase?: "examination" | "registering" | "ready";
  releaseConformityEntryDate?: string;
  releaseConform?: boolean;
  releaseDenialReason?: string;
  creditReleaseDate?: string;
  completedAt?: string;
  version: number;
  updatedAt: string;
  documents: FinancingDocument[];
  conformityAttempts: ConformityAttempt[];
  history: FinancingHistoryItem[];
  inspectionChecklist: Record<string, boolean>;
};

type RawProcess = Record<string, unknown> & {
  id: string;
  lead_id: string;
  broker_id: string;
  operator_id: string;
  current_stage: FinancingStage;
  status: FinancingStatus;
  activated_at: string;
  checklist_sent: boolean;
  documentation_complete: boolean;
  minutes_issued: boolean;
  version: number;
  updated_at: string;
  inspection_checklist?: Record<string, boolean>;
  credit_financing_value?: number;
  lead?: {
    name?: string;
    phone?: string;
    property_interest?: string;
    budget?: number | string;
  } | null;
  broker?: { full_name?: string; email?: string } | null;
};

function optionalString(value: unknown) {
  return typeof value === "string" && value ? value : undefined;
}

function optionalBoolean(value: unknown) {
  return typeof value === "boolean" ? value : undefined;
}

function optionalNumber(value: unknown) {
  if (value === null || value === undefined || value === "") return undefined;
  const number = Number(value);
  return Number.isFinite(number) ? number : undefined;
}

function mapProcess(
  raw: RawProcess,
  documents: FinancingDocument[],
  conformityAttempts: ConformityAttempt[],
  history: FinancingHistoryItem[],
): FinancingProcess {
  return {
    id: raw.id,
    leadId: raw.lead_id,
    leadName: raw.lead?.name || "Lead",
    leadPhone: optionalString(raw.lead?.phone),
    propertyInterest: optionalString(raw.lead?.property_interest),
    leadValue: Number(raw.lead?.budget ?? 0),
    brokerId: raw.broker_id,
    brokerName: raw.broker?.full_name || raw.broker?.email || "Corretor",
    operatorId: raw.operator_id,
    currentStage: raw.current_stage,
    status: raw.status,
    activatedAt: raw.activated_at,
    checklistSent: raw.checklist_sent,
    checklistSentAt: optionalString(raw.checklist_sent_at),
    documentationComplete: raw.documentation_complete,
    documentationCompletedAt: optionalString(raw.documentation_completed_at),
    creditApproved: optionalBoolean(raw.credit_approved),
    creditApprovedValue: optionalNumber(raw.credit_approved_value),
    creditBank: optionalString(raw.credit_bank),
    creditFinancingValue: optionalNumber(raw.credit_financing_value),
    creditDenialReason: optionalString(raw.credit_denial_reason),
    inspectionRequested: optionalBoolean(raw.inspection_requested),
    reportResult: optionalString(raw.report_result) as FinancingProcess["reportResult"],
    reportPropertyValue: optionalNumber(raw.report_property_value),
    reportDenialReason: optionalString(raw.report_denial_reason),
    committeeSentDate: optionalString(raw.committee_sent_date),
    minutesIssued: raw.minutes_issued,
    minutesIssuedAt: optionalString(raw.minutes_issued_at),
    notaryName: optionalString(raw.notary_name),
    deedDate: optionalString(raw.deed_date),
    deedSigningDate: optionalString(raw.deed_signing_date),
    registryOpenedAt: optionalString(raw.registry_opened_at),
    registryProtocol: optionalString(raw.registry_protocol),
    registryExpectedDelivery: optionalString(raw.registry_expected_delivery),
    registryPhase: optionalString(raw.registry_phase) as FinancingProcess["registryPhase"],
    releaseConformityEntryDate: optionalString(raw.release_conformity_entry_date),
    releaseConform: optionalBoolean(raw.release_conform),
    releaseDenialReason: optionalString(raw.release_denial_reason),
    creditReleaseDate: optionalString(raw.credit_release_date),
    completedAt: optionalString(raw.completed_at),
    version: Number(raw.version),
    updatedAt: raw.updated_at,
    documents,
    conformityAttempts,
    history,
    inspectionChecklist: raw.inspection_checklist ?? {},
  };
}

export function isFinancingUnavailableError(error: unknown) {
  const value = error as { code?: string; message?: string } | null;
  return (
    value?.code === "42P01" ||
    value?.code === "PGRST202" ||
    value?.code === "PGRST205" ||
    /crm_financing|is_financing_operator|schema cache/i.test(value?.message ?? "")
  );
}

async function getFinancingProcesses() {
  const [processResult, documentResult, conformityResult, historyResult] = await Promise.all([
    supabase
      .from("crm_financing_processes")
      .select(
        "*, lead:crm_leads!crm_financing_processes_lead_id_fkey(name, phone, property_interest, budget), broker:profiles!crm_financing_processes_broker_id_fkey(full_name, email)",
      )
      .order("updated_at", { ascending: false }),
    supabase
      .from("crm_financing_documents")
      .select("id, process_id, document_key, label, position, status, received_at")
      .order("position"),
    supabase
      .from("crm_financing_conformity_attempts")
      .select(
        "id, process_id, attempt_number, entry_date, result, return_date, nonconformity_reason, active, started_at, decided_at, restarted_at",
      )
      .order("attempt_number", { ascending: false }),
    supabase
      .from("crm_financing_history")
      .select(
        "id, process_id, stage, action, field_name, old_value, new_value, actor_name, note, attempt_number, created_at",
      )
      .order("created_at", { ascending: false }),
  ]);
  const error =
    processResult.error ?? documentResult.error ?? conformityResult.error ?? historyResult.error;
  if (error) throw error;

  const documentsByProcess = new Map<string, FinancingDocument[]>();
  for (const item of documentResult.data ?? []) {
    const list = documentsByProcess.get(item.process_id) ?? [];
    list.push({
      id: item.id,
      documentKey: item.document_key,
      label: displayText(item.label),
      position: item.position,
      status: item.status as FinancingDocument["status"],
      receivedAt: optionalString(item.received_at),
    });
    documentsByProcess.set(item.process_id, list);
  }
  const attemptsByProcess = new Map<string, ConformityAttempt[]>();
  for (const item of conformityResult.data ?? []) {
    const list = attemptsByProcess.get(item.process_id) ?? [];
    list.push({
      id: item.id,
      attemptNumber: item.attempt_number,
      entryDate: optionalString(item.entry_date),
      result: optionalString(item.result) as ConformityAttempt["result"],
      returnDate: optionalString(item.return_date),
      nonconformityReason: optionalString(item.nonconformity_reason),
      active: item.active,
      startedAt: item.started_at,
      decidedAt: optionalString(item.decided_at),
      restartedAt: optionalString(item.restarted_at),
    });
    attemptsByProcess.set(item.process_id, list);
  }
  const historyByProcess = new Map<string, FinancingHistoryItem[]>();
  for (const item of historyResult.data ?? []) {
    const list = historyByProcess.get(item.process_id) ?? [];
    list.push({
      id: item.id,
      stage: item.stage,
      action: item.action,
      fieldName: optionalString(item.field_name),
      oldValue: item.old_value,
      newValue: item.new_value,
      actorName: item.actor_name,
      note: optionalString(item.note),
      attemptNumber: optionalNumber(item.attempt_number),
      createdAt: item.created_at,
    });
    historyByProcess.set(item.process_id, list);
  }
  return ((processResult.data ?? []) as RawProcess[]).map((raw) =>
    mapProcess(
      raw,
      documentsByProcess.get(raw.id) ?? [],
      attemptsByProcess.get(raw.id) ?? [],
      historyByProcess.get(raw.id) ?? [],
    ),
  );
}

export async function getFinancingProcessByLead(leadId: string) {
  const { data, error } = await supabase
    .from("crm_financing_processes")
    .select("id")
    .eq("lead_id", leadId)
    .maybeSingle();
  if (error) throw error;
  return data?.id ? String(data.id) : null;
}

export function useFinancingProcesses(enabled = true) {
  return useQuery({
    queryKey: ["crm-financing-processes"],
    queryFn: getFinancingProcesses,
    enabled,
    staleTime: 15_000,
  });
}

export function useFinancingPermission(enabled = true) {
  return useQuery({
    queryKey: ["crm-financing-permission"],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("is_financing_operator");
      if (error) {
        if (isFinancingUnavailableError(error)) return false;
        throw error;
      }
      return Boolean(data);
    },
    enabled,
    staleTime: 60_000,
  });
}

export function useStartLeadFinancing() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: async (leadId: string) => {
      const { data, error } = await supabase.rpc("start_lead_financing", { p_lead_id: leadId });
      if (error) throw new Error(displayText(error.message));
      return String(data);
    },
    onSuccess: async () => {
      await client.invalidateQueries({ queryKey: ["crm-financing-processes"] });
    },
  });
}

export type FinancingUpdateInput = {
  processId: string;
  action: string;
  payload?: Record<string, unknown>;
  expectedVersion: number;
  note?: string;
};

export function useUpdateFinancingProcess() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: async (input: FinancingUpdateInput) => {
      if (typeof navigator !== "undefined" && !navigator.onLine) {
        throw new Error("Sem conexao. Reconecte-se antes de salvar esta etapa.");
      }
      const rpcName =
        input.action === "credit_decision"
          ? "update_financing_credit_decision"
          : "update_financing_process";
      const { data, error } = await supabase.rpc(rpcName, {
        p_process_id: input.processId,
        p_payload: input.payload ?? {},
        p_expected_version: input.expectedVersion,
        p_note: input.note?.trim() || null,
        ...(rpcName === "update_financing_process" ? { p_action: input.action } : {}),
      });
      if (error) throw new Error(displayText(error.message));
      return Number(data);
    },
    onSuccess: async () => {
      await client.invalidateQueries({ queryKey: ["crm-financing-processes"] });
      await client.invalidateQueries({ queryKey: ["crm-notifications"] });
    },
  });
}

export function useDeleteFinancingProcess() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: async (processId: string) => {
      const { data, error } = await supabase.rpc("delete_financing_process", {
        p_process_id: processId,
      });
      if (error) throw new Error(displayText(error.message));
      return String(data);
    },
    onSuccess: async () => {
      await client.invalidateQueries({ queryKey: ["crm-financing-processes"] });
      await client.invalidateQueries({ queryKey: ["crm-notifications"] });
    },
  });
}

export const FINANCING_STAGES: Array<{ key: FinancingStage; label: string }> = [
  { key: "checklist", label: "Checklist inicial" },
  { key: "documentation", label: "Documentacao" },
  { key: "credit", label: "Aprovacao do credito" },
  { key: "inspection", label: "Vistoria" },
  { key: "report", label: "Laudo" },
  { key: "conformity", label: "Conformidade" },
  { key: "committee", label: "Comite" },
  { key: "minutes", label: "Minuta" },
  { key: "notary", label: "Cartorio de Notas" },
  { key: "registry_details", label: "Registro de Imoveis" },
  { key: "registry_phase", label: "Fase do registro" },
  { key: "release_conformity", label: "Liberacao de credito" },
  { key: "completed", label: "Concluido" },
];

export function financingProgress(stage: FinancingStage) {
  const index = FINANCING_STAGES.findIndex((item) => item.key === stage);
  return Math.max(0, Math.round((index / (FINANCING_STAGES.length - 1)) * 100));
}

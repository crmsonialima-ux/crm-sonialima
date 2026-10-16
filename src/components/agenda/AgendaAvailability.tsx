import { useQuery, useQueryClient } from "@tanstack/react-query";
import {
  CalendarDays,
  CheckCircle2,
  ChevronLeft,
  ChevronRight,
  Download,
  Loader2,
  Paperclip,
  Pencil,
  Save,
  Trash2,
  X,
} from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { supabase } from "@/lib/supabase";
import type { AccessProfile } from "@/lib/lead-access";
import { displayText } from "@/lib/display-text";
import { SaleTransferDocuments } from "@/components/agenda/SaleTransferDocuments";

const labels = {
  neo_energia: "NEO Energia",
  caesb: "Caesb",
  cartorio: "Cartório",
  observacao: "Observação",
};
const agendaModalStorageKey = "sonialima:agenda-open-modal";

function agendaPersonName(person?: { full_name?: string | null; email?: string | null }) {
  if (person?.email?.trim().toLowerCase() === "crmsoniaallyson@gmail.com") return "Allyson";
  return person?.full_name || person?.email || "Não identificado";
}

function createFileId() {
  const bytes = new Uint8Array(16);
  globalThis.crypto.getRandomValues(bytes);
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

type ProtocolVersion = {
  version: number;
  entry_date?: string | null;
  expected_date?: string | null;
  paths?: string[] | null;
  saved_at?: string | null;
  received_at?: string | null;
  delivered_to_vitor_at?: string | null;
};

type AgendaEntry = {
  id: string;
  category: keyof typeof labels;
  scheduled_at: string;
  observation: string;
  target_user_id: string;
  created_by: string;
  feedback_at: string | null;
  feedback_note: string | null;
  feedback_history?: { at?: string; note?: string | null; stage?: string | null }[] | null;
  cartorio_client_name?: string | null;
  cartorio_property_address?: string | null;
  cartorio_name?: string | null;
  cartorio_service?: string | null;
  demand_client_name?: string | null;
  demand_property_address?: string | null;
  demand_service?: string | null;
  protocol_path?: string | null;
  protocol_paths?: string[] | null;
  protocol_uploaded_at?: string | null;
  protocol_entry_date?: string | null;
  protocol_expected_date?: string | null;
  cartorio_received_at?: string | null;
  cartorio_delivered_to_vitor_at?: string | null;
  cartorio_protocol_versions?: ProtocolVersion[] | null;
  cartorio_protocol_revision_count?: number | null;
  cartorio_vitor_document_paths?: string[] | null;
  cartorio_vitor_document_uploaded_at?: string | null;
  cartorio_vitor_document_uploaded_by?: string | null;
  cartorio_protocol_observation?: string | null;
  cartorio_protocol_observation_at?: string | null;
  source_kind?: string | null;
  source_lead_id?: string | null;
  source_sale_id?: string | null;
  sale_task_kind?: string | null;
  sale_task_due_at?: string | null;
  sale_documents_completed_at?: string | null;
  created_by_email?: string | null;
  target?: { full_name?: string | null; email?: string | null };
  creator?: { full_name?: string | null; email?: string | null };
  participants?: { user_id: string }[];
  companion_reason?: string | null;
};

type AgendaEditForm = {
  category: keyof typeof labels;
  when: string;
  targetUserId: string;
  observation: string;
  clientName: string;
  propertyAddress: string;
  notaryName: string;
  service: string;
  companions: string[];
  companionReason: string;
};

type PendingProtocol = { files: File[]; entryDate: string; expectedDate: string };

type VisitFinalStage = "Visita realizada" | "Proposta";
type VisitVisualStatus = "scheduled" | "in_progress" | "completed" | "proposal";

function toLocalDateTimeInput(value: string) {
  const date = new Date(value);
  return new Date(date.getTime() - date.getTimezoneOffset() * 60_000).toISOString().slice(0, 16);
}

export function AgendaAvailability({
  brokers,
  profile,
}: {
  brokers: AccessProfile[];
  profile?: AccessProfile;
}) {
  const [selectedBrokerId, setSelectedBrokerId] = useState(brokers[0]?.id ?? "");
  const [selectedEntries, setSelectedEntries] = useState<AgendaEntry[] | null>(null);
  const [feedback, setFeedback] = useState<Record<string, string>>({});
  const [visitStages, setVisitStages] = useState<Record<string, "Visita realizada" | "Proposta">>(
    {},
  );
  const [editingVisitResults, setEditingVisitResults] = useState<Record<string, boolean>>({});
  const [visitPropertyCaptured, setVisitPropertyCaptured] = useState<
    Record<string, boolean | undefined>
  >({});
  const [pendingProtocols, setPendingProtocols] = useState<Record<string, PendingProtocol>>({});
  const [pendingVitorDocuments, setPendingVitorDocuments] = useState<Record<string, File[]>>({});
  const [editingProtocol, setEditingProtocol] = useState<Record<string, boolean>>({});
  const [editingEntryId, setEditingEntryId] = useState<string | null>(null);
  const [editForm, setEditForm] = useState<AgendaEditForm | null>(null);
  const [editDraftRestored, setEditDraftRestored] = useState(false);
  const [savingEntryId, setSavingEntryId] = useState<string | null>(null);
  const [savingVisitId, setSavingVisitId] = useState<string | null>(null);
  const [savingProtocolId, setSavingProtocolId] = useState<string | null>(null);
  const [savingVitorDocumentId, setSavingVitorDocumentId] = useState<string | null>(null);
  const [savingMilestoneId, setSavingMilestoneId] = useState<string | null>(null);
  const [deletingAttachmentKey, setDeletingAttachmentKey] = useState<string | null>(null);
  const [cartorioObservations, setCartorioObservations] = useState<Record<string, string>>({});
  const [savingCartorioObservationId, setSavingCartorioObservationId] = useState<string | null>(
    null,
  );
  const [error, setError] = useState("");
  const [attachmentNotice, setAttachmentNotice] = useState<Record<string, string>>({});
  const [agendaNow, setAgendaNow] = useState(() => Date.now());
  const [visibleMonth, setVisibleMonth] = useState(() => {
    const today = new Date();
    return new Date(today.getFullYear(), today.getMonth(), 1);
  });
  const restoredModal = useRef(false);
  const initializedBroker = useRef(false);
  const selectedEntriesScrollRef = useRef<HTMLDivElement | null>(null);
  const cameraScrollTopRef = useRef(0);
  const activeFilePickerRef = useRef<{
    input: HTMLInputElement;
    entry: AgendaEntry;
    kind: "protocol" | "vitor";
    consumed: boolean;
  } | null>(null);
  const pickerRecoveryTimersRef = useRef<number[]>([]);
  const receivePickedFilesRef = useRef<((input: HTMLInputElement) => boolean) | null>(null);
  const queryClient = useQueryClient();
  const year = visibleMonth.getFullYear();
  const month = visibleMonth.getMonth();
  const firstDay = new Date(year, month, 1).getDay();
  const daysInMonth = new Date(year, month + 1, 0).getDate();
  const isAdmin = profile?.role === "admin";
  const editDraftKey = `sonialima:agenda-edit-draft:${profile?.id ?? "anonymous"}`;
  const protocolDraftKey = `sonialima:agenda-protocol-drafts:${profile?.id ?? "anonymous"}`;
  const email = (profile?.email ?? "").toLowerCase();
  const isAdministrador =
    email === "crmsoniaallyson@gmail.com" || email === "unassigned-institutional@example.invalid";
  const isDerleyProfile = email === "unassigned-agenda@example.invalid";
  const isVitorProfile = email === "unassigned-operator@example.invalid";
  const canViewProtocol = Boolean(profile?.id);
  const canViewVitorDocument = isAdmin || isDerleyProfile || isVitorProfile;
  const isLeadVisit = (entry: AgendaEntry) => entry.source_kind === "lead_visit";
  const isSaleTransfer = (entry: AgendaEntry) => entry.source_kind === "sale_transfer";
  const finalVisitFeedback = (entry: AgendaEntry) =>
    [...(entry.feedback_history ?? [])]
      .reverse()
      .find(
        (item): item is { at?: string; note?: string | null; stage: VisitFinalStage } =>
          (item.stage === "Visita realizada" || item.stage === "Proposta") &&
          Boolean(item.at) &&
          Number.isFinite(new Date(item.at!).getTime()) &&
          new Date(item.at!).getTime() >= new Date(entry.scheduled_at).getTime(),
      );
  const visitVisualStatus = (entry: AgendaEntry): VisitVisualStatus => {
    const finalStage = finalVisitFeedback(entry)?.stage;
    if (finalStage === "Visita realizada") return "completed";
    if (finalStage === "Proposta") return "proposal";
    return new Date(entry.scheduled_at).getTime() > agendaNow ? "scheduled" : "in_progress";
  };
  const visitStatusLabel = (status: VisitVisualStatus) => {
    if (status === "completed") return "Visita realizada";
    if (status === "proposal") return "Proposta";
    if (status === "in_progress") return "Em visita";
    return "Visita agendada";
  };
  const visitCalendarTone = (status: VisitVisualStatus) => {
    if (status === "completed") return "border border-emerald-400/40 bg-emerald-500/20";
    if (status === "proposal") return "border border-violet-400/40 bg-violet-500/20";
    if (status === "in_progress") return "border border-red-400/50 bg-red-500/20";
    return "border border-amber-400/40 bg-amber-500/20";
  };
  const visitCardTone = (status: VisitVisualStatus) => {
    if (status === "completed") return "border-emerald-400/35 bg-emerald-500/[0.08]";
    if (status === "proposal") return "border-violet-400/35 bg-violet-500/[0.08]";
    if (status === "in_progress") return "border-red-400/40 bg-red-500/[0.08]";
    return "border-amber-400/35 bg-amber-500/[0.08]";
  };
  const visitTextTone = (status: VisitVisualStatus) => {
    if (status === "completed") return "text-emerald-300";
    if (status === "proposal") return "text-violet-300";
    if (status === "in_progress") return "text-red-300";
    return "text-amber-300";
  };
  const calendarTone = (entry: AgendaEntry) => {
    if (isSaleTransfer(entry))
      return entry.sale_documents_completed_at
        ? "border border-emerald-400/40 bg-emerald-500/20"
        : "border border-red-400/50 bg-red-500/20";
    if (isLeadVisit(entry)) return visitCalendarTone(visitVisualStatus(entry));
    return entry.feedback_at ? "border border-emerald-400/30 bg-emerald-500/20" : "bg-copper/20";
  };
  const cardTone = (entry: AgendaEntry) => {
    if (isSaleTransfer(entry))
      return entry.sale_documents_completed_at
        ? "border-emerald-400/40 bg-emerald-500/[0.08]"
        : "border-red-400/40 bg-red-500/[0.08]";
    if (isLeadVisit(entry)) return visitCardTone(visitVisualStatus(entry));
    return entry.feedback_at ? "border-emerald-400/30 bg-emerald-500/[0.08]" : "border-white/10";
  };
  const entryLabel = (entry: AgendaEntry) => {
    if (isSaleTransfer(entry)) return "Transferências pós-entrega";
    if (entry.source_kind === "sale_delivery") return "Entrega do imóvel";
    if (entry.source_kind === "sale_followup") return "Ligação de pós-venda";
    if (!isLeadVisit(entry)) return labels[entry.category];
    return visitStatusLabel(visitVisualStatus(entry));
  };
  const entrySummary = (entry: AgendaEntry) => {
    if (isLeadVisit(entry)) {
      const originalSummary = entry.observation.split("\n")[0] || "Visita agendada";
      return originalSummary.replace(
        /^(?:Visita (?:agendada|reagendada|realizada)|Em visita|Proposta)/i,
        entryLabel(entry),
      );
    }
    if (entry.category === "cartorio") return entry.cartorio_service || "Cartório";
    return entry.demand_service || entry.observation;
  };
  const entryObservation = (entry: AgendaEntry) => {
    if (!isLeadVisit(entry)) return entry.observation;
    const lines = entry.observation.split("\n");
    return [entrySummary(entry), ...lines.slice(1)].join("\n");
  };
  const isParticipant = (entry: AgendaEntry) =>
    entry.participants?.some((participant) => participant.user_id === profile?.id) ?? false;
  const canManageEntry = (entry: AgendaEntry) => {
    if (!profile?.id) return false;
    if (entry.source_sale_id) return false;
    if (isAdministrador) return true;

    const isFuture = new Date(entry.scheduled_at).getTime() > agendaNow;
    if (!isFuture) return false;

    return (
      !isLeadVisit(entry) || isAdmin || entry.target_user_id === profile.id || isParticipant(entry)
    );
  };
  const canDeleteEntry = (entry: AgendaEntry) => {
    if (entry.source_sale_id) return false;
    if (isAdministrador) return true;
    const isFuture = new Date(entry.scheduled_at).getTime() > agendaNow;
    return isFuture && canManageEntry(entry);
  };
  const canRegisterVisitProgress = (entry: AgendaEntry) =>
    isLeadVisit(entry) &&
    Boolean(profile?.id) &&
    (isAdmin || entry.target_user_id === profile?.id || isParticipant(entry));

  useEffect(() => {
    const interval = window.setInterval(() => setAgendaNow(Date.now()), 30_000);
    return () => window.clearInterval(interval);
  }, []);

  const entries = useQuery({
    queryKey: ["agenda"],
    // Abrir a camera/galeria tira o foco da pagina no Android. Nao refaça a
    // agenda nesse retorno: alguns aparelhos substituem o input antes que o
    // Chrome entregue o FileList.
    refetchOnWindowFocus: false,
    refetchInterval: 30_000,
    refetchIntervalInBackground: true,
    queryFn: async () => {
      const sharedQuery = await supabase
        .from("crm_agenda_entries")
        .select(
          "*,target:profiles!crm_agenda_entries_target_user_id_fkey(full_name,email),creator:profiles!crm_agenda_entries_created_by_fkey(full_name,email),participants:crm_agenda_entry_participants(user_id)",
        )
        .eq("companion_approval_status", "approved")
        .order("scheduled_at");
      if (!sharedQuery.error) return (sharedQuery.data ?? []) as AgendaEntry[];

      // Mantém a prévia local utilizável antes da migração compartilhada ser publicada.
      const legacyQuery = await supabase
        .from("crm_agenda_entries")
        .select(
          "*,target:profiles!crm_agenda_entries_target_user_id_fkey(full_name,email),creator:profiles!crm_agenda_entries_created_by_fkey(full_name,email)",
        )
        .eq("companion_approval_status", "approved")
        .order("scheduled_at");
      if (legacyQuery.error) throw legacyQuery.error;
      return (legacyQuery.data ?? []).map((entry) => ({
        ...entry,
        participants: [],
      })) as AgendaEntry[];
    },
  });

  useEffect(() => {
    if (!profile?.id) return;
    let refreshTimer: ReturnType<typeof setTimeout> | undefined;
    const refreshAgenda = () => {
      if (refreshTimer) clearTimeout(refreshTimer);
      refreshTimer = setTimeout(() => {
        void queryClient.invalidateQueries({ queryKey: ["agenda"] });
      }, 150);
    };
    const channel = supabase
      .channel(`crm-agenda-live:${profile.id}`)
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "crm_agenda_entries" },
        refreshAgenda,
      )
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "crm_agenda_entry_participants" },
        refreshAgenda,
      )
      .subscribe();
    return () => {
      if (refreshTimer) clearTimeout(refreshTimer);
      void supabase.removeChannel(channel);
    };
  }, [profile?.id, queryClient]);

  useEffect(() => {
    if (!entries.data) return;
    setSelectedEntries((current) => {
      if (!current) return current;
      const refreshed = current
        .map((selected) => entries.data.find((entry) => entry.id === selected.id))
        .filter((entry): entry is AgendaEntry => Boolean(entry));
      return refreshed.length ? refreshed : null;
    });
  }, [entries.data]);

  const cells = Array.from({ length: 42 }, (_, index) => index - firstDay + 1);
  const orderedBrokers = profile?.id
    ? [...brokers].sort(
        (left, right) => Number(right.id === profile.id) - Number(left.id === profile.id),
      )
    : brokers;

  useEffect(() => {
    if (initializedBroker.current || !profile?.id || !brokers.length) return;
    initializedBroker.current = true;
    setSelectedBrokerId(
      brokers.some((broker) => broker.id === profile.id) ? profile.id : brokers[0].id,
    );
  }, [brokers, profile?.id]);

  useEffect(() => {
    if (restoredModal.current || !entries.data) return;
    restoredModal.current = true;
    try {
      const ids = JSON.parse(localStorage.getItem(agendaModalStorageKey) ?? "[]") as string[];
      const saved = entries.data.filter((entry) => ids.includes(entry.id));
      if (saved.length) setSelectedEntries(saved);
    } catch {
      localStorage.removeItem(agendaModalStorageKey);
    }
  }, [entries.data]);

  useEffect(() => {
    if (!entries.data?.length || typeof window === "undefined") return;
    const agendaId = new URLSearchParams(window.location.search).get("focusAgendaId");
    if (!agendaId) return;
    const entry = entries.data.find((item) => item.id === agendaId);
    if (entry) setSelectedEntries([entry]);
  }, [entries.data]);

  useEffect(() => {
    if (!restoredModal.current) return;
    if (selectedEntries?.length)
      localStorage.setItem(
        agendaModalStorageKey,
        JSON.stringify(selectedEntries.map((entry) => entry.id)),
      );
    else localStorage.removeItem(agendaModalStorageKey);
  }, [selectedEntries]);

  useEffect(() => {
    if (editDraftRestored || !entries.data) return;
    try {
      const saved = JSON.parse(localStorage.getItem(editDraftKey) ?? "null") as {
        entryId?: string;
        form?: AgendaEditForm;
      } | null;
      if (
        saved?.entryId &&
        saved.form &&
        entries.data.some((entry) => entry.id === saved.entryId)
      ) {
        setEditingEntryId(saved.entryId);
        setEditForm(saved.form);
      }
    } catch {
      localStorage.removeItem(editDraftKey);
    } finally {
      setEditDraftRestored(true);
    }
  }, [editDraftKey, editDraftRestored, entries.data]);

  useEffect(() => {
    if (!editDraftRestored) return;
    if (editingEntryId && editForm) {
      localStorage.setItem(
        editDraftKey,
        JSON.stringify({ entryId: editingEntryId, form: editForm }),
      );
    } else {
      localStorage.removeItem(editDraftKey);
    }
  }, [editDraftKey, editDraftRestored, editForm, editingEntryId]);

  useEffect(() => {
    try {
      const saved = JSON.parse(localStorage.getItem(protocolDraftKey) ?? "{}") as Record<
        string,
        Pick<PendingProtocol, "entryDate" | "expectedDate">
      >;
      setPendingProtocols((current) => {
        const next = { ...current };
        for (const [entryId, draft] of Object.entries(saved)) {
          next[entryId] = {
            files: next[entryId]?.files ?? [],
            entryDate: draft.entryDate ?? "",
            expectedDate: draft.expectedDate ?? "",
          };
        }
        return next;
      });
    } catch {
      localStorage.removeItem(protocolDraftKey);
    }
  }, [protocolDraftKey]);

  useEffect(() => {
    const serializable = Object.fromEntries(
      Object.entries(pendingProtocols)
        .filter(([, draft]) => draft.entryDate || draft.expectedDate)
        .map(([entryId, draft]) => [
          entryId,
          { entryDate: draft.entryDate, expectedDate: draft.expectedDate },
        ]),
    );
    if (Object.keys(serializable).length)
      localStorage.setItem(protocolDraftKey, JSON.stringify(serializable));
    else localStorage.removeItem(protocolDraftKey);
  }, [pendingProtocols, protocolDraftKey]);

  const pathsOf = (entry: AgendaEntry) =>
    entry.protocol_paths?.length
      ? entry.protocol_paths
      : entry.protocol_path
        ? [entry.protocol_path]
        : [];
  const pendingOf = (entry: AgendaEntry): PendingProtocol =>
    pendingProtocols[entry.id] ?? {
      files: [],
      entryDate: entry.protocol_entry_date ?? "",
      expectedDate: entry.protocol_expected_date ?? "",
    };
  const dateLabel = (value?: string | null) =>
    value ? new Date(`${value}T12:00:00`).toLocaleDateString("pt-BR") : "Não informado";
  const dateTimeLabel = (value?: string | null) =>
    value ? new Date(value).toLocaleString("pt-BR") : "Pendente";
  const replaceEntry = (id: string, update: Partial<AgendaEntry>) => {
    setSelectedEntries(
      (current) =>
        current?.map((entry) => (entry.id === id ? { ...entry, ...update } : entry)) ?? null,
    );
  };
  const refresh = () => queryClient.invalidateQueries({ queryKey: ["agenda"] });
  const closeSelectedEntries = () => {
    setSelectedEntries(null);
    if (typeof window === "undefined") return;
    const url = new URL(window.location.href);
    url.searchParams.delete("focusAgendaId");
    window.history.replaceState({}, "", `${url.pathname}${url.search}${url.hash}`);
  };

  async function registerFeedback(entry: AgendaEntry) {
    const registeredAt = new Date().toISOString();
    const note = feedback[entry.id]?.trim() ?? "";
    setError("");
    const { error: rpcError } = await supabase.rpc("feedback_agenda_entry", {
      p_id: entry.id,
      p_feedback_at: registeredAt,
      p_note: note,
    });
    if (rpcError) return setError(displayText(rpcError.message));
    replaceEntry(entry.id, {
      feedback_at: registeredAt,
      feedback_note: note || null,
      feedback_history: [
        ...(entry.feedback_history ?? []),
        { at: registeredAt, note: note || null },
      ],
    });
    void refresh();
  }

  async function registerVisitProgress(entry: AgendaEntry) {
    const note = feedback[entry.id]?.trim() ?? "";
    if (!note) return setError("Descreva o que aconteceu na visita.");
    const stage = visitStages[entry.id] ?? "Visita realizada";
    const captured = visitPropertyCaptured[entry.id];
    if (stage === "Visita realizada" && captured === undefined) {
      return setError("Informe se algum imóvel do cliente foi captado durante a visita.");
    }
    setSavingVisitId(entry.id);
    setError("");
    const { error: rpcError } = await supabase.rpc("register_agenda_lead_visit_progress", {
      p_entry_id: entry.id,
      p_stage: stage,
      p_note: note,
      p_visit_property_captured: stage === "Visita realizada" ? captured : null,
    });
    setSavingVisitId(null);
    if (rpcError) return setError(displayText(rpcError.message));
    const registeredAt = new Date().toISOString();
    replaceEntry(entry.id, {
      feedback_at: registeredAt,
      feedback_note: note,
      feedback_history: [...(entry.feedback_history ?? []), { at: registeredAt, note, stage }],
    });
    setFeedback((current) => ({ ...current, [entry.id]: "" }));
    setVisitPropertyCaptured((current) => ({ ...current, [entry.id]: undefined }));
    setEditingVisitResults((current) => ({ ...current, [entry.id]: false }));
    await Promise.all([
      queryClient.invalidateQueries({ queryKey: ["agenda"] }),
      queryClient.invalidateQueries({ queryKey: ["crm-leads"] }),
      queryClient.invalidateQueries({ queryKey: ["crm-lead-activities"] }),
    ]);
  }

  async function remove(id: string) {
    const { error: rpcError } = await supabase.rpc("delete_agenda_entry", { p_id: id });
    if (rpcError) return setError(displayText(rpcError.message));
    setSelectedEntries((current) => {
      const remaining = current?.filter((entry) => entry.id !== id) ?? [];
      return remaining.length ? remaining : null;
    });
    void refresh();
  }

  function startEditingEntry(entry: AgendaEntry) {
    setError("");
    setEditingEntryId(entry.id);
    setEditForm({
      category: entry.category,
      when: toLocalDateTimeInput(entry.scheduled_at),
      targetUserId: entry.target_user_id,
      observation: entry.category === "observacao" ? entry.observation : "",
      clientName: entry.cartorio_client_name ?? entry.demand_client_name ?? "",
      propertyAddress: entry.cartorio_property_address ?? entry.demand_property_address ?? "",
      notaryName: entry.cartorio_name ?? "",
      service: entry.cartorio_service ?? entry.demand_service ?? "",
      companions: entry.participants?.map((p) => p.user_id) ?? [],
      companionReason: entry.companion_reason ?? "",
    });
  }

  const updateEditForm = <K extends keyof AgendaEditForm>(key: K, value: AgendaEditForm[K]) =>
    setEditForm((current) => (current ? { ...current, [key]: value } : current));

  async function saveEditedEntry(entry: AgendaEntry) {
    if (!editForm || editingEntryId !== entry.id) return;
    if (!editForm.when) return setError("Informe data e hora.");
    setSavingEntryId(entry.id);
    setError("");
    const { data, error: rpcError } = await supabase.rpc("update_agenda_entry", {
      p_id: entry.id,
      p_category: editForm.category,
      p_scheduled_at: new Date(editForm.when).toISOString(),
      p_target_user_id: editForm.targetUserId,
      p_observation: editForm.observation,
      p_client_name: editForm.clientName,
      p_property_address: editForm.propertyAddress,
      p_cartorio_name: editForm.notaryName,
      p_service: editForm.service,
    });
    setSavingEntryId(null);
    if (rpcError) return setError(displayText(rpcError.message));

    const { error: participantError } = await supabase.rpc("request_agenda_companion_approval", {
      p_entry_id: entry.id,
      p_companion_user_ids: editForm.companions,
      p_reason: editForm.companionReason.trim(),
    });

    if (participantError) return setError(displayText(participantError.message));

    const saved = data as AgendaEntry;
    const targetProfile = brokers.find((broker) => broker.id === saved.target_user_id);
    replaceEntry(entry.id, {
      ...saved,
      target: targetProfile
        ? { full_name: targetProfile.fullName, email: targetProfile.email }
        : entry.target,
      creator: entry.creator,
    });
    setEditingEntryId(null);
    setEditForm(null);
    void refresh();
  }

  function preserveCameraScrollPosition() {
    cameraScrollTopRef.current = selectedEntriesScrollRef.current?.scrollTop ?? 0;
  }

  function restoreCameraScrollPosition() {
    const scrollTop = cameraScrollTopRef.current;
    window.requestAnimationFrame(() => {
      window.requestAnimationFrame(() => {
        selectedEntriesScrollRef.current?.scrollTo({ top: scrollTop, behavior: "auto" });
      });
    });
  }

  function clearPickerRecoveryTimers() {
    for (const timer of pickerRecoveryTimersRef.current) window.clearTimeout(timer);
    pickerRecoveryTimersRef.current = [];
  }

  function receivePickedFiles(input: HTMLInputElement) {
    const picker = activeFilePickerRef.current;
    if (!picker || picker.input !== input || picker.consumed) return false;
    const files = Array.from(input.files ?? []);
    if (!files.length) return false;

    // Copia o FileList imediatamente. Em alguns Androids ele e esvaziado
    // quando o seletor/camera termina de devolver o foco ao navegador.
    picker.consumed = true;
    clearPickerRecoveryTimers();
    if (picker.kind === "protocol") chooseProtocolFiles(picker.entry, files);
    else chooseVitorDocumentFiles(picker.entry, files);
    activeFilePickerRef.current = null;
    sessionStorage.removeItem("sonialima:file-picker-active");
    restoreCameraScrollPosition();
    return true;
  }
  receivePickedFilesRef.current = receivePickedFiles;

  function prepareFilePicker(
    entry: AgendaEntry,
    input: HTMLInputElement,
    kind: "protocol" | "vitor",
  ) {
    clearPickerRecoveryTimers();
    preserveCameraScrollPosition();
    sessionStorage.setItem("sonialima:file-picker-active", "1");
    // Garante que selecionar/tirar novamente uma foto com o mesmo nome ainda
    // produza um evento change no Chrome/WebView do Android.
    input.value = "";
    activeFilePickerRef.current = {
      input,
      entry,
      kind,
      consumed: false,
    };
  }

  useEffect(() => {
    const recoverAndroidPicker = () => {
      const picker = activeFilePickerRef.current;
      if (!picker || picker.consumed || document.visibilityState === "hidden") return;

      clearPickerRecoveryTimers();
      // O Moto G56 pode tornar a pagina visivel antes de preencher input.files.
      // Verifica por alguns segundos; o change/input continuam sendo o caminho
      // principal e estes tempos sao apenas a recuperacao do retorno nativo.
      for (const delay of [0, 100, 300, 700, 1_500, 3_000, 5_000]) {
        const timer = window.setTimeout(() => {
          const current = activeFilePickerRef.current;
          if (!current || current !== picker || current.consumed) return;
          const received = receivePickedFilesRef.current?.(current.input) ?? false;
          if (!received && delay === 5_000 && document.visibilityState === "visible") {
            activeFilePickerRef.current = null;
            sessionStorage.removeItem("sonialima:file-picker-active");
            setError(
              "O Android voltou sem entregar a foto ao navegador. Tente novamente e confirme a foto antes de voltar.",
            );
          }
        }, delay);
        pickerRecoveryTimersRef.current.push(timer);
      }
    };
    window.addEventListener("focus", recoverAndroidPicker);
    document.addEventListener("visibilitychange", recoverAndroidPicker);
    window.addEventListener("pageshow", recoverAndroidPicker);
    return () => {
      clearPickerRecoveryTimers();
      window.removeEventListener("focus", recoverAndroidPicker);
      document.removeEventListener("visibilitychange", recoverAndroidPicker);
      window.removeEventListener("pageshow", recoverAndroidPicker);
    };
  }, []);

  function chooseProtocolFiles(entry: AgendaEntry, list: FileList | File[] | null) {
    const files = Array.from(list ?? []);
    if (files.length > 5) return setError("É permitido anexar no máximo 5 arquivos.");
    setError("");
    setPendingProtocols((current) => ({
      ...current,
      [entry.id]: {
        entryDate: current[entry.id]?.entryDate ?? entry.protocol_entry_date ?? "",
        expectedDate: current[entry.id]?.expectedDate ?? entry.protocol_expected_date ?? "",
        files,
      },
    }));
    setAttachmentNotice((current) => ({
      ...current,
      [entry.id]: `${files.length} ${files.length === 1 ? "arquivo anexado" : "arquivos anexados"}. Clique em Salvar para concluir o envio.`,
    }));
  }

  async function uploadFile(entry: AgendaEntry, file: File, index: number) {
    const extension = file.name.includes(".") ? `.${file.name.split(".").pop()}` : "";
    const path = `${entry.id}/v${(entry.cartorio_protocol_revision_count ?? 0) + 1}-${createFileId()}-${index}${extension}`;
    const result = await Promise.race([
      supabase.storage
        .from("agenda-protocols")
        .upload(path, file, { contentType: file.type || undefined }),
      new Promise<never>((_, reject) =>
        window.setTimeout(
          () =>
            reject(new Error("O envio demorou demais. Verifique sua conexão e tente novamente.")),
          120_000,
        ),
      ),
    ]);
    if (result.error) throw new Error(`Não foi possível anexar: ${result.error.message}`);
    return path;
  }

  async function saveProtocolSubmission(entry: AgendaEntry) {
    const pending = pendingOf(entry);
    if (!pending.entryDate || !pending.expectedDate) return setError("Preencha as duas datas.");
    if (!pending.files.length) return setError("Anexe pelo menos um arquivo antes de salvar.");
    if (!isAdministrador && (entry.cartorio_protocol_revision_count ?? 0) >= 2)
      return setError("A correção permitida já foi utilizada.");

    setSavingProtocolId(entry.id);
    setError("");
    try {
      const uploaded: string[] = [];
      for (const [index, file] of pending.files.entries())
        uploaded.push(await uploadFile(entry, file, index));

      const { data, error: rpcError } = await supabase.rpc("save_agenda_cartorio_submission", {
        p_id: entry.id,
        p_entry_date: pending.entryDate,
        p_expected_date: pending.expectedDate,
        p_protocol_paths: uploaded,
      });
      if (rpcError) throw rpcError;

      const saved = data as AgendaEntry;
      replaceEntry(entry.id, {
        protocol_entry_date: saved.protocol_entry_date ?? pending.entryDate,
        protocol_expected_date: saved.protocol_expected_date ?? pending.expectedDate,
        protocol_paths: saved.protocol_paths ?? uploaded,
        protocol_path: saved.protocol_path ?? uploaded[0],
        protocol_uploaded_at: saved.protocol_uploaded_at ?? new Date().toISOString(),
        cartorio_received_at: null,
        cartorio_delivered_to_vitor_at: null,
        cartorio_protocol_versions: saved.cartorio_protocol_versions,
        cartorio_protocol_revision_count:
          saved.cartorio_protocol_revision_count ??
          (entry.cartorio_protocol_revision_count ?? 0) + 1,
      });
      setPendingProtocols((current) => {
        const next = { ...current };
        delete next[entry.id];
        return next;
      });
      setEditingProtocol((current) => ({ ...current, [entry.id]: false }));
      setAttachmentNotice((current) => ({
        ...current,
        [entry.id]: "Anexos enviados e salvos com sucesso.",
      }));
      void refresh();
    } catch (saveError) {
      setError(
        saveError instanceof Error ? saveError.message : "Não foi possível salvar o protocolo.",
      );
    } finally {
      setSavingProtocolId(null);
    }
  }

  async function downloadStoredFile(bucket: string, path: string) {
    const { data, error: downloadError } = await supabase.storage.from(bucket).download(path);
    if (downloadError || !data) return setError("Não foi possível abrir o anexo.");
    const url = URL.createObjectURL(data);
    window.open(url, "_blank", "noopener");
    window.setTimeout(() => URL.revokeObjectURL(url), 60_000);
  }

  const downloadProtocol = (path: string) => downloadStoredFile("agenda-protocols", path);
  const downloadVitorDocument = (path: string) =>
    downloadStoredFile("agenda-vitor-documents", path);

  async function deleteAgendaAttachment(
    entry: AgendaEntry,
    bucket: "agenda-protocols" | "agenda-vitor-documents",
    path: string,
  ) {
    const isAttachmentOwner =
      bucket === "agenda-protocols"
        ? isDerleyProfile
        : entry.cartorio_vitor_document_uploaded_by === profile?.id;
    if (!isAdministrador && !isAttachmentOwner) return;
    const key = `${bucket}:${path}`;
    setDeletingAttachmentKey(key);
    setError("");
    const { data, error: rpcError } = await supabase.rpc("delete_agenda_attachment", {
      p_id: entry.id,
      p_bucket: bucket,
      p_path: path,
    });
    if (rpcError) {
      setDeletingAttachmentKey(null);
      return setError(displayText(rpcError.message));
    }
    const { error: storageError } = await supabase.storage.from(bucket).remove([path]);
    setDeletingAttachmentKey(null);
    if (storageError) {
      return setError(
        `O anexo saiu da agenda, mas o arquivo não pôde ser removido do armazenamento: ${displayText(storageError.message)}`,
      );
    }
    const saved = data as AgendaEntry;
    replaceEntry(entry.id, {
      protocol_path: saved.protocol_path,
      protocol_paths: saved.protocol_paths,
      protocol_uploaded_at: saved.protocol_uploaded_at,
      cartorio_protocol_versions: saved.cartorio_protocol_versions,
      cartorio_vitor_document_paths: saved.cartorio_vitor_document_paths,
      cartorio_vitor_document_uploaded_at: saved.cartorio_vitor_document_uploaded_at,
      cartorio_vitor_document_uploaded_by: saved.cartorio_vitor_document_uploaded_by,
    });
    setAttachmentNotice((current) => ({
      ...current,
      [entry.id]: "Anexo excluído com sucesso.",
    }));
    void refresh();
  }

  async function saveCartorioObservation(entry: AgendaEntry) {
    const observation = (
      cartorioObservations[entry.id] ??
      entry.cartorio_protocol_observation ??
      ""
    ).trim();
    if (!observation) return setError("A observação do cartório é obrigatória.");
    setSavingCartorioObservationId(entry.id);
    setError("");
    const { data, error: rpcError } = await supabase.rpc("save_agenda_cartorio_observation", {
      p_id: entry.id,
      p_observation: observation,
    });
    setSavingCartorioObservationId(null);
    if (rpcError) return setError(displayText(rpcError.message));
    const saved = data as AgendaEntry;
    replaceEntry(entry.id, {
      cartorio_protocol_observation: saved.cartorio_protocol_observation ?? observation,
      cartorio_protocol_observation_at:
        saved.cartorio_protocol_observation_at ?? new Date().toISOString(),
    });
    setCartorioObservations((current) => ({ ...current, [entry.id]: observation }));
    setAttachmentNotice((current) => ({
      ...current,
      [entry.id]: "Observação salva. Os avisos para anexar o protocolo foram interrompidos.",
    }));
    void refresh();
  }

  function renderCartorioObservation(entry: AgendaEntry) {
    const value = cartorioObservations[entry.id] ?? entry.cartorio_protocol_observation ?? "";
    const canEdit = isDerleyProfile || isAdministrador;
    return (
      <div className="mb-4 space-y-3 rounded-lg border border-amber-300/20 bg-amber-300/[.05] p-3">
        <div>
          <p className="text-sm font-semibold text-amber-100">Observação do cartório *</p>
          <p className="mt-1 text-xs text-muted-foreground">
            Ao salvar esta observação, os avisos para anexar o protocolo serão interrompidos.
          </p>
        </div>
        {canEdit ? (
          <>
            <textarea
              required
              value={value}
              onChange={(event) =>
                setCartorioObservations((current) => ({
                  ...current,
                  [entry.id]: event.target.value,
                }))
              }
              placeholder="Informe obrigatoriamente a situação da demanda no cartório."
              className="min-h-24 w-full rounded-lg border border-white/10 bg-background p-3 text-sm text-foreground outline-none focus:border-copper/50"
            />
            <Button
              className="w-full"
              disabled={!value.trim() || savingCartorioObservationId === entry.id}
              onClick={() => void saveCartorioObservation(entry)}
            >
              {savingCartorioObservationId === entry.id ? (
                <Loader2 size={16} className="mr-2 animate-spin" />
              ) : (
                <Save size={16} className="mr-2" />
              )}
              Salvar observação e parar avisos
            </Button>
          </>
        ) : (
          <p className="whitespace-pre-wrap text-sm text-foreground">
            {value || "Observação ainda não registrada."}
          </p>
        )}
        {entry.cartorio_protocol_observation_at && (
          <p className="text-xs text-emerald-300">
            Avisos interrompidos em {dateTimeLabel(entry.cartorio_protocol_observation_at)}.
          </p>
        )}
      </div>
    );
  }

  function chooseVitorDocumentFiles(entry: AgendaEntry, list: FileList | File[] | null) {
    const files = Array.from(list ?? []);
    if (files.length > 5) return setError("É permitido anexar no máximo 5 arquivos.");
    setError("");
    setPendingVitorDocuments((current) => ({ ...current, [entry.id]: files }));
    setAttachmentNotice((current) => ({
      ...current,
      [entry.id]: `${files.length} ${files.length === 1 ? "documento anexado" : "documentos anexados"}. Clique em Salvar para concluir o envio.`,
    }));
  }

  async function uploadVitorDocumentFile(entry: AgendaEntry, file: File, index: number) {
    const extension = file.name.includes(".") ? `.${file.name.split(".").pop()}` : "";
    const path = `${entry.id}/vitor-${createFileId()}-${index}${extension}`;
    const result = await Promise.race([
      supabase.storage
        .from("agenda-vitor-documents")
        .upload(path, file, { contentType: file.type || undefined }),
      new Promise<never>((_, reject) =>
        window.setTimeout(
          () =>
            reject(new Error("O envio demorou demais. Verifique sua conexão e tente novamente.")),
          120_000,
        ),
      ),
    ]);
    if (result.error) throw new Error(`Não foi possível anexar: ${result.error.message}`);
    return path;
  }

  async function saveVitorDocuments(entry: AgendaEntry) {
    const files = pendingVitorDocuments[entry.id] ?? [];
    if (!files.length) return setError("Selecione ao menos um documento digitalizado.");
    if (files.length > 5) return setError("É permitido anexar no máximo 5 arquivos.");

    setSavingVitorDocumentId(entry.id);
    setError("");
    try {
      const uploaded: string[] = [];
      for (const [index, file] of files.entries())
        uploaded.push(await uploadVitorDocumentFile(entry, file, index));

      const { data, error: rpcError } = await supabase.rpc("save_agenda_cartorio_vitor_documents", {
        p_id: entry.id,
        p_document_paths: uploaded,
      });
      if (rpcError) throw rpcError;

      const saved = data as AgendaEntry;
      replaceEntry(entry.id, {
        cartorio_vitor_document_paths: saved.cartorio_vitor_document_paths ?? uploaded,
        cartorio_vitor_document_uploaded_at:
          saved.cartorio_vitor_document_uploaded_at ?? new Date().toISOString(),
        cartorio_vitor_document_uploaded_by:
          saved.cartorio_vitor_document_uploaded_by ?? profile?.id,
      });
      setPendingVitorDocuments((current) => {
        const next = { ...current };
        delete next[entry.id];
        return next;
      });
      setAttachmentNotice((current) => ({
        ...current,
        [entry.id]: "Documentos enviados e salvos com sucesso.",
      }));
      void refresh();
    } catch (saveError) {
      setError(
        saveError instanceof Error
          ? saveError.message
          : "Não foi possível salvar o documento digitalizado.",
      );
    } finally {
      setSavingVitorDocumentId(null);
    }
  }

  async function registerMilestone(
    entry: AgendaEntry,
    milestone: "received" | "delivered_to_vitor",
  ) {
    const stateId = `${entry.id}:${milestone}`;
    setSavingMilestoneId(stateId);
    setError("");
    const { data, error: rpcError } = await supabase.rpc("register_agenda_cartorio_milestone", {
      p_id: entry.id,
      p_milestone: milestone,
    });
    if (rpcError) setError(displayText(rpcError.message));
    else {
      const saved = data as AgendaEntry;
      replaceEntry(entry.id, {
        cartorio_received_at: saved.cartorio_received_at,
        cartorio_delivered_to_vitor_at: saved.cartorio_delivered_to_vitor_at,
        cartorio_protocol_versions: saved.cartorio_protocol_versions,
      });
      void refresh();
    }
    setSavingMilestoneId(null);
  }

  function startProtocolCorrection(entry: AgendaEntry) {
    if (!isAdministrador && (entry.cartorio_protocol_revision_count ?? 0) !== 1) return;
    setError("");
    setPendingProtocols((current) => ({
      ...current,
      [entry.id]: {
        files: [],
        entryDate: entry.protocol_entry_date ?? "",
        expectedDate: entry.protocol_expected_date ?? "",
      },
    }));
    setEditingProtocol((current) => ({ ...current, [entry.id]: true }));
  }

  function renderProtocolForm(entry: AgendaEntry) {
    const pending = pendingOf(entry);
    const correcting = (entry.cartorio_protocol_revision_count ?? 0) === 1;
    return (
      <div className="space-y-3">
        {correcting && (
          <p className="rounded-lg bg-amber-400/10 p-3 text-sm text-amber-200">
            Correção: esta será a segunda e última versão. A anterior continuará guardada para o
            Allyson.
          </p>
        )}
        <div className="grid gap-2 sm:grid-cols-2">
          <label className="text-xs text-muted-foreground">
            Data de entrada
            <input
              type="date"
              min="1900-01-01"
              max="9999-12-31"
              value={pending.entryDate}
              onChange={(event) =>
                setPendingProtocols((current) => ({
                  ...current,
                  [entry.id]: { ...pending, entryDate: event.target.value },
                }))
              }
              className="mt-1 block w-full rounded-md bg-white/[.05] p-2 text-sm text-foreground"
            />
          </label>
          <label className="text-xs text-muted-foreground">
            Data prevista para buscar
            <input
              type="date"
              min="1900-01-01"
              max="9999-12-31"
              value={pending.expectedDate}
              onChange={(event) =>
                setPendingProtocols((current) => ({
                  ...current,
                  [entry.id]: { ...pending, expectedDate: event.target.value },
                }))
              }
              className="mt-1 block w-full rounded-md bg-white/[.05] p-2 text-sm text-foreground"
            />
          </label>
        </div>
        <label className="inline-flex cursor-pointer items-center gap-2 rounded-md bg-copper px-3 py-2 text-sm font-medium text-white">
          <Paperclip size={16} />{" "}
          {pending.files.length ? "Trocar arquivos selecionados" : "Anexar arquivos (até 5)"}
          <input
            type="file"
            multiple
            accept="image/*,application/pdf"
            className="sr-only"
            disabled={savingProtocolId === entry.id}
            onClick={(event) => prepareFilePicker(entry, event.currentTarget, "protocol")}
            onInput={(event) => receivePickedFiles(event.currentTarget)}
            onChange={(event) => receivePickedFiles(event.currentTarget)}
          />
        </label>
        <label className="ml-2 inline-flex cursor-pointer items-center gap-2 rounded-md border border-copper/40 px-3 py-2 text-sm font-medium text-foreground">
          Tirar foto
          <input
            type="file"
            accept="image/*"
            capture="environment"
            className="sr-only"
            disabled={savingProtocolId === entry.id}
            onClick={(event) => prepareFilePicker(entry, event.currentTarget, "protocol")}
            onInput={(event) => receivePickedFiles(event.currentTarget)}
            onChange={(event) => receivePickedFiles(event.currentTarget)}
          />
        </label>
        {pending.files.length > 0 && (
          <p className="text-xs text-muted-foreground">
            Selecionados: {pending.files.map((file) => file.name).join(", ")}
          </p>
        )}
        {attachmentNotice[entry.id] && (
          <p className="flex items-start gap-2 rounded-lg border border-emerald-400/25 bg-emerald-500/10 p-3 text-sm text-emerald-200">
            <CheckCircle2 size={17} className="mt-0.5 shrink-0" />
            {attachmentNotice[entry.id]}
          </p>
        )}
        <Button
          className="w-full"
          disabled={savingProtocolId === entry.id}
          onClick={() => void saveProtocolSubmission(entry)}
        >
          {savingProtocolId === entry.id ? (
            <>
              <Loader2 size={16} className="mr-2 animate-spin" />
              Salvando...
            </>
          ) : (
            <>
              <Save size={16} className="mr-2" />
              Salvar
            </>
          )}
        </Button>
      </div>
    );
  }

  function renderProtocolReadOnly(entry: AgendaEntry) {
    const paths = pathsOf(entry);
    const revision = entry.cartorio_protocol_revision_count ?? 0;
    const completeMilestones = Boolean(
      entry.cartorio_received_at && entry.cartorio_delivered_to_vitor_at,
    );
    return (
      <div className="space-y-3">
        <div className="flex items-start justify-between gap-3">
          <div>
            <p className="text-sm font-medium text-emerald-300">
              Protocolo salvo · versão {revision}
            </p>
            <p className="mt-1 text-xs text-muted-foreground">
              Entrada: {dateLabel(entry.protocol_entry_date)} · Previsto para buscar:{" "}
              {dateLabel(entry.protocol_expected_date)}
            </p>
          </div>
          {(isAdministrador || (isDerleyProfile && revision === 1 && completeMilestones)) && (
            <Button
              size="sm"
              variant="ghost"
              title="Corrigir uma vez"
              onClick={() => startProtocolCorrection(entry)}
            >
              <Pencil size={16} />
            </Button>
          )}
        </div>
        <div className="flex flex-wrap gap-2">
          {paths.map((path, index) => (
            <span key={path} className="inline-flex items-center gap-1">
              <Button size="sm" variant="ghost" onClick={() => void downloadProtocol(path)}>
                <Download size={15} className="mr-1" />
                Visualizar anexo {index + 1}
              </Button>
              {(isAdministrador || isDerleyProfile) && (
                <Button
                  size="icon"
                  variant="ghost"
                  title={`Excluir anexo ${index + 1}`}
                  disabled={deletingAttachmentKey === `agenda-protocols:${path}`}
                  onClick={() => void deleteAgendaAttachment(entry, "agenda-protocols", path)}
                  className="text-red-300 hover:text-red-200"
                >
                  {deletingAttachmentKey === `agenda-protocols:${path}` ? (
                    <Loader2 size={15} className="animate-spin" />
                  ) : (
                    <Trash2 size={15} />
                  )}
                </Button>
              )}
            </span>
          ))}
        </div>
        <div className="grid gap-3 border-t border-white/10 pt-3 sm:grid-cols-2">
          <div>
            <p className="text-xs text-muted-foreground">Recebido no Cartório</p>
            {entry.cartorio_received_at ? (
              <p className="mt-1 text-sm font-medium text-emerald-300">
                {dateTimeLabel(entry.cartorio_received_at)}
              </p>
            ) : isDerleyProfile || isAdministrador ? (
              <Button
                size="sm"
                className="mt-1"
                disabled={savingMilestoneId === `${entry.id}:received`}
                onClick={() => void registerMilestone(entry, "received")}
              >
                {savingMilestoneId === `${entry.id}:received` ? (
                  <Loader2 size={15} className="animate-spin" />
                ) : (
                  "Recebi agora"
                )}
              </Button>
            ) : (
              <p className="mt-1 text-sm text-amber-200">Pendente</p>
            )}
          </div>
          <div>
            <p className="text-xs text-muted-foreground">Entregue ao Vitor</p>
            {entry.cartorio_delivered_to_vitor_at ? (
              <p className="mt-1 text-sm font-medium text-emerald-300">
                {dateTimeLabel(entry.cartorio_delivered_to_vitor_at)}
              </p>
            ) : isDerleyProfile || isAdministrador ? (
              <Button
                size="sm"
                className="mt-1"
                disabled={savingMilestoneId === `${entry.id}:delivered_to_vitor`}
                onClick={() => void registerMilestone(entry, "delivered_to_vitor")}
              >
                {savingMilestoneId === `${entry.id}:delivered_to_vitor` ? (
                  <Loader2 size={15} className="animate-spin" />
                ) : (
                  "Entreguei agora"
                )}
              </Button>
            ) : (
              <p className="mt-1 text-sm text-amber-200">Pendente</p>
            )}
          </div>
        </div>
      </div>
    );
  }

  function renderVitorDigitalization(entry: AgendaEntry) {
    if (!entry.cartorio_delivered_to_vitor_at) return null;
    const paths = entry.cartorio_vitor_document_paths ?? [];
    const pending = pendingVitorDocuments[entry.id] ?? [];

    return (
      <div className="mt-4 rounded-lg border border-white/10 bg-white/[.02] p-3">
        <div className="flex flex-wrap items-start justify-between gap-2">
          <div>
            <p
              className={`text-sm font-medium ${paths.length ? "text-emerald-300" : "text-amber-200"}`}
            >
              {paths.length
                ? "Documento digitalizado salvo"
                : "Documento aguardando digitalização pelo Vitor"}
            </p>
            <p className="mt-1 text-xs text-muted-foreground">
              {paths.length
                ? `Salvo em ${dateTimeLabel(entry.cartorio_vitor_document_uploaded_at)}`
                : "O Vitor será lembrado a cada 1 hora. Após 24 horas sem anexo, Allyson será avisado."}
            </p>
          </div>
        </div>

        {paths.length ? (
          <div className="mt-3 flex flex-wrap gap-2">
            {paths.map((path, index) => (
              <span key={path} className="inline-flex items-center gap-1">
                <Button size="sm" variant="ghost" onClick={() => void downloadVitorDocument(path)}>
                  <Download size={15} className="mr-1" />
                  Visualizar documento {index + 1}
                </Button>
                {(isAdministrador || entry.cartorio_vitor_document_uploaded_by === profile?.id) && (
                  <Button
                    size="icon"
                    variant="ghost"
                    title={`Excluir documento ${index + 1}`}
                    disabled={deletingAttachmentKey === `agenda-vitor-documents:${path}`}
                    onClick={() =>
                      void deleteAgendaAttachment(entry, "agenda-vitor-documents", path)
                    }
                    className="text-red-300 hover:text-red-200"
                  >
                    {deletingAttachmentKey === `agenda-vitor-documents:${path}` ? (
                      <Loader2 size={15} className="animate-spin" />
                    ) : (
                      <Trash2 size={15} />
                    )}
                  </Button>
                )}
              </span>
            ))}
          </div>
        ) : isVitorProfile || isAdministrador ? (
          <div className="mt-3 space-y-3">
            <label className="inline-flex cursor-pointer items-center gap-2 rounded-md bg-copper px-3 py-2 text-sm font-medium text-white">
              <Paperclip size={16} />{" "}
              {pending.length
                ? "Trocar documentos selecionados"
                : "Anexar documento digitalizado (até 5)"}
              <input
                type="file"
                multiple
                accept="image/*,application/pdf"
                className="sr-only"
                disabled={savingVitorDocumentId === entry.id}
                onClick={(event) => prepareFilePicker(entry, event.currentTarget, "vitor")}
                onInput={(event) => receivePickedFiles(event.currentTarget)}
                onChange={(event) => receivePickedFiles(event.currentTarget)}
              />
            </label>
            <label className="ml-2 inline-flex cursor-pointer items-center gap-2 rounded-md border border-copper/40 px-3 py-2 text-sm font-medium text-foreground">
              Tirar foto
              <input
                type="file"
                accept="image/*"
                capture="environment"
                className="sr-only"
                disabled={savingVitorDocumentId === entry.id}
                onClick={(event) => prepareFilePicker(entry, event.currentTarget, "vitor")}
                onInput={(event) => receivePickedFiles(event.currentTarget)}
                onChange={(event) => receivePickedFiles(event.currentTarget)}
              />
            </label>
            {pending.length > 0 && (
              <>
                <p className="text-xs text-muted-foreground">
                  Selecionados: {pending.map((file) => file.name).join(", ")}
                </p>
                <Button
                  className="w-full"
                  disabled={savingVitorDocumentId === entry.id}
                  onClick={() => void saveVitorDocuments(entry)}
                >
                  {savingVitorDocumentId === entry.id ? (
                    <>
                      <Loader2 size={16} className="mr-2 animate-spin" />
                      Salvando...
                    </>
                  ) : (
                    <>
                      <Save size={16} className="mr-2" />
                      Salvar documento digitalizado
                    </>
                  )}
                </Button>
              </>
            )}
            {attachmentNotice[entry.id] && (
              <p className="flex items-start gap-2 rounded-lg border border-emerald-400/25 bg-emerald-500/10 p-3 text-sm text-emerald-200">
                <CheckCircle2 size={17} className="mt-0.5 shrink-0" />
                {attachmentNotice[entry.id]}
              </p>
            )}
          </div>
        ) : (
          <p className="mt-3 text-sm text-amber-200">
            Aguardando o Vitor anexar o documento digitalizado.
          </p>
        )}
      </div>
    );
  }

  function renderProtocolAudit(entry: AgendaEntry) {
    const versions = entry.cartorio_protocol_versions ?? [];
    if (!isAdmin || !versions.length) return null;
    return (
      <div className="mt-4 rounded-lg border border-copper/30 bg-copper/[.04] p-3">
        <p className="text-xs font-semibold uppercase tracking-wider text-copper">
          Histórico para auditoria
        </p>
        <div className="mt-3 space-y-3">
          {versions.map((version) => (
            <div key={version.version} className="rounded-lg border border-white/10 p-3 text-xs">
              <p className="font-semibold text-foreground">
                Versão {version.version}
                {version.version === 1 && versions.length > 1
                  ? " · registro original"
                  : version.version === 2
                    ? " · correção"
                    : ""}
              </p>
              <p className="mt-1 text-muted-foreground">
                Entrada: {dateLabel(version.entry_date)} · Previsto:{" "}
                {dateLabel(version.expected_date)}
              </p>
              <p className="mt-1 text-muted-foreground">
                Recebido: {dateTimeLabel(version.received_at)} · Entregue ao Vitor:{" "}
                {dateTimeLabel(version.delivered_to_vitor_at)}
              </p>
              <div className="mt-2 flex flex-wrap gap-2">
                {(version.paths ?? []).map((path, index) => (
                  <Button
                    key={path}
                    size="sm"
                    variant="ghost"
                    onClick={() => void downloadProtocol(path)}
                  >
                    <Download size={14} className="mr-1" />
                    Anexo {index + 1}
                  </Button>
                ))}
              </div>
            </div>
          ))}
        </div>
      </div>
    );
  }

  function renderEntryEditForm(entry: AgendaEntry) {
    if (!editForm || editingEntryId !== entry.id) return null;
    const isService = editForm.category === "neo_energia" || editForm.category === "caesb";
    const derley = brokers.find(
      (broker) => broker.email.toLowerCase() === "unassigned-agenda@example.invalid",
    );
    const targetOptions = brokers.some((broker) => broker.id === entry.target_user_id)
      ? brokers
      : [
          ...brokers,
          {
            id: entry.target_user_id,
            fullName: entry.target?.full_name || entry.target?.email || "Responsável atual",
            email: entry.target?.email || "",
            role: "broker" as const,
          },
        ];

    return (
      <div className="mt-4 grid gap-3 rounded-lg border border-copper/30 bg-copper/[.04] p-3 sm:grid-cols-2">
        {!isLeadVisit(entry) && (
          <label className="text-xs text-muted-foreground">
            Tipo da demanda
            <select
              value={editForm.category}
              onChange={(event) => {
                const category = event.target.value as keyof typeof labels;
                updateEditForm("category", category);
                if (category === "cartorio" && derley) updateEditForm("targetUserId", derley.id);
              }}
              className="mt-1 w-full rounded-lg bg-background p-2 text-sm text-foreground"
            >
              {Object.entries(labels).map(([key, label]) => (
                <option key={key} value={key}>
                  {label}
                </option>
              ))}
            </select>
          </label>
        )}
        <label className="text-xs text-muted-foreground">
          Data e horário
          <input
            type="datetime-local"
            value={editForm.when}
            onChange={(event) => updateEditForm("when", event.target.value)}
            className="mt-1 w-full rounded-lg bg-background p-2 text-sm text-foreground"
          />
        </label>
        {!isLeadVisit(entry) && (
          <label className="text-xs text-muted-foreground sm:col-span-2">
            Responsável
            <select
              value={editForm.targetUserId}
              onChange={(event) => updateEditForm("targetUserId", event.target.value)}
              disabled={editForm.category === "cartorio"}
              className="mt-1 w-full rounded-lg bg-background p-2 text-sm text-foreground disabled:opacity-70"
            >
              {targetOptions.map((broker) => (
                <option key={broker.id} value={broker.id}>
                  {broker.fullName || broker.email}
                </option>
              ))}
            </select>
          </label>
        )}

        {!isLeadVisit(entry) &&
          (editForm.category === "observacao" ? (
            <label className="text-xs text-muted-foreground sm:col-span-2">
              Demanda / observação
              <textarea
                value={editForm.observation}
                onChange={(event) => updateEditForm("observation", event.target.value)}
                className="mt-1 min-h-24 w-full rounded-lg bg-background p-2 text-sm text-foreground"
              />
            </label>
          ) : (
            <>
              <label className="text-xs text-muted-foreground">
                Cliente
                <input
                  value={editForm.clientName}
                  onChange={(event) => updateEditForm("clientName", event.target.value)}
                  className="mt-1 w-full rounded-lg bg-background p-2 text-sm text-foreground"
                />
              </label>
              <label className="text-xs text-muted-foreground">
                Imóvel
                <input
                  value={editForm.propertyAddress}
                  onChange={(event) => updateEditForm("propertyAddress", event.target.value)}
                  className="mt-1 w-full rounded-lg bg-background p-2 text-sm text-foreground"
                />
              </label>
              {editForm.category === "cartorio" && (
                <label className="text-xs text-muted-foreground">
                  Cartório
                  <input
                    value={editForm.notaryName}
                    onChange={(event) => updateEditForm("notaryName", event.target.value)}
                    className="mt-1 w-full rounded-lg bg-background p-2 text-sm text-foreground"
                  />
                </label>
              )}
              {(isService || editForm.category === "cartorio") && (
                <label className="text-xs text-muted-foreground">
                  Serviço / demanda
                  <input
                    value={editForm.service}
                    onChange={(event) => updateEditForm("service", event.target.value)}
                    className="mt-1 w-full rounded-lg bg-background p-2 text-sm text-foreground"
                  />
                </label>
              )}
            </>
          ))}

        {isLeadVisit(entry) && (
          <p className="text-xs text-sky-700 dark:text-sky-200 sm:col-span-2">
            Ao salvar, a nova data será atualizada automaticamente no lead.
          </p>
        )}

        <div className="sm:col-span-2">
          <label className="text-xs text-muted-foreground block mb-1">Acompanhantes</label>
          <details className="group relative rounded-lg bg-background">
            <summary className="flex h-full min-h-10 cursor-pointer list-none items-center justify-between gap-2 px-3 py-2 text-sm marker:hidden border border-transparent border-white/5">
              <span className="truncate">
                {(editForm.companions ?? []).length
                  ? `${(editForm.companions ?? []).length} acompanhante${(editForm.companions ?? []).length > 1 ? "s" : ""}`
                  : "Sem acompanhante"}
              </span>
              <span className="text-muted-foreground group-open:rotate-180">⌄</span>
            </summary>
            <div className="absolute left-0 top-full z-30 mt-1 max-h-64 w-full min-w-56 overflow-y-auto rounded-lg border border-white/15 bg-background p-2 shadow-2xl">
              {targetOptions
                .filter((broker) => broker.id !== editForm.targetUserId)
                .map((broker) => (
                  <label
                    key={broker.id}
                    className="flex cursor-pointer items-center gap-2 rounded px-2 py-2 text-sm hover:bg-white/10"
                  >
                    <input
                      type="checkbox"
                      checked={(editForm.companions ?? []).includes(broker.id)}
                      onChange={() =>
                        updateEditForm(
                          "companions",
                          (editForm.companions ?? []).includes(broker.id)
                            ? (editForm.companions ?? []).filter((id) => id !== broker.id)
                            : [...(editForm.companions ?? []), broker.id],
                        )
                      }
                      className="accent-copper"
                    />
                    Ir junto: {broker.fullName || broker.email}
                  </label>
                ))}
            </div>
          </details>

          {(editForm.companions ?? []).length > 0 && (
            <textarea
              required
              value={editForm.companionReason ?? ""}
              onChange={(event) => updateEditForm("companionReason", event.target.value)}
              placeholder="Motivo obrigatório para o acompanhante"
              className="mt-3 min-h-20 w-full rounded-lg border border-amber-400/30 bg-background p-2 text-sm"
            />
          )}
        </div>

        <div className="flex justify-end gap-2 sm:col-span-2">
          <Button
            size="sm"
            variant="ghost"
            disabled={savingEntryId === entry.id}
            onClick={() => {
              setEditingEntryId(null);
              setEditForm(null);
            }}
          >
            Cancelar
          </Button>
          <Button
            size="sm"
            disabled={savingEntryId === entry.id}
            onClick={() => void saveEditedEntry(entry)}
          >
            {savingEntryId === entry.id ? (
              <Loader2 size={15} className="animate-spin" />
            ) : (
              <Save size={15} />
            )}
            Salvar alterações
          </Button>
        </div>
      </div>
    );
  }

  return (
    <section className="mt-8">
      <div className="flex flex-wrap gap-2">
        {orderedBrokers.map((broker) => (
          <button
            key={broker.id}
            onClick={() => setSelectedBrokerId(broker.id)}
            className={`rounded-full px-4 py-2 text-sm font-medium ${selectedBrokerId === broker.id ? "bg-copper text-white" : "bg-muted text-foreground hover:bg-muted/80"}`}
          >
            {broker.fullName || broker.email}
          </button>
        ))}
      </div>
      <div className="mt-5 flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 className="text-xl font-semibold capitalize text-foreground">
            {visibleMonth.toLocaleDateString("pt-BR", { month: "long", year: "numeric" })}
          </h2>
          <p className="mt-1 text-xs text-muted-foreground">
            Clique em um dia com compromisso para ver os detalhes.
          </p>
        </div>
        <div className="flex items-center gap-2" aria-label="Navegação entre meses">
          <Button
            size="sm"
            variant="ghost"
            title="Mês anterior"
            aria-label="Mês anterior"
            onClick={() =>
              setVisibleMonth(
                (current) => new Date(current.getFullYear(), current.getMonth() - 1, 1),
              )
            }
          >
            <ChevronLeft size={17} />
          </Button>
          <Button
            size="sm"
            variant="ghost"
            onClick={() => {
              const today = new Date();
              setVisibleMonth(new Date(today.getFullYear(), today.getMonth(), 1));
            }}
          >
            Hoje
          </Button>
          <Button
            size="sm"
            variant="ghost"
            title="Próximo mês"
            aria-label="Próximo mês"
            onClick={() =>
              setVisibleMonth(
                (current) => new Date(current.getFullYear(), current.getMonth() + 1, 1),
              )
            }
          >
            <ChevronRight size={17} />
          </Button>
        </div>
      </div>
      <div className="mt-3 grid grid-cols-7 overflow-hidden rounded-xl border border-white/10">
        {["Dom", "Seg", "Ter", "Qua", "Qui", "Sex", "Sáb"].map((day) => (
          <div
            key={day}
            className="border-b border-white/10 px-0.5 py-2 text-center text-[10px] font-medium text-foreground sm:p-2 sm:text-xs"
          >
            <span className="sm:hidden">{day.slice(0, 1)}</span>
            <span className="hidden sm:inline">{day}</span>
          </div>
        ))}
        {cells.map((day, index) => {
          const current = day > 0 && day <= daysInMonth;
          const dayEntries = current
            ? (entries.data ?? []).filter((entry) => {
                const scheduled = new Date(entry.scheduled_at);
                return (
                  (entry.target_user_id === selectedBrokerId ||
                    entry.participants?.some(
                      (participant) => participant.user_id === selectedBrokerId,
                    )) &&
                  scheduled.getFullYear() === year &&
                  scheduled.getMonth() === month &&
                  scheduled.getDate() === day
                );
              })
            : [];
          return (
            <button
              key={index}
              disabled={!dayEntries.length}
              onClick={() => setSelectedEntries(dayEntries)}
              className={`min-h-16 min-w-0 border-b border-r border-white/10 p-1 text-left sm:min-h-28 sm:p-2 ${dayEntries.length ? "cursor-pointer hover:bg-white/[.05]" : "cursor-default"}`}
            >
              <b className="text-xs font-semibold text-foreground">{current ? day : ""}</b>
              {dayEntries.length > 0 && (
                <span
                  className={`mt-2 flex items-center justify-center gap-1 rounded px-1 py-1 text-[10px] font-semibold text-foreground sm:hidden ${
                    dayEntries.some(
                      (entry) => isSaleTransfer(entry) && !entry.sale_documents_completed_at,
                    )
                      ? "border border-red-400/50 bg-red-500/20"
                      : dayEntries.some(
                            (entry) =>
                              isLeadVisit(entry) && visitVisualStatus(entry) === "in_progress",
                          )
                        ? "border border-red-400/50 bg-red-500/20"
                        : dayEntries.some(
                              (entry) =>
                                isLeadVisit(entry) && visitVisualStatus(entry) === "scheduled",
                            )
                          ? "border border-amber-400/40 bg-amber-500/20"
                          : dayEntries.some(
                                (entry) =>
                                  isLeadVisit(entry) && visitVisualStatus(entry) === "proposal",
                              )
                            ? "border border-violet-400/40 bg-violet-500/20"
                            : dayEntries.some(
                                  (entry) =>
                                    (isLeadVisit(entry) &&
                                      visitVisualStatus(entry) === "completed") ||
                                    (!isLeadVisit(entry) && !!entry.feedback_at),
                                )
                              ? "border border-emerald-400/40 bg-emerald-500/20"
                              : "bg-copper/20"
                  }`}
                >
                  {dayEntries.length}
                </span>
              )}
              {dayEntries.map((entry) => (
                <span
                  key={entry.id}
                  className={`mt-1 hidden truncate rounded p-1.5 text-[11px] font-medium leading-relaxed text-foreground sm:block ${calendarTone(entry)}`}
                >
                  {new Date(entry.scheduled_at).toLocaleTimeString("pt-BR", {
                    hour: "2-digit",
                    minute: "2-digit",
                  })}{" "}
                  · {entrySummary(entry)}
                </span>
              ))}
            </button>
          );
        })}
      </div>

      {selectedEntries && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-2 sm:p-4"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) closeSelectedEntries();
          }}
        >
          <div
            ref={selectedEntriesScrollRef}
            className="max-h-[calc(100dvh-1rem)] w-full max-w-2xl overscroll-contain overflow-x-hidden overflow-y-auto rounded-2xl border border-white/15 bg-background p-4 pb-[max(1rem,env(safe-area-inset-bottom))] shadow-2xl sm:max-h-[85dvh] sm:p-5"
          >
            <div className="flex items-start justify-between gap-4">
              <div>
                <p className="text-xs uppercase tracking-[.18em] text-copper">Agenda</p>
                <h3 className="mt-1 text-lg font-semibold text-foreground sm:text-xl">
                  Compromissos de{" "}
                  {new Date(selectedEntries[0].scheduled_at).toLocaleDateString("pt-BR")}
                </h3>
              </div>
              <button
                onClick={closeSelectedEntries}
                className="rounded-lg p-2 text-muted-foreground hover:bg-white/10 hover:text-foreground"
              >
                <X size={20} />
              </button>
            </div>
            {error && (
              <p className="mt-4 rounded-lg bg-red-400/10 p-3 text-sm text-red-200">{error}</p>
            )}
            <div className="mt-5 space-y-4">
              {selectedEntries.map((entry) => {
                const submitted = (entry.cartorio_protocol_revision_count ?? 0) > 0;
                const editing = editingProtocol[entry.id] === true;
                const currentVisitStatus = isLeadVisit(entry) ? visitVisualStatus(entry) : null;
                const finalFeedback = isLeadVisit(entry) ? finalVisitFeedback(entry) : undefined;
                return (
                  <article
                    key={entry.id}
                    className={`rounded-xl border p-3 sm:p-4 ${cardTone(entry)}`}
                  >
                    <div className="flex flex-wrap justify-between gap-2">
                      <b
                        className={`inline-flex items-center gap-2 ${currentVisitStatus ? visitTextTone(currentVisitStatus) : "text-foreground"}`}
                      >
                        {isLeadVisit(entry) && <CalendarDays size={17} />} {entryLabel(entry)}
                      </b>
                      <span className="text-sm text-muted-foreground">
                        {new Date(entry.scheduled_at).toLocaleString("pt-BR")}
                      </span>
                    </div>
                    {isLeadVisit(entry) ? (
                      <div className="mt-3 rounded-lg border border-sky-400/20 bg-sky-500/[.08] p-3 text-sm text-foreground">
                        <p className="whitespace-pre-wrap leading-relaxed">
                          {entryObservation(entry)}
                        </p>
                        <p className="mt-3 text-xs text-sky-700/80 dark:text-sky-200/80">
                          Compromisso criado automaticamente ao agendar a visita na aba Leads.
                        </p>
                      </div>
                    ) : entry.category === "cartorio" ? (
                      <div className="mt-3 grid gap-2 rounded-lg bg-white/[.03] p-3 text-sm text-foreground">
                        <p>
                          <span className="text-muted-foreground">Cliente:</span>{" "}
                          {entry.cartorio_client_name}
                        </p>
                        <p>
                          <span className="text-muted-foreground">Imóvel:</span>{" "}
                          {entry.cartorio_property_address}
                        </p>
                        <p>
                          <span className="text-muted-foreground">Cartório:</span>{" "}
                          {entry.cartorio_name}
                        </p>
                        <p>
                          <span className="text-muted-foreground">Serviço:</span>{" "}
                          {entry.cartorio_service}
                        </p>
                      </div>
                    ) : entry.category === "neo_energia" || entry.category === "caesb" ? (
                      <div className="mt-3 grid gap-2 rounded-lg bg-white/[.03] p-3 text-sm text-foreground">
                        <p>
                          <span className="text-muted-foreground">Cliente:</span>{" "}
                          {entry.demand_client_name}
                        </p>
                        <p>
                          <span className="text-muted-foreground">Imóvel:</span>{" "}
                          {entry.demand_property_address}
                        </p>
                        <p>
                          <span className="text-muted-foreground">Serviço:</span>{" "}
                          {entry.demand_service}
                        </p>
                      </div>
                    ) : (
                      <p className="mt-3 whitespace-pre-wrap text-sm leading-relaxed text-foreground">
                        {entry.observation}
                      </p>
                    )}
                    <p className="mt-3 text-xs text-muted-foreground">
                      Responsável: {agendaPersonName(entry.target)} · Criado por:{" "}
                      {entry.created_by_email || entry.creator?.email || "Não identificado"}
                    </p>
                    {entry.participants && entry.participants.length > 0 && (
                      <p className="mt-2 rounded-lg border border-red-400/20 bg-red-400/10 px-3 py-2 text-sm text-foreground">
                        Irão juntos: {agendaPersonName(entry.target)} e{" "}
                        {entry.participants
                          .map((participant) => {
                            const companion = brokers.find(
                              (broker) => broker.id === participant.user_id,
                            );
                            return companion?.fullName || companion?.email || "Não identificado";
                          })
                          .join(", ")}
                      </p>
                    )}

                    {renderEntryEditForm(entry)}

                    {isSaleTransfer(entry) &&
                      entry.source_sale_id &&
                      (isDerleyProfile || isAdministrador) && (
                        <SaleTransferDocuments
                          saleId={entry.source_sale_id}
                          dueAt={entry.sale_task_due_at}
                          canUpload={isDerleyProfile || email === "crmsoniaallyson@gmail.com"}
                          onCompleted={() => {
                            const completedAt = new Date().toISOString();
                            replaceEntry(entry.id, {
                              sale_documents_completed_at: completedAt,
                              feedback_at: completedAt,
                            });
                            void refresh();
                          }}
                        />
                      )}

                    {entry.category === "cartorio" && canViewProtocol && (
                      <div className="mt-4 rounded-lg border border-white/10 p-3">
                        {renderCartorioObservation(entry)}
                        {!submitted || editing ? (
                          isDerleyProfile || isAdministrador ? (
                            renderProtocolForm(entry)
                          ) : (
                            <p className="text-sm text-amber-200">
                              Aguardando o Derley preencher e salvar o protocolo.
                            </p>
                          )
                        ) : (
                          renderProtocolReadOnly(entry)
                        )}
                        {submitted &&
                          !editing &&
                          canViewVitorDocument &&
                          renderVitorDigitalization(entry)}
                        {renderProtocolAudit(entry)}
                      </div>
                    )}

                    {canRegisterVisitProgress(entry) && currentVisitStatus === "scheduled" && (
                      <div className="mt-4 rounded-lg border border-amber-400/30 bg-amber-500/[.08] p-3 text-sm text-amber-200">
                        Esta visita está agendada. O resultado poderá ser registrado a partir de{" "}
                        {new Date(entry.scheduled_at).toLocaleString("pt-BR")}.
                      </div>
                    )}

                    {canRegisterVisitProgress(entry) &&
                      (currentVisitStatus === "in_progress" ||
                        (isAdministrador &&
                          editingVisitResults[entry.id] &&
                          (currentVisitStatus === "completed" ||
                            currentVisitStatus === "proposal"))) && (
                        <div className="mt-4 rounded-lg border border-red-400/30 bg-red-500/[.06] p-3">
                          <p className="mb-3 text-sm font-medium text-red-200">
                            {currentVisitStatus === "in_progress"
                              ? "Visita em andamento. Registre o resultado somente depois que ela for realizada."
                              : "Correção administrativa do resultado da visita."}
                          </p>
                          <div className="grid gap-2 sm:grid-cols-[180px_1fr]">
                            <select
                              value={visitStages[entry.id] ?? "Visita realizada"}
                              onChange={(event) =>
                                setVisitStages((current) => ({
                                  ...current,
                                  [entry.id]: event.target.value as "Visita realizada" | "Proposta",
                                }))
                              }
                              className="rounded-lg border border-white/10 bg-background p-2 text-sm text-foreground"
                            >
                              <option value="Visita realizada">Visita realizada</option>
                              <option value="Proposta">Proposta</option>
                            </select>
                            <textarea
                              value={feedback[entry.id] ?? ""}
                              onChange={(event) =>
                                setFeedback((current) => ({
                                  ...current,
                                  [entry.id]: event.target.value,
                                }))
                              }
                              placeholder="Descreva o que aconteceu e os próximos passos"
                              className="min-h-20 resize-y rounded-lg border border-white/10 bg-background p-2 text-sm text-foreground"
                            />
                          </div>
                          {(visitStages[entry.id] ?? "Visita realizada") === "Visita realizada" && (
                            <div className="mt-3 rounded-lg border border-violet-300/20 bg-violet-300/[.05] p-3">
                              <p className="text-sm font-medium text-violet-100">
                                O imóvel do cliente foi captado durante a visita?
                              </p>
                              <div className="mt-2 flex gap-2">
                                {([true, false] as const).map((value) => (
                                  <Button
                                    key={String(value)}
                                    type="button"
                                    size="sm"
                                    variant={
                                      visitPropertyCaptured[entry.id] === value
                                        ? "default"
                                        : "outline"
                                    }
                                    onClick={() =>
                                      setVisitPropertyCaptured((current) => ({
                                        ...current,
                                        [entry.id]: value,
                                      }))
                                    }
                                  >
                                    {value ? "Sim" : "Não"}
                                  </Button>
                                ))}
                              </div>
                            </div>
                          )}
                          <Button
                            size="sm"
                            className="mt-2 w-full sm:w-auto"
                            disabled={
                              savingVisitId === entry.id ||
                              ((visitStages[entry.id] ?? "Visita realizada") ===
                                "Visita realizada" &&
                                visitPropertyCaptured[entry.id] === undefined)
                            }
                            onClick={() => void registerVisitProgress(entry)}
                          >
                            {savingVisitId === entry.id ? (
                              <Loader2 size={15} className="animate-spin" />
                            ) : (
                              <Save size={15} />
                            )}
                            Atualizar lead e salvar feedback
                          </Button>
                        </div>
                      )}

                    {canRegisterVisitProgress(entry) &&
                      (currentVisitStatus === "completed" || currentVisitStatus === "proposal") && (
                        <div
                          className={`mt-4 rounded-lg border p-3 ${
                            currentVisitStatus === "completed"
                              ? "border-emerald-400/30 bg-emerald-500/[.06]"
                              : "border-violet-400/30 bg-violet-500/[.06]"
                          }`}
                        >
                          <p className={`text-sm font-medium ${visitTextTone(currentVisitStatus)}`}>
                            {visitStatusLabel(currentVisitStatus)} registrada
                            {finalFeedback?.at
                              ? ` em ${new Date(finalFeedback.at).toLocaleString("pt-BR")}`
                              : ""}
                            .
                          </p>
                          {finalFeedback?.note && (
                            <p className="mt-2 whitespace-pre-wrap text-sm text-foreground">
                              {finalFeedback.note}
                            </p>
                          )}
                          {isAdministrador && !editingVisitResults[entry.id] && (
                            <Button
                              type="button"
                              size="sm"
                              variant="outline"
                              className="mt-3"
                              onClick={() => {
                                setVisitStages((current) => ({
                                  ...current,
                                  [entry.id]:
                                    currentVisitStatus === "proposal"
                                      ? "Proposta"
                                      : "Visita realizada",
                                }));
                                setFeedback((current) => ({
                                  ...current,
                                  [entry.id]: finalFeedback?.note ?? "",
                                }));
                                setEditingVisitResults((current) => ({
                                  ...current,
                                  [entry.id]: true,
                                }));
                              }}
                            >
                              <Pencil size={15} /> Corrigir resultado
                            </Button>
                          )}
                        </div>
                      )}

                    {!isLeadVisit(entry) &&
                      !isSaleTransfer(entry) &&
                      (entry.feedback_at ? (
                        <p className="mt-3 text-sm text-emerald-300">
                          Retorno: {entry.feedback_note || "Registrado"} ·{" "}
                          {new Date(entry.feedback_at).toLocaleString("pt-BR")}
                        </p>
                      ) : entry.target_user_id === profile?.id ||
                        isParticipant(entry) ||
                        isAdministrador ? (
                        <div className="mt-4 flex flex-col gap-2 sm:flex-row">
                          <input
                            value={feedback[entry.id] ?? ""}
                            onChange={(event) =>
                              setFeedback((current) => ({
                                ...current,
                                [entry.id]: event.target.value,
                              }))
                            }
                            placeholder="Observação do retorno (opcional)"
                            className="min-w-0 flex-1 rounded-lg bg-white/[.05] p-2 text-sm text-foreground"
                          />
                          <Button
                            size="sm"
                            className="w-full sm:w-auto"
                            onClick={() => void registerFeedback(entry)}
                          >
                            Concluir demanda
                          </Button>
                        </div>
                      ) : null)}
                    {canDeleteEntry(entry) && editingEntryId !== entry.id && (
                      <div className="mt-3 flex flex-wrap gap-2">
                        {canManageEntry(entry) && (
                          <Button
                            size="sm"
                            variant="ghost"
                            onClick={() => startEditingEntry(entry)}
                          >
                            <Pencil size={15} /> Editar
                          </Button>
                        )}
                        <Button
                          size="sm"
                          variant="ghost"
                          className="text-red-300"
                          onClick={() => void remove(entry.id)}
                        >
                          Excluir
                        </Button>
                      </div>
                    )}
                  </article>
                );
              })}
            </div>
          </div>
        </div>
      )}
    </section>
  );
}

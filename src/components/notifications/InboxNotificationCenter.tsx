import {
  Bell,
  Building2,
  CalendarDays,
  CheckCheck,
  CircleAlert,
  ExternalLink,
  FileText,
  Handshake,
  History,
  Info,
  Loader2,
  MessageCircle,
  RefreshCw,
  Timer,
  Trash2,
  UserPlus,
  FileWarning,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "@tanstack/react-router";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { supabase } from "@/lib/supabase";
import { displayText } from "@/lib/display-text";
import { recordNotificationClientEvent, reportCrmClientError } from "@/lib/audit-client";

type InboxNotification = {
  id: string;
  kind: string;
  title: string;
  body: string;
  url: string;
  payload: Record<string, unknown>;
  created_at: string;
  available_at: string | null;
  read_at: string | null;
};

type CurrentLeadOffer = {
  id: string;
  owner_id: string;
  assignment_status: string;
  assignment_run_number: number | null;
  assignment_available_at: string | null;
  assignment_deadline_at: string | null;
};

const NOTIFICATION_SOUND_URL = "/notification.mp3";

type AcceptanceNotice = {
  message: string;
  expired: boolean;
};

const iconByKind: Record<string, typeof Bell> = {
  lead_assignment: UserPlus,
  lead_direct_assignment: UserPlus,
  lead_unanswered: CircleAlert,
  attendance_reminder: Timer,
  visit_started: CalendarDays,
  visit_follow_up: CalendarDays,
  visit_feedback_reminder: CalendarDays,
  proposal_admin_alert: Handshake,
  property_match: Handshake,
  property_document_reminder: CircleAlert,
  lead_proposal_document_reminder: CircleAlert,
  assignment_lab: Info,
  assignment_lab_complete: Info,
  assignment_queue_separation_test: Info,
  agenda_new_demand: CalendarDays,
  agenda_reminder: CalendarDays,
  sale_delivery: CalendarDays,
  sale_delivery_reminder: Timer,
  agenda_escalation: CircleAlert,
  agenda_protocol_reminder: CircleAlert,
  agenda_pickup_reminder: CalendarDays,
  agenda_cartorio_delivered_to_vitor: CalendarDays,
  agenda_cartorio_vitor_document_reminder: Timer,
  agenda_cartorio_vitor_document_overdue: CircleAlert,
  agenda_requester_reminder: Timer,
  agenda_requester_followup: Timer,
  agenda_request_progress: CalendarDays,
  agenda_request_completed: CheckCheck,
  lead_visit_scheduled: CalendarDays,
  lead_assignment_expired: Timer,
  whatsapp_code_unmatched: CircleAlert,
  whatsapp_lead_intervention: CircleAlert,
  lead_registration_incomplete: CircleAlert,
  whatsapp_message_ambiguous: Info,
  whatsapp_existing_lead_contact: MessageCircle,
  property_value_review: CircleAlert,
  property_value_approval: CircleAlert,
  property_portal_price_update: CircleAlert,
  allyson_user_activity: History,
  financing_new: Handshake,
  financing_checklist_pending: CircleAlert,
  financing_documentation_pending: FileText,
  financing_conformity_restart: RefreshCw,
  financing_registry_details: Building2,
  property_pending: FileWarning,
};

const auditFieldLabels: Record<string, string> = {
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
};

type AuditChange = { before?: unknown; after?: unknown };

function auditChanges(payload: Record<string, unknown>) {
  if (payload.changes === null || typeof payload.changes !== "object") return [];
  return Object.entries(payload.changes as Record<string, AuditChange>);
}

function formatAuditValue(field: string, value: unknown) {
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
  ) {
    return value.toLocaleString("pt-BR", { style: "currency", currency: "BRL" });
  }
  if (typeof value === "string" && /^\d{4}-\d{2}-\d{2}T/.test(value)) {
    const date = new Date(value);
    if (!Number.isNaN(date.getTime())) return date.toLocaleString("pt-BR");
  }
  if (typeof value === "object") return JSON.stringify(value);
  return displayText(String(value));
}

function relativeTime(value: string) {
  const seconds = Math.max(0, Math.floor((Date.now() - new Date(value).getTime()) / 1_000));
  if (seconds < 60) return "Agora";
  if (seconds < 3_600) return `Há ${Math.floor(seconds / 60)} min`;
  if (seconds < 86_400) return `Há ${Math.floor(seconds / 3_600)} h`;
  return new Date(value).toLocaleDateString("pt-BR");
}

function whatsappUrl(phone: unknown) {
  const digits = String(phone ?? "").replace(/\D/g, "");
  if (!digits) return null;
  return `https://wa.me/${digits.length <= 11 ? `55${digits}` : digits}`;
}

function acceptanceNotice(notification: InboxNotification, errorMessage: string): AcceptanceNotice {
  if (notification.kind !== "lead_assignment") {
    return { message: errorMessage || "Não foi possível aceitar esta atribuição.", expired: false };
  }

  const deadline = new Date(String(notification.payload.deadlineAt ?? "")).getTime();
  const normalizedError = errorMessage
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase();
  const expired =
    (Number.isFinite(deadline) && deadline <= Date.now()) ||
    normalizedError.includes("nao esta mais disponivel para aceite");

  if (expired) {
    return {
      message: "Este lead já expirou e não é mais possível aceitar.",
      expired: true,
    };
  }

  return {
    message:
      errorMessage ||
      "Não foi possível aceitar este lead. Atualize as notificações e tente novamente.",
    expired: false,
  };
}

function isCurrentLeadOffer(
  notification: InboxNotification,
  offer: CurrentLeadOffer | undefined,
  userId: string | undefined,
  now: number,
) {
  if (!offer || !userId || offer.owner_id !== userId || offer.assignment_status !== "pending")
    return false;
  const availableAt = Date.parse(offer.assignment_available_at ?? "");
  const deadlineAt = Date.parse(offer.assignment_deadline_at ?? "");
  if (!Number.isFinite(availableAt) || !Number.isFinite(deadlineAt)) return false;
  if (now < availableAt || now >= deadlineAt) return false;
  const notifiedRun = notification.payload.runNumber;
  return notifiedRun == null || Number(notifiedRun) === offer.assignment_run_number;
}

export function InboxNotificationCenter({ userId }: { userId?: string }) {
  const navigate = useNavigate();
  const [notifications, setNotifications] = useState<InboxNotification[]>([]);
  const [currentLeadOffers, setCurrentLeadOffers] = useState<Record<string, CurrentLeadOffer>>({});
  const [offerClock, setOfferClock] = useState(() => Date.now());
  const [loading, setLoading] = useState(false);
  const [acceptingId, setAcceptingId] = useState<string | null>(null);
  const [acceptanceNotices, setAcceptanceNotices] = useState<Record<string, AcceptanceNotice>>({});
  const [decidingAgendaId, setDecidingAgendaId] = useState<string | null>(null);
  const [agendaDecisionNotices, setAgendaDecisionNotices] = useState<Record<string, string>>({});
  const [financingDecisionNotices, setFinancingDecisionNotices] = useState<Record<string, string>>(
    {},
  );
  const [decidingFinancingId, setDecidingFinancingId] = useState<string | null>(null);
  const [propertyLinks, setPropertyLinks] = useState<Record<string, string>>({});
  const presentedIds = useRef(new Set<string>());
  const soundedIds = useRef(new Set<string>());
  const soundingIds = useRef(new Set<string>());
  const pendingSounds = useRef(new Map<string, string | undefined>());
  const knownNotificationIds = useRef(new Set<string>());
  const standardSound = useRef<HTMLAudioElement | null>(null);
  const leadSound = useRef<HTMLAudioElement | null>(null);

  const playNotificationSound = useCallback((notificationId: string, kind?: string) => {
    if (
      !notificationId ||
      soundedIds.current.has(notificationId) ||
      soundingIds.current.has(notificationId)
    )
      return;
    const audio = kind === "lead_assignment" ? leadSound.current : standardSound.current;
    if (!audio) {
      pendingSounds.current.set(notificationId, kind);
      return;
    }
    soundingIds.current.add(notificationId);
    audio.currentTime = 0;
    void audio
      .play()
      .then(() => {
        soundedIds.current.add(notificationId);
        pendingSounds.current.delete(notificationId);
      })
      .catch(() => {
        // Retente depois da primeira interação do usuário. Uma tentativa
        // bloqueada pelo navegador não pode consumir definitivamente o aviso.
        pendingSounds.current.set(notificationId, kind);
      })
      .finally(() => soundingIds.current.delete(notificationId));
  }, []);

  const load = useCallback(async () => {
    if (!userId) return;
    setLoading(true);
    const { data, error } = await supabase
      .from("crm_notification_outbox")
      .select("id, kind, title, body, url, payload, created_at, available_at, read_at")
      .eq("recipient_id", userId)
      .is("dismissed_at", null)
      .neq("delivery_status", "cancelled")
      .order("created_at", { ascending: false })
      .limit(50);
    if (error) {
      await reportCrmClientError(error, {
        area: "notifications",
        operation: "Carregar caixa de notificações",
      });
    }
    const loaded = (data ?? []) as InboxNotification[];
    const leadIds = [
      ...new Set(
        loaded
          .filter((notification) => notification.kind === "lead_assignment")
          .map((notification) => String(notification.payload.leadId ?? ""))
          .filter(Boolean),
      ),
    ];
    let offersById: Record<string, CurrentLeadOffer> = {};
    if (leadIds.length) {
      const { data: offers, error: offerError } = await supabase
        .from("crm_leads")
        .select(
          "id,owner_id,assignment_status,assignment_run_number,assignment_available_at,assignment_deadline_at",
        )
        .in("id", leadIds);
      if (offerError) {
        await reportCrmClientError(offerError, {
          area: "notifications",
          operation: "Conferir ofertas de leads",
        });
      }
      offersById = Object.fromEntries(
        ((offers ?? []) as CurrentLeadOffer[]).map((offer) => [offer.id, offer]),
      );
      setCurrentLeadOffers(offersById);
    } else {
      setCurrentLeadOffers({});
    }
    // An offer can be superseded by a direct transfer or by the next queue
    // turn before this browser receives its realtime event. Do not sound or
    // show a notification that can no longer be accepted.
    const visibleNotifications = loaded.filter((notification) => {
      if (notification.kind !== "lead_assignment") return true;
      const leadId = String(notification.payload.leadId ?? "");
      return isCurrentLeadOffer(notification, offersById[leadId], userId, Date.now());
    });
    const newlyVisible = visibleNotifications.find((notification) => {
      const availableAt = notification.available_at
        ? new Date(notification.available_at).getTime()
        : 0;
      return (
        !knownNotificationIds.current.has(notification.id) &&
        !notification.read_at &&
        availableAt <= Date.now()
      );
    });
    if (newlyVisible) playNotificationSound(newlyVisible.id, newlyVisible.kind);
    knownNotificationIds.current = new Set(
      visibleNotifications.map((notification) => notification.id),
    );
    setNotifications(visibleNotifications);
    const propertyIds = [
      ...new Set(
        loaded
          .filter((notification) => notification.kind === "property_match")
          .map((notification) =>
            String(
              notification.payload.propertyId ?? notification.payload.propertyExternalId ?? "",
            ),
          )
          .filter(Boolean),
      ),
    ];
    if (propertyIds.length) {
      const { data: links } = await supabase
        .from("crm_property_public_links")
        .select("property_id, url")
        .in("property_id", propertyIds);
      setPropertyLinks(
        Object.fromEntries((links ?? []).map((link) => [String(link.property_id), link.url])),
      );
    } else {
      setPropertyLinks({});
    }
    setLoading(false);
  }, [playNotificationSound, userId]);

  useEffect(() => {
    const audio = new Audio(NOTIFICATION_SOUND_URL);
    audio.preload = "auto";
    standardSound.current = audio;

    const leadAudio = new Audio("/lead-notification.mp3");
    leadAudio.preload = "auto";
    leadSound.current = leadAudio;

    const unlockAudio = () => {
      audio.muted = true;
      leadAudio.muted = true;
      void Promise.allSettled([audio.play(), leadAudio.play()]).then(() => {
        audio.pause();
        audio.currentTime = 0;
        audio.muted = false;
        leadAudio.pause();
        leadAudio.currentTime = 0;
        leadAudio.muted = false;
        for (const [notificationId, kind] of pendingSounds.current) {
          playNotificationSound(notificationId, kind);
        }
      });
    };
    window.addEventListener("pointerdown", unlockAudio, { once: true });
    window.addEventListener("keydown", unlockAudio, { once: true });

    return () => {
      window.removeEventListener("pointerdown", unlockAudio);
      window.removeEventListener("keydown", unlockAudio);
      audio.pause();
      leadAudio.pause();
      standardSound.current = null;
      leadSound.current = null;
    };
  }, [playNotificationSound]);

  useEffect(() => {
    void load();
    if (!userId) return;
    const offerTimer = window.setInterval(() => setOfferClock(Date.now()), 5_000);
    const channel = supabase
      .channel(`notification-inbox:${userId}`)
      .on(
        "postgres_changes",
        {
          event: "INSERT",
          schema: "public",
          table: "crm_notification_outbox",
          filter: `recipient_id=eq.${userId}`,
        },
        (payload) => {
          const availableAt = String(payload.new.available_at ?? "");
          if (!availableAt || new Date(availableAt).getTime() <= Date.now()) {
            playNotificationSound(String(payload.new.id ?? ""), String(payload.new.kind ?? ""));
          }
          void load();
        },
      )
      .on(
        "postgres_changes",
        {
          event: "UPDATE",
          schema: "public",
          table: "crm_notification_outbox",
          filter: `recipient_id=eq.${userId}`,
        },
        (payload) => {
          if (payload.new.delivery_status === "sent" && payload.old.delivery_status !== "sent") {
            playNotificationSound(String(payload.new.id ?? ""), String(payload.new.kind ?? ""));
          }
          void load();
        },
      )
      .on(
        "postgres_changes",
        {
          event: "DELETE",
          schema: "public",
          table: "crm_notification_outbox",
          filter: `recipient_id=eq.${userId}`,
        },
        () => void load(),
      )
      .subscribe((status) => {
        if (status === "CHANNEL_ERROR" || status === "TIMED_OUT") void load();
      });
    // Contingência para reconexões: antes eram 240 consultas por hora por usuário.
    const timer = window.setInterval(() => void load(), 30_000);
    return () => {
      window.clearInterval(offerTimer);
      window.clearInterval(timer);
      void supabase.removeChannel(channel);
    };
  }, [load, playNotificationSound, userId]);

  const unread = useMemo(
    () => notifications.filter((notification) => !notification.read_at).length,
    [notifications],
  );

  const markRead = async (id: string) => {
    if (notifications.find((notification) => notification.id === id)?.read_at) return;
    const now = new Date().toISOString();
    setNotifications((current) =>
      current.map((notification) =>
        notification.id === id
          ? { ...notification, read_at: notification.read_at ?? now }
          : notification,
      ),
    );
    const { error } = await supabase
      .from("crm_notification_outbox")
      .update({ read_at: now })
      .eq("id", id)
      .is("read_at", null);
    if (error) {
      void recordNotificationClientEvent(id, "notification_client_error", {
        operation: "mark_read",
        message: error.message,
      });
    }
  };

  const markAllRead = async () => {
    const ids = notifications
      .filter((notification) => !notification.read_at)
      .map((notification) => notification.id);
    if (!ids.length) return;
    const now = new Date().toISOString();
    setNotifications((current) =>
      current.map((notification) => ({ ...notification, read_at: now })),
    );
    const { error } = await supabase
      .from("crm_notification_outbox")
      .update({ read_at: now })
      .in("id", ids)
      .is("read_at", null);
    if (error) {
      await reportCrmClientError(error, {
        area: "notifications",
        operation: "Marcar todas as notificações como lidas",
        details: { notificationCount: ids.length },
      });
    }
  };

  const clear = async () => {
    const ids = notifications.map((notification) => notification.id);
    if (!ids.length) return;
    setNotifications([]);
    const { error } = await supabase
      .from("crm_notification_outbox")
      .update({ dismissed_at: new Date().toISOString() })
      .in("id", ids);
    if (error) {
      await reportCrmClientError(error, {
        area: "notifications",
        operation: "Limpar caixa de notificações",
        details: { notificationCount: ids.length },
      });
    }
  };

  const openNotification = async (notification: InboxNotification) => {
    await Promise.all([
      markRead(notification.id),
      recordNotificationClientEvent(notification.id, "inbox_opened", {
        source: "notification_center",
        targetUrl: notification.url,
      }),
    ]);
    if (typeof window !== "undefined") {
      const target = new URL(notification.url || window.location.pathname, window.location.origin);
      if (target.origin !== window.location.origin) return;
      target.searchParams.set("notificationId", notification.id);
      target.searchParams.set("notificationKind", notification.kind);
      target.searchParams.set("notificationTitle", notification.title);
      target.searchParams.set("notificationBody", notification.body);
      const propertyId = String(
        notification.payload.propertyId ?? notification.payload.propertyExternalId ?? "",
      );
      const leadId = String(notification.payload.leadId ?? "");
      const agendaId = String(notification.payload.agendaId ?? "");
      const reviewRequestId = String(notification.payload.reviewRequestId ?? "");
      if (propertyId) target.searchParams.set("focusPropertyId", propertyId);
      if (leadId) target.searchParams.set("focusLeadId", leadId);
      if (agendaId) target.searchParams.set("focusAgendaId", agendaId);
      if (reviewRequestId) target.searchParams.set("reviewRequestId", reviewRequestId);
      window.location.assign(`${target.pathname}${target.search}${target.hash}`);
    }
  };

  const recordInboxPresentation = (open: boolean) => {
    if (!open) return;
    const happenedAt = new Date().toISOString();
    for (const notification of notifications) {
      if (presentedIds.current.has(notification.id)) continue;
      presentedIds.current.add(notification.id);
      void recordNotificationClientEvent(notification.id, "inbox_presented", {
        clientEventId: "first-inbox-presentation",
        happenedAt,
        source: "notification_center",
      });
    }
  };

  const acceptLead = async (notification: InboxNotification) => {
    const leadId = String(notification.payload.leadId ?? "");
    if (
      notification.kind === "lead_assignment" &&
      !isCurrentLeadOffer(notification, currentLeadOffers[leadId], userId, Date.now())
    ) {
      setAcceptanceNotices((current) => ({
        ...current,
        [notification.id]: {
          message: "Esta oferta não está mais ativa. Confira o lead atual.",
          expired: true,
        },
      }));
      await load();
      return;
    }
    setAcceptanceNotices((current) => {
      const next = { ...current };
      delete next[notification.id];
      return next;
    });
    setAcceptingId(notification.id);
    const isLabTest = notification.kind === "assignment_lab" && Boolean(notification.payload.runId);
    const { error } = isLabTest
      ? await supabase.rpc("accept_assignment_notification_test", {
          p_run_id: String(notification.payload.runId),
        })
      : leadId
        ? await supabase.rpc("accept_lead_assignment", { p_lead_id: leadId })
        : { error: new Error("Lead da notificação não encontrado.") };
    setAcceptingId(null);
    if (!error) {
      await Promise.all([
        markRead(notification.id),
        recordNotificationClientEvent(notification.id, "inbox_opened", {
          source: "accept_assignment",
        }),
      ]);
      await load();
      void navigate({ to: "/leads" });
    } else {
      setAcceptanceNotices((current) => ({
        ...current,
        [notification.id]: acceptanceNotice(notification, error.message),
      }));
      void recordNotificationClientEvent(notification.id, "notification_client_error", {
        operation: "accept_assignment",
        message: error.message,
      });
      void load();
    }
  };

  const decideAgendaCompanion = async (notification: InboxNotification, approved: boolean) => {
    const agendaId = String(notification.payload.agendaId ?? "");
    setDecidingAgendaId(notification.id);
    const { data, error } = await supabase.rpc("decide_agenda_companion_request", {
      p_entry_id: agendaId,
      p_approved: approved,
    });
    setDecidingAgendaId(null);
    if (error) {
      setAgendaDecisionNotices((current) => ({
        ...current,
        [notification.id]: displayText(error.message),
      }));
      return;
    }
    setAgendaDecisionNotices((current) => ({
      ...current,
      [notification.id]:
        data === "approved" ? "Acompanhante autorizado." : "Acompanhante recusado.",
    }));
    await markRead(notification.id);
    await load();
  };

  const decideFinancingChecklist = async (notification: InboxNotification, sent: boolean) => {
    const processId = String(notification.payload.processId ?? "");
    setDecidingFinancingId(notification.id);
    const { error } = await supabase.rpc("update_financing_process", {
      p_process_id: processId,
      p_action: "checklist_sent",
      p_payload: { sent },
      p_expected_version: null,
      p_note: "Resposta registrada diretamente na notificacao inicial.",
    });
    setDecidingFinancingId(null);
    if (error) {
      setFinancingDecisionNotices((current) => ({
        ...current,
        [notification.id]: displayText(error.message),
      }));
      return;
    }
    setFinancingDecisionNotices((current) => ({
      ...current,
      [notification.id]: sent ? "Checklist marcado como enviado." : "Checklist permanece pendente.",
    }));
    await markRead(notification.id);
  };

  if (!userId) return null;

  return (
    <DropdownMenu onOpenChange={recordInboxPresentation}>
      <DropdownMenuTrigger asChild>
        <button
          className="glass relative grid h-10 w-10 place-items-center rounded-xl transition hover:bg-white/[0.05]"
          aria-label="Abrir caixa de entrada de notificações"
        >
          <Bell size={17} strokeWidth={1.75} />
          {unread > 0 && (
            <span className="absolute -right-1 -top-1 grid h-4 min-w-4 place-items-center rounded-full bg-copper px-1 text-[9px] font-bold text-white">
              {unread > 9 ? "9+" : unread}
            </span>
          )}
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent
        align="end"
        className="glass-strong w-[min(94vw,430px)] border-white/10 p-0"
      >
        <div className="flex items-center justify-between px-4 py-3">
          <DropdownMenuLabel className="p-0 text-sm text-foreground">
            Notificações
            {unread > 0 && (
              <span className="ml-1.5 rounded-full bg-copper/15 px-1.5 py-0.5 text-[10px] text-copper">
                {unread} novas
              </span>
            )}
          </DropdownMenuLabel>
          <div className="flex gap-1">
            <Button
              variant="ghost"
              size="icon"
              aria-label="Marcar todas como lidas"
              title="Marcar todas como lidas"
              disabled={!unread}
              onClick={() => void markAllRead()}
            >
              <CheckCheck size={15} />
            </Button>
            <Button
              variant="ghost"
              size="icon"
              aria-label="Limpar notificações"
              title="Limpar notificações"
              disabled={!notifications.length}
              onClick={() => void clear()}
            >
              <Trash2 size={15} />
            </Button>
          </div>
        </div>
        <DropdownMenuSeparator className="m-0" />
        <div className="max-h-[min(460px,calc(100dvh-8rem))] overscroll-contain overflow-y-auto p-1.5">
          {loading && !notifications.length ? (
            <div className="flex justify-center px-4 py-10 text-muted-foreground">
              <Loader2 className="animate-spin" size={18} />
            </div>
          ) : notifications.length === 0 ? (
            <div className="px-4 py-10 text-center text-sm text-muted-foreground">
              Sua central está em dia.
            </div>
          ) : (
            notifications.map((notification) => {
              const Icon = iconByKind[notification.kind] ?? Bell;
              const changes = auditChanges(notification.payload);
              const phoneUrl = whatsappUrl(notification.payload.phone);
              const leadOffer =
                notification.kind === "lead_assignment" && Boolean(notification.payload.leadId);
              const canAccept =
                (leadOffer &&
                  isCurrentLeadOffer(
                    notification,
                    currentLeadOffers[String(notification.payload.leadId)],
                    userId,
                    offerClock,
                  )) ||
                (notification.kind === "assignment_lab" && Boolean(notification.payload.runId));
              const acceptanceFeedback = acceptanceNotices[notification.id];
              const isAgendaApproval = notification.kind === "agenda_companion_approval";
              const persistedAgendaDecision = String(
                notification.payload.decisionStatus ?? "pending",
              );
              const agendaDecisionSaved =
                persistedAgendaDecision === "approved" || persistedAgendaDecision === "rejected";
              const isFinancingChecklist =
                notification.kind === "financing_new" &&
                notification.payload.action === "checklist_sent";
              const matchedPropertyId = String(
                notification.payload.propertyId ?? notification.payload.propertyExternalId ?? "",
              );
              const matchedPropertyUrl = matchedPropertyId
                ? propertyLinks[matchedPropertyId] ||
                  `/imoveis?focusPropertyId=${encodeURIComponent(matchedPropertyId)}`
                : "";
              return (
                <article
                  key={notification.id}
                  className={`rounded-lg p-3 transition hover:bg-white/[0.05] ${notification.read_at ? "opacity-65" : ""}`}
                >
                  <div className="flex gap-3">
                    <span
                      className={`grid h-8 w-8 shrink-0 place-items-center rounded-lg ${notification.kind === "property_pending" ? "bg-red-400/20 text-red-400" : "bg-copper/10 text-copper"}`}
                    >
                      <Icon size={15} />
                    </span>
                    <div className="min-w-0 flex-1">
                      <div className="flex items-center gap-2">
                        {notification.kind === "property_pending" && (
                          <span className="rounded bg-red-400/20 px-1 py-0.5 text-[9px] font-bold tracking-wider text-red-400">
                            CRÍTICO
                          </span>
                        )}
                        <p className="truncate text-xs font-medium text-foreground">
                          {displayText(notification.title)}
                        </p>
                        {!notification.read_at && (
                          <span className="h-1.5 w-1.5 shrink-0 rounded-full bg-copper" />
                        )}
                      </div>
                      <p className="mt-0.5 text-xs leading-relaxed text-muted-foreground">
                        {displayText(notification.body)}
                      </p>
                      {changes.length > 0 && (
                        <div className="mt-2 space-y-1.5 rounded-lg border border-white/10 bg-black/10 p-2">
                          {changes.map(([field, change]) => (
                            <div key={field} className="text-[11px] leading-relaxed">
                              <span className="font-medium text-foreground">
                                {auditFieldLabels[field] ?? field.replaceAll("_", " ")}:
                              </span>{" "}
                              <span className="text-red-300/90 line-through">
                                {formatAuditValue(field, change.before)}
                              </span>{" "}
                              <span className="text-muted-foreground">→</span>{" "}
                              <span className="text-emerald-300">
                                {formatAuditValue(field, change.after)}
                              </span>
                            </div>
                          ))}
                        </div>
                      )}
                      <p className="mt-1 text-[10px] text-muted-foreground/70">
                        {notification.kind === "allyson_user_activity"
                          ? new Date(notification.created_at).toLocaleString("pt-BR")
                          : relativeTime(notification.created_at)}
                      </p>
                      {acceptanceFeedback ? (
                        <p
                          role="alert"
                          className={`mt-2 rounded-md border px-2.5 py-2 text-[11px] leading-relaxed ${
                            acceptanceFeedback.expired
                              ? "border-amber-400/30 bg-amber-400/10 text-amber-200"
                              : "border-red-400/30 bg-red-400/10 text-red-200"
                          }`}
                        >
                          {acceptanceFeedback.message}
                        </p>
                      ) : null}
                      <div className="mt-3 flex flex-wrap gap-2">
                        {isFinancingChecklist && !financingDecisionNotices[notification.id] ? (
                          <>
                            <span className="w-full text-[11px] font-medium text-foreground">
                              Checklist enviado?
                            </span>
                            <button
                              onClick={() => void decideFinancingChecklist(notification, true)}
                              disabled={decidingFinancingId === notification.id}
                              className="rounded-md bg-emerald-600 px-2.5 py-1.5 text-[11px] font-medium text-white disabled:opacity-60"
                            >
                              Sim
                            </button>
                            <button
                              onClick={() => void decideFinancingChecklist(notification, false)}
                              disabled={decidingFinancingId === notification.id}
                              className="rounded-md border border-red-400/40 px-2.5 py-1.5 text-[11px] text-red-200 disabled:opacity-60"
                            >
                              Nao
                            </button>
                          </>
                        ) : null}
                        {financingDecisionNotices[notification.id] ? (
                          <span className="w-full text-[11px] text-emerald-300">
                            {financingDecisionNotices[notification.id]}
                          </span>
                        ) : null}
                        {isAgendaApproval &&
                          !agendaDecisionSaved &&
                          !agendaDecisionNotices[notification.id] && (
                            <>
                              <button
                                onClick={() => void decideAgendaCompanion(notification, true)}
                                disabled={decidingAgendaId === notification.id}
                                className="rounded-md bg-emerald-600 px-2.5 py-1.5 text-[11px] font-medium text-white disabled:opacity-60"
                              >
                                Sim
                              </button>
                              <button
                                onClick={() => void decideAgendaCompanion(notification, false)}
                                disabled={decidingAgendaId === notification.id}
                                className="rounded-md border border-red-400/40 px-2.5 py-1.5 text-[11px] text-red-200 disabled:opacity-60"
                              >
                                Não
                              </button>
                            </>
                          )}
                        {(agendaDecisionSaved || agendaDecisionNotices[notification.id]) && (
                          <span
                            className={`text-[11px] ${persistedAgendaDecision === "rejected" ? "text-red-300" : "text-emerald-300"}`}
                          >
                            {agendaDecisionNotices[notification.id] ||
                              (persistedAgendaDecision === "approved"
                                ? "Acompanhante autorizado. Decisão salva."
                                : "Acompanhante recusado. Decisão salva.")}
                            {notification.payload.decisionByName
                              ? ` Por ${displayText(String(notification.payload.decisionByName))}.`
                              : ""}
                          </span>
                        )}
                        {canAccept && (
                          <button
                            onClick={() => void acceptLead(notification)}
                            disabled={
                              acceptingId === notification.id ||
                              Boolean(acceptanceFeedback?.expired)
                            }
                            className="rounded-md bg-copper px-2.5 py-1.5 text-[11px] font-medium text-white disabled:opacity-60"
                          >
                            {acceptingId === notification.id
                              ? "Assumindo…"
                              : acceptanceFeedback?.expired
                                ? "Lead expirado"
                                : "Assumir atendimento"}
                          </button>
                        )}
                        {leadOffer && !canAccept && (
                          <span className="text-[11px] text-muted-foreground">
                            Oferta encerrada ou ainda não liberada
                          </span>
                        )}
                        {phoneUrl && (
                          <a
                            href={phoneUrl}
                            target="_blank"
                            rel="noreferrer"
                            onClick={() => {
                              void Promise.all([
                                markRead(notification.id),
                                recordNotificationClientEvent(notification.id, "inbox_opened", {
                                  source: "whatsapp_action",
                                }),
                              ]);
                            }}
                            className="inline-flex items-center gap-1 rounded-md border border-white/10 px-2.5 py-1.5 text-[11px] text-foreground transition hover:border-copper/40"
                          >
                            <MessageCircle size={12} /> WhatsApp
                          </a>
                        )}
                        <button
                          onClick={() => void openNotification(notification)}
                          className="inline-flex items-center gap-1 rounded-md border border-white/10 px-2.5 py-1.5 text-[11px] text-foreground transition hover:border-copper/40"
                        >
                          <ExternalLink size={12} /> Abrir
                        </button>
                        {notification.kind === "property_match" && matchedPropertyUrl ? (
                          <a
                            href={matchedPropertyUrl}
                            target="_blank"
                            rel="noreferrer"
                            onClick={() => {
                              void Promise.all([
                                markRead(notification.id),
                                recordNotificationClientEvent(notification.id, "inbox_opened", {
                                  source: "property_match_link",
                                  propertyId: matchedPropertyId,
                                }),
                              ]);
                            }}
                            className="inline-flex items-center gap-1 rounded-md border border-amber-400/30 bg-amber-400/10 px-2.5 py-1.5 text-[11px] font-medium text-amber-200 transition hover:bg-amber-400/15"
                          >
                            <ExternalLink size={12} /> Ver imóvel
                          </a>
                        ) : null}
                      </div>
                    </div>
                  </div>
                </article>
              );
            })
          )}
        </div>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

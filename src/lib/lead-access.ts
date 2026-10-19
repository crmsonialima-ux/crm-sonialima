import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect } from "react";
import { LEAD_DISTRIBUTION_QUERY_KEY, type LeadType } from "@/lib/lead-distribution";
import { canonicalLeadOrigin } from "@/lib/lead-origin";
import {
  ADMINISTRATOR_ADMIN_ID,
  isAdministradorAdmin,
  isVitorProfile,
} from "@/lib/admin-access";
import { supabase } from "@/lib/supabase";
import { displayText } from "@/lib/display-text";

export type CrmRole = "admin" | "broker";

export type AccessProfile = {
  id: string;
  fullName: string;
  email: string;
  role: CrmRole;
};

export type ManagedLead = {
  id: string;
  nome: string;
  segundoNome?: string;
  telefone?: string;
  telefonesAdicionais: string[];
  email?: string;
  imovel?: string;
  estagio: string;
  canal?: string;
  sourcePortal?: string;
  sourceListingId?: string;
  registrationMissingFields: string[];
  valor: number;
  observacoes?: string;
  corretor?: string;
  ownerEmail?: string;
  ownerId: string;
  createdBy: string;
  criadoEm: string;
  externalId?: string;
  atualizadoEm?: string;
  visitaAgendadaEm?: string;
  visitaRealizadaEm?: string;
  propostaEm?: string;
  visitExecutorId?: string;
  visitExecutorIds: string[];
  tipoLead?: LeadType;
  valorDesejado?: number;
  localizacaoDesejada?: string;
  assignmentStatus?: "pending" | "accepted" | "exhausted";
  assignmentAvailableAt?: string;
  assignmentDeadlineAt?: string;
  postAcceptanceQualificationDeadlineAt?: string;
  postAcceptanceCallMade?: boolean;
  postAcceptanceCallResult?: string;
  postAcceptanceInteraction?: string;
  postAcceptanceWhatsappContacted?: boolean;
  postAcceptanceWhatsappPrintPath?: string;
  postAcceptanceWhatsappHasWhatsapp?: boolean;
  postAcceptanceQualificationCompletedAt?: string;
  postAcceptanceQualificationExpiredAt?: string;
  hasPropertyToSell?: boolean;
  propertyToSellLocation?: string;
  propertyToSellValue?: number;
  needsFinancing?: boolean;
  willUseFgts?: boolean;
  bankingCorrespondentPresented?: boolean;
  visitPropertyCaptured?: boolean;
  commercialQualificationRequired: boolean;
  propertyMatches: PropertyMatchOffer[];
};

export type PropertyMatchOffer = {
  propertyId: string;
  title: string;
  url?: string;
  expiresAt: string;
  offerStartedAt?: string;
  expiredAt?: string;
  dismissedAt?: string;
};

export type LeadQualificationInput = {
  hasPropertyToSell?: boolean;
  propertyToSellLocation?: string;
  propertyToSellValue?: number;
  needsFinancing?: boolean;
  willUseFgts?: boolean;
  bankingCorrespondentPresented?: boolean;
  visitPropertyCaptured?: boolean;
};

export const LEAD_PROGRESS_STAGES = [
  "Em atendimento",
  "Corretor",
  "Standby",
  "Aguardando imóvel similar",
  "Visita agendada",
  "Visita realizada",
  "Proposta",
  "Financiamento",
  "Comprou",
  "Não teve interesse",
  "Telefone não existe",
] as const;
export type LeadProgressStage = (typeof LEAD_PROGRESS_STAGES)[number];

export type CreateLeadInput = {
  nome: string;
  telefone?: string;
  telefonesAdicionais?: string[];
  email?: string;
  imovel?: string;
  estagio: string;
  canal?: string;
  valor: number;
  observacoes?: string;
  ownerId: string;
  tipoLead: LeadType;
  valorDesejado: number;
  localizacaoDesejada: string;
  visitScheduledAt?: string;
  visitExecutorId?: string;
  visitExecutorIds?: string[];
  distributeToQueue?: boolean;
};

export type CompleteLeadRegistrationInput = {
  leadId: string;
  nome: string;
  segundoNome: string;
  telefone: string;
  telefonesAdicionais: string[];
  email: string;
  imovel: string;
  tipoLead: LeadType;
  valorDesejado: number;
  localizacaoDesejada: string;
  canal: string;
  observacoes: string;
};

export type LeadActivity = {
  id: string;
  leadId: string;
  stage: string;
  note?: string;
  authorName: string;
  createdAt: string;
  scheduledFor?: string;
};

export type LeadTimelineEvent = LeadActivity & {
  eventType: string;
  sourceTable: string;
  sourceId: string;
  brokerName?: string;
};

type LeadRecord = {
  id: string;
  name: string;
  secondary_name: string | null;
  phone: string | null;
  additional_phones: string[] | null;
  email: string | null;
  property_interest: string | null;
  stage: string;
  channel: string | null;
  source_portal: string | null;
  source_listing_id: string | null;
  registration_missing_fields: string[] | null;
  budget: number | string | null;
  notes: string | null;
  owner_id: string;
  created_by: string;
  created_at: string;
  external_id: string | null;
  updated_at: string;
  has_property_to_sell: boolean | null;
  property_to_sell_location: string | null;
  property_to_sell_value: number | string | null;
  needs_financing: boolean | null;
  will_use_fgts: boolean | null;
  banking_correspondent_presented: boolean | null;
  visit_property_captured: boolean | null;
  commercial_qualification_required: boolean;
  visit_scheduled_at: string | null;
  visit_completed_at: string | null;
  proposal_at: string | null;
  visit_executor_id: string | null;
  visit_executor_ids?: string[] | null;
  lead_type: LeadType;
  assignment_status: "pending" | "accepted" | "exhausted";
  assignment_available_at: string | null;
  assignment_deadline_at: string | null;
  post_acceptance_qualification_deadline_at: string | null;
  post_acceptance_call_made: boolean | null;
  post_acceptance_call_result: string | null;
  post_acceptance_interaction: string | null;
  post_acceptance_whatsapp_contacted: boolean | null;
  post_acceptance_whatsapp_print_path: string | null;
  post_acceptance_whatsapp_has_whatsapp: boolean | null;
  post_acceptance_qualification_completed_at: string | null;
  post_acceptance_qualification_expired_at: string | null;
  desired_property_value: number | string | null;
  desired_location: string | null;
  owner?: { full_name?: string | null; email?: string | null } | null;
};

type LeadActivityRecord = {
  id: string;
  lead_id: string;
  stage: string;
  note: string | null;
  author_name: string;
  created_at: string;
  scheduled_for: string | null;
};

type LeadTimelineEventRecord = {
  id: string;
  lead_id: string;
  event_type: string;
  stage: string;
  note: string | null;
  actor_name: string;
  broker_name: string | null;
  occurred_at: string;
  scheduled_for: string | null;
  source_table: string;
  source_id: string;
};

type AgendaProfileRecord = {
  id: string;
  full_name: string | null;
  email: string;
  role: CrmRole;
};

type AgendaVisitRecord = {
  source_lead_id: string;
  scheduled_at: string;
  target_user_id: string | null;
  requested_companion_ids: string[] | null;
  companion_approval_status: string | null;
  participants: Array<{ user_id: string }> | null;
};

function message(error: unknown) {
  return error instanceof Error ? error.message : "Não foi possível concluir a operação.";
}

function mapLead(record: LeadRecord): ManagedLead {
  return {
    id: record.id,
    nome: record.name,
    segundoNome: record.secondary_name ?? undefined,
    telefone: record.phone ?? undefined,
    telefonesAdicionais: record.additional_phones ?? [],
    email: record.email ?? undefined,
    imovel: record.property_interest ?? undefined,
    estagio: record.stage,
    // Site leads retain link_bio as the intake portal for operational rules,
    // but channel is the user-facing origin: Site vs Link da bio.
    canal: canonicalLeadOrigin(record.channel) ?? canonicalLeadOrigin(record.source_portal),
    sourcePortal: record.source_portal ?? undefined,
    sourceListingId: record.source_listing_id ?? undefined,
    registrationMissingFields: Array.from(
      new Set(
        (record.registration_missing_fields ?? [])
          .filter((field): field is string => typeof field === "string")
          .filter((field) => field !== "email")
          .map((field) => field.trim())
          .filter(Boolean),
      ),
    ),
    valor: Number(record.budget ?? 0),
    observacoes: record.notes ?? undefined,
    corretor: record.owner?.full_name || record.owner?.email || "Não atribuído",
    ownerEmail: record.owner?.email ?? undefined,
    ownerId: record.owner_id,
    createdBy: record.created_by,
    criadoEm: record.created_at,
    externalId: record.external_id ?? undefined,
    atualizadoEm: record.updated_at,
    visitaAgendadaEm: record.visit_scheduled_at ?? undefined,
    visitaRealizadaEm: record.visit_completed_at ?? undefined,
    propostaEm: record.proposal_at ?? undefined,
    visitExecutorId: record.visit_executor_id ?? undefined,
    visitExecutorIds:
      record.visit_executor_ids ?? (record.visit_executor_id ? [record.visit_executor_id] : []),
    tipoLead: record.lead_type,
    assignmentStatus: record.assignment_status,
    assignmentAvailableAt: record.assignment_available_at ?? undefined,
    assignmentDeadlineAt: record.assignment_deadline_at ?? undefined,
    postAcceptanceQualificationDeadlineAt:
      record.post_acceptance_qualification_deadline_at ?? undefined,
    postAcceptanceCallMade: record.post_acceptance_call_made ?? undefined,
    postAcceptanceCallResult: record.post_acceptance_call_result ?? undefined,
    postAcceptanceInteraction: record.post_acceptance_interaction ?? undefined,
    postAcceptanceWhatsappContacted: record.post_acceptance_whatsapp_contacted ?? undefined,
    postAcceptanceWhatsappPrintPath: record.post_acceptance_whatsapp_print_path ?? undefined,
    postAcceptanceWhatsappHasWhatsapp: record.post_acceptance_whatsapp_has_whatsapp ?? undefined,
    postAcceptanceQualificationCompletedAt:
      record.post_acceptance_qualification_completed_at ?? undefined,
    postAcceptanceQualificationExpiredAt:
      record.post_acceptance_qualification_expired_at ?? undefined,
    valorDesejado: Number(record.desired_property_value ?? 0) || undefined,
    localizacaoDesejada: record.desired_location ?? undefined,
    hasPropertyToSell: record.has_property_to_sell ?? undefined,
    propertyToSellLocation: record.property_to_sell_location ?? undefined,
    propertyToSellValue: Number(record.property_to_sell_value ?? 0) || undefined,
    needsFinancing: record.needs_financing ?? undefined,
    willUseFgts: record.will_use_fgts ?? undefined,
    bankingCorrespondentPresented: record.banking_correspondent_presented ?? undefined,
    visitPropertyCaptured: record.visit_property_captured ?? undefined,
    commercialQualificationRequired: record.commercial_qualification_required,
    propertyMatches: [],
  };
}

async function getProfile(userId: string) {
  const { data, error } = await supabase
    .from("profiles")
    .select("id, full_name, email, role")
    .eq("id", userId)
    .single();
  if (error) throw new Error(error.message);
  return {
    id: data.id,
    fullName: data.full_name || data.email,
    email: data.email,
    role: data.role as CrmRole,
  } satisfies AccessProfile;
}

async function getLeads() {
  const leadFields =
    "id, name, secondary_name, phone, additional_phones, email, property_interest, stage, channel, source_portal, source_listing_id, registration_missing_fields, budget, notes, owner_id, created_by, created_at, external_id, updated_at, visit_scheduled_at, visit_completed_at, proposal_at, visit_executor_id, visit_executor_ids, lead_type, assignment_status, assignment_available_at, assignment_deadline_at, post_acceptance_qualification_deadline_at, post_acceptance_call_made, post_acceptance_call_result, post_acceptance_interaction, post_acceptance_whatsapp_contacted, post_acceptance_whatsapp_print_path, post_acceptance_whatsapp_has_whatsapp, post_acceptance_qualification_completed_at, post_acceptance_qualification_expired_at, desired_property_value, desired_location, has_property_to_sell, property_to_sell_location, property_to_sell_value, needs_financing, will_use_fgts, banking_correspondent_presented, visit_property_captured, commercial_qualification_required, owner:profiles!crm_leads_owner_id_fkey(full_name, email)";
  const fetchLeads = async () => {
    const currentSchema = await supabase
      .from("crm_leads")
      .select(leadFields)
      .order("updated_at", { ascending: false });
    if (!currentSchema.error) return currentSchema;
    if (!currentSchema.error.message.includes("visit_executor_id")) return currentSchema;
    return supabase
      .from("crm_leads")
      .select(leadFields.replace(", visit_executor_ids", ""))
      .order("updated_at", { ascending: false });
  };
  const [{ data, error }, matchesResult, linksResult] = await Promise.all([
    fetchLeads(),
    supabase
      .from("crm_property_match_notifications")
      .select(
        "lead_id, property_external_id, expires_at, offer_started_at, expired_at, dismissed_at, property:crm_property_catalog!crm_property_match_notifications_property_external_id_fkey(title)",
      ),
    supabase.from("crm_property_public_links").select("property_id, url"),
  ]);
  if (error) throw new Error(error.message);
  if (matchesResult.error) throw new Error(matchesResult.error.message);
  if (linksResult.error) throw new Error(linksResult.error.message);
  const rentalVisits = (data as LeadRecord[]).filter(
    (lead) =>
      lead.lead_type === "Aluguel" &&
      lead.visit_scheduled_at &&
      !(lead.visit_executor_ids?.length ?? 0),
  );
  if (rentalVisits.length) {
    const { data: agendaEntries, error: agendaError } = await supabase
      .from("crm_agenda_entries")
      .select(
        "source_lead_id, scheduled_at, target_user_id, requested_companion_ids, companion_approval_status, participants:crm_agenda_entry_participants(user_id)",
      )
      .eq("source_kind", "lead_visit")
      .in(
        "source_lead_id",
        rentalVisits.map((lead) => lead.id),
      );
    if (agendaError) throw new Error(agendaError.message);
    const executorsByVisit = new Map<string, string[]>(
      ((agendaEntries ?? []) as AgendaVisitRecord[]).map((entry) => {
        const approvedCompanionIds = new Set(
          entry.companion_approval_status === "approved"
            ? (entry.requested_companion_ids ?? [])
            : [],
        );
        const executorIds = [
          entry.target_user_id,
          ...(entry.participants ?? [])
            .map((participant) => participant.user_id)
            .filter((id) => !approvedCompanionIds.has(id)),
        ].filter((id): id is string => Boolean(id));
        return [`${entry.source_lead_id}:${entry.scheduled_at}`, [...new Set(executorIds)]];
      }),
    );
    for (const lead of rentalVisits) {
      const agendaExecutorIds = executorsByVisit.get(`${lead.id}:${lead.visit_scheduled_at}`);
      if (agendaExecutorIds?.length) lead.visit_executor_ids = agendaExecutorIds;
    }
  }
  const links = new Map((linksResult.data ?? []).map((item) => [item.property_id, item.url]));
  const matchesByLead = new Map<string, PropertyMatchOffer[]>();
  for (const item of matchesResult.data ?? []) {
    const current = matchesByLead.get(item.lead_id) ?? [];
    current.push({
      propertyId: item.property_external_id,
      title: (item.property as { title?: string } | null)?.title ?? item.property_external_id,
      url: links.get(item.property_external_id),
      expiresAt: item.expires_at,
      offerStartedAt: item.offer_started_at ?? undefined,
      expiredAt: item.expired_at ?? undefined,
      dismissedAt: item.dismissed_at ?? undefined,
    });
    matchesByLead.set(item.lead_id, current);
  }
  return (data as LeadRecord[]).map((record) => ({
    ...mapLead(record),
    propertyMatches: matchesByLead.get(record.id) ?? [],
  }));
}

export async function getBrokers() {
  const [{ data, error }, agendaProfilesResult] = await Promise.all([
    supabase.rpc("list_broker_profiles"),
    supabase.rpc("list_agenda_profiles"),
  ]);
  if (error && agendaProfilesResult.error) throw new Error(error.message);
  if (agendaProfilesResult.error && !(data?.length ?? 0)) {
    throw new Error(agendaProfilesResult.error.message);
  }
  const brokerProfiles = (data ?? []) as AgendaProfileRecord[];
  const agendaProfiles = (agendaProfilesResult.data ?? []) as AgendaProfileRecord[];
  const profilesById = new Map<string, AccessProfile>(
    [...brokerProfiles, ...agendaProfiles.filter((item) => item.role === "broker")].map(
      (profile) => [
        profile.id,
        {
          id: profile.id,
          fullName: profile.full_name || profile.email,
          email: profile.email,
          role: profile.role as CrmRole,
        },
      ],
    ),
  );
  // Allyson também pode ser selecionado como responsável ao cadastrar um lead,
  // embora seja o único usuário autorizado a efetuar esse cadastro.
  profilesById.set(ADMINISTRATOR_ADMIN_ID, {
    id: ADMINISTRATOR_ADMIN_ID,
    fullName: "crmallyson",
    email: "crmsoniaallyson@gmail.com",
    role: "admin",
  });
  const rosterOrder = ["crmdanilo", "crmnoemia", "crmsonia", "crmallyson"];
  return [...profilesById.values()].sort((left, right) => {
    const leftPosition = rosterOrder.indexOf(left.fullName.trim().toLowerCase());
    const rightPosition = rosterOrder.indexOf(right.fullName.trim().toLowerCase());
    if (leftPosition !== -1 || rightPosition !== -1) {
      return (leftPosition === -1 ? Number.MAX_SAFE_INTEGER : leftPosition) -
        (rightPosition === -1 ? Number.MAX_SAFE_INTEGER : rightPosition);
    }
    return left.fullName.localeCompare(right.fullName, "pt-BR");
  }) satisfies AccessProfile[];
}

export function useBrokerProfiles(enabled = true) {
  return useQuery({
    queryKey: ["crm-brokers"],
    queryFn: getBrokers,
    enabled,
    staleTime: 60_000,
  });
}

async function getAgendaProfiles() {
  const { data, error } = await supabase.rpc("list_agenda_profiles");
  if (error) throw new Error(error.message);
  const agendaProfiles = ((data ?? []) as AgendaProfileRecord[]).filter(
    (profile) => profile.id !== ADMINISTRATOR_ADMIN_ID,
  );
  agendaProfiles.push({
    id: ADMINISTRATOR_ADMIN_ID,
    full_name: "crmallyson",
    email: "crmsoniaallyson@gmail.com",
    role: "admin",
  });
  return agendaProfiles
    .map((profile) => {
      const normalizedEmail = profile.email.trim().toLowerCase();
      const isAdministrador = normalizedEmail === "crmsoniaallyson@gmail.com";
      const isSoniaLimaAgenda = normalizedEmail === "unassigned-institutional@example.invalid";
      return {
        id: profile.id,
        fullName: isSoniaLimaAgenda
          ? "Sônia Lima"
          : isAdministrador
            ? "crmallyson"
            : profile.full_name || profile.email,
        email: profile.email,
        role: profile.role as CrmRole,
      };
    })
    .sort((left, right) => {
      const leftIsAdministrador = left.email.trim().toLowerCase() === "crmsoniaallyson@gmail.com";
      const rightIsAdministrador = right.email.trim().toLowerCase() === "crmsoniaallyson@gmail.com";
      if (leftIsAdministrador !== rightIsAdministrador) return leftIsAdministrador ? 1 : -1;
      return left.fullName.localeCompare(right.fullName, "pt-BR");
    }) satisfies AccessProfile[];
}

export function useAgendaProfiles(enabled = true) {
  return useQuery({
    queryKey: ["crm-agenda-profiles"],
    queryFn: getAgendaProfiles,
    enabled,
    staleTime: 60_000,
  });
}

async function getLeadActivities() {
  const { data, error } = await supabase
    .from("crm_lead_activities")
    .select("id, lead_id, stage, note, author_name, created_at, scheduled_for")
    .order("created_at", { ascending: false });
  if (error) throw new Error(error.message);
  return (data as LeadActivityRecord[]).map((activity) => ({
    id: activity.id,
    leadId: activity.lead_id,
    stage: activity.stage,
    note: activity.note ?? undefined,
    authorName: activity.author_name || "Usuário removido",
    createdAt: activity.created_at,
    scheduledFor: activity.scheduled_for ?? undefined,
  })) satisfies LeadActivity[];
}

async function getLeadTimeline() {
  const pageSize = 1000;
  const rows: LeadTimelineEventRecord[] = [];
  for (let from = 0; ; from += pageSize) {
    const { data, error } = await supabase
      .from("crm_lead_timeline_events")
      .select(
        "id, lead_id, event_type, stage, note, actor_name, broker_name, occurred_at, scheduled_for, source_table, source_id",
      )
      .order("occurred_at", { ascending: false })
      .range(from, from + pageSize - 1);
    if (error) throw new Error(error.message);
    const page = (data ?? []) as LeadTimelineEventRecord[];
    rows.push(...page);
    if (page.length < pageSize) break;
  }
  return rows.map((event) => ({
    id: event.id,
    leadId: event.lead_id,
    eventType: event.event_type,
    stage: event.stage,
    note: event.note ?? undefined,
    authorName: event.actor_name || "Sistema",
    brokerName: event.broker_name ?? undefined,
    createdAt: event.occurred_at,
    scheduledFor: event.scheduled_for ?? undefined,
    sourceTable: event.source_table,
    sourceId: event.source_id,
  })) satisfies LeadTimelineEvent[];
}

export function useLeadAccess(userId?: string) {
  const queryClient = useQueryClient();
  const profile = useQuery({
    queryKey: ["access-profile", userId],
    queryFn: () => getProfile(userId!),
    enabled: Boolean(userId),
    staleTime: 60_000,
  });
  const leads = useQuery({
    queryKey: ["crm-leads", userId],
    queryFn: getLeads,
    enabled: Boolean(userId) && profile.isSuccess,
    refetchInterval: 5_000,
    refetchIntervalInBackground: true,
    refetchOnWindowFocus: "always",
  });
  useEffect(() => {
    if (!userId || !profile.isSuccess) return;

    let refreshTimer: ReturnType<typeof setTimeout> | undefined;
    const refreshLeads = () => {
      if (refreshTimer) clearTimeout(refreshTimer);
      refreshTimer = setTimeout(() => {
        void queryClient.invalidateQueries({ queryKey: ["crm-leads", userId] });
        void queryClient.invalidateQueries({ queryKey: ["crm-lead-activities", userId] });
        void queryClient.invalidateQueries({ queryKey: LEAD_DISTRIBUTION_QUERY_KEY });
      }, 150);
    };

    const channel = supabase
      .channel(`crm-leads-live:${userId}`)
      .on("postgres_changes", { event: "*", schema: "public", table: "crm_leads" }, refreshLeads)
      .subscribe();

    return () => {
      if (refreshTimer) clearTimeout(refreshTimer);
      void supabase.removeChannel(channel);
    };
  }, [profile.isSuccess, queryClient, userId]);
  const brokers = useBrokerProfiles(Boolean(userId) && profile.isSuccess);
  const activities = useQuery({
    queryKey: ["crm-lead-activities", userId],
    queryFn: getLeadActivities,
    enabled: Boolean(userId) && profile.isSuccess,
  });
  const timeline = useQuery({
    queryKey: ["crm-lead-timeline", userId],
    queryFn: getLeadTimeline,
    enabled: Boolean(userId) && profile.isSuccess,
    refetchInterval: 60_000,
  });
  const createLead = useMutation({
    mutationFn: async (input: CreateLeadInput) => {
      if (!userId) throw new Error("Sessão não encontrada.");
      const allysonCreator = isAdministradorAdmin(profile.data);
      const selectedOwner = input.ownerId
        ? brokers.data?.find((broker) => broker.id === input.ownerId)
        : undefined;
      const sonialimaQueueSelection =
        allysonCreator &&
        selectedOwner?.email?.trim().toLocaleLowerCase("pt-BR") === "unassigned-institutional@example.invalid";
      const vitorQueueCreator = isVitorProfile(profile.data) && input.distributeToQueue;
      const hasScheduledVisit = input.estagio === "Visita agendada";
      if (hasScheduledVisit && !input.visitScheduledAt) {
        throw new Error("Informe o dia e a hora da visita.");
      }
      if (hasScheduledVisit && input.tipoLead === "Aluguel" && !input.visitExecutorIds?.length) {
        throw new Error("Selecione ao menos um corretor para a visita de aluguel.");
      }
      const visitScheduledAt = hasScheduledVisit
        ? new Date(input.visitScheduledAt!).toISOString()
        : undefined;
      const baseCreationParams = {
        p_name: input.nome,
        p_phone: input.telefone ?? "",
        p_additional_phones: input.telefonesAdicionais ?? [],
        p_email: input.email ?? "",
        p_property_interest: input.imovel ?? "",
        p_channel: input.canal ?? "",
        p_notes: input.observacoes ?? "",
        p_lead_type: input.tipoLead,
        p_desired_property_value: input.valorDesejado,
        p_desired_location: input.localizacaoDesejada,
      };
      const creationRpc = hasScheduledVisit
        ? "create_scheduled_visit_lead_with_phones_and_executors"
        : allysonCreator && input.ownerId && !sonialimaQueueSelection
          ? "create_allyson_assigned_lead_with_phones"
          : vitorQueueCreator
            ? "create_vitor_distributed_lead_with_phones"
            : "create_lead_with_phones";
      const creationParams = hasScheduledVisit
        ? {
            ...baseCreationParams,
            p_visit_scheduled_at: visitScheduledAt,
            p_visit_executor_ids:
              input.tipoLead === "Aluguel" ? (input.visitExecutorIds ?? []) : [],
            p_owner_id:
              allysonCreator && input.ownerId && !sonialimaQueueSelection ? input.ownerId : null,
            p_use_vitor_queue: vitorQueueCreator,
          }
        : {
            ...baseCreationParams,
            p_stage: input.estagio,
            p_visit_scheduled_at: null,
            ...(creationRpc === "create_allyson_assigned_lead_with_phones"
              ? { p_owner_id: input.ownerId }
              : {}),
          };
      const { data: distributed, error: distributionError } = await supabase.rpc(
        creationRpc,
        creationParams,
      );

      if (distributionError) throw new Error(displayText(distributionError.message));
      const created = Array.isArray(distributed) ? distributed[0] : distributed;
      if (!created?.lead_id || !created.assigned_owner_name) {
        throw new Error(
          input.ownerId
            ? "Não foi possível atribuir o lead ao corretor selecionado."
            : "Não foi possível definir o corretor da fila.",
        );
      }
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["crm-leads", userId] });
      await queryClient.invalidateQueries({ queryKey: LEAD_DISTRIBUTION_QUERY_KEY });
      await queryClient.invalidateQueries({ queryKey: ["agenda"] });
    },
  });
  const assignLead = useMutation({
    mutationFn: async ({ leadId, ownerId }: { leadId: string; ownerId: string }) => {
      const lead = leads.data?.find((item) => item.id === leadId);
      if (!lead) throw new Error("Lead não encontrado. Atualize a lista e tente novamente.");
      const owner =
        ownerId === profile.data?.id
          ? profile.data
          : brokers.data?.find((broker) => broker.id === ownerId);
      if (!owner) throw new Error("Corretor responsável não encontrado.");

      if (!isAdministradorAdmin(profile.data)) {
        throw new Error("Somente crmallyson pode transferir um lead diretamente.");
      }
      const { error } = await supabase.rpc("transfer_lead_directly", {
        p_lead_id: leadId,
        p_owner_id: ownerId,
      });
      if (error) throw new Error(error.message);
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["crm-leads", userId] });
    },
  });
  const completeLeadRegistration = useMutation({
    mutationFn: async (input: CompleteLeadRegistrationInput) => {
      if (!userId) throw new Error("Sessão não encontrada.");
      if (!isAdministradorAdmin(profile.data)) {
        throw new Error("Somente crmallyson pode alterar os dados cadastrais do lead.");
      }
      const lead = leads.data?.find((item) => item.id === input.leadId);
      if (!lead) throw new Error("Lead não encontrado. Atualize a lista e tente novamente.");
      const name = input.nome.trim();
      const phone = input.telefone.trim();
      const email = input.email.trim().toLowerCase();
      const propertyInterest = input.imovel.trim();
      const desiredLocation = input.localizacaoDesejada.trim();
      const desiredPropertyValue = Number(input.valorDesejado);

      if (!name || !phone || !propertyInterest || !desiredLocation) {
        throw new Error("Preencha todos os campos obrigatórios do cadastro.");
      }
      if (email && !/^\S+@\S+\.\S+$/.test(email)) throw new Error("Informe um e-mail válido.");
      if (!Number.isFinite(desiredPropertyValue) || desiredPropertyValue <= 0) {
        throw new Error("Informe um valor desejado maior que zero.");
      }
      if (input.tipoLead !== "Venda" && input.tipoLead !== "Aluguel") {
        throw new Error("Selecione a finalidade do imóvel.");
      }

      const { data: updated, error } = await supabase
        .from("crm_leads")
        .update({
          name,
          secondary_name: input.segundoNome.trim() || null,
          phone,
          additional_phones: input.telefonesAdicionais,
          email: email || null,
          property_interest: propertyInterest,
          lead_type: input.tipoLead,
          desired_property_value: desiredPropertyValue,
          desired_location: desiredLocation,
          channel: input.canal.trim() || null,
          notes: input.observacoes.trim() || null,
        })
        .eq("id", input.leadId)
        .select("id")
        .maybeSingle();
      if (error) throw new Error(error.message);
      if (!updated) throw new Error("Você não tem permissão para atualizar este lead.");
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["crm-leads", userId] });
    },
  });
  const deleteLead = useMutation({
    mutationFn: async (leadId: string) => {
      if (profile.data?.role !== "admin") {
        throw new Error("Somente crmallyson pode excluir leads.");
      }
      const lead = leads.data?.find((item) => item.id === leadId);
      if (!lead) throw new Error("Lead não encontrado. Atualize a lista e tente novamente.");

      const { error } = await supabase.rpc("delete_crm_lead", { p_lead_id: leadId });
      if (error) throw new Error(error.message);
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["crm-leads", userId] });
      await queryClient.invalidateQueries({ queryKey: ["crm-lead-activities", userId] });
      await queryClient.invalidateQueries({ queryKey: LEAD_DISTRIBUTION_QUERY_KEY });
    },
  });
  const updateLeadProgress = useMutation({
    mutationFn: async ({
      leadId,
      stage,
      visitScheduledAt,
      companionUserId,
      visitExecutorIds,
      note,
      qualification,
    }: {
      leadId: string;
      stage: LeadProgressStage;
      visitScheduledAt?: string;
      companionUserId?: string;
      visitExecutorIds?: string[];
      note?: string;
      qualification?: LeadQualificationInput;
    }) => {
      const lead = leads.data?.find((item) => item.id === leadId);
      if (!lead) throw new Error("Lead não encontrado. Atualize a lista e tente novamente.");
      const qualificationPending =
        Boolean(lead.postAcceptanceQualificationDeadlineAt) &&
        !lead.postAcceptanceQualificationCompletedAt &&
        !lead.postAcceptanceQualificationExpiredAt;
      if (qualificationPending && stage !== lead.estagio) {
        throw new Error("Conclua a qualificação obrigatória antes de alterar a etapa do lead.");
      }
      const hasNewVisitSchedule = stage === "Visita agendada" && Boolean(visitScheduledAt);
      const isVisitReschedule =
        hasNewVisitSchedule && lead.estagio === "Visita agendada" && Boolean(lead.visitaAgendadaEm);
      const acceptingAssignment =
        stage === "Em atendimento" &&
        lead.assignmentStatus === "pending" &&
        lead.ownerId === userId;
      if (acceptingAssignment) {
        const { error: acceptanceError } = await supabase.rpc("accept_lead_assignment", {
          p_lead_id: leadId,
        });
        if (acceptanceError) {
          await queryClient.invalidateQueries({ queryKey: ["crm-leads", userId] });
          if (/n[aã]o est[aá] mais dispon[ií]vel para aceite/i.test(acceptanceError.message)) {
            throw new Error(
              "O prazo de aceite encerrou ou o lead foi redistribuído. A lista foi atualizada.",
            );
          }
          throw new Error(acceptanceError.message);
        }
        await queryClient.invalidateQueries({ queryKey: ["crm-leads", userId] });
        if (
          profile.data?.email.trim().toLocaleLowerCase("pt-BR") === "unassigned-institutional@example.invalid"
        ) {
          return;
        }
      }
      const now = new Date().toISOString();
      const qualificationNotes: string[] = [];
      if (qualification?.hasPropertyToSell !== undefined) {
        qualificationNotes.push(
          qualification.hasPropertyToSell
            ? `Possui imóvel para venda: Sim${qualification.propertyToSellLocation ? ` · Localização: ${qualification.propertyToSellLocation}` : ""}${qualification.propertyToSellValue ? ` · Valor: ${qualification.propertyToSellValue.toLocaleString("pt-BR", { style: "currency", currency: "BRL" })}` : ""}.`
            : "Possui imóvel para venda: Não.",
        );
      }
      if (qualification?.needsFinancing !== undefined) {
        qualificationNotes.push(
          `Necessita de financiamento: ${qualification.needsFinancing ? "Sim" : "Não"}.`,
        );
      }
      if (qualification?.willUseFgts !== undefined) {
        qualificationNotes.push(
          `Pretende utilizar FGTS: ${qualification.willUseFgts ? "Sim" : "Não"}.`,
        );
      }
      if (qualification?.bankingCorrespondentPresented !== undefined) {
        qualificationNotes.push(
          `Empresa apresentada como correspondente bancária: ${qualification.bankingCorrespondentPresented ? "Sim" : "Não"}.`,
        );
      }
      if (qualification?.visitPropertyCaptured !== undefined) {
        qualificationNotes.push(
          `Imóvel do cliente captado durante a visita: ${qualification.visitPropertyCaptured ? "Sim" : "Não"}.`,
        );
      }
      const activityNote = [note?.trim(), ...qualificationNotes].filter(Boolean).join("\n");
      const fullLeadUpdate = {
        stage,
        ...(stage !== "Em atendimento" ? { assignment_deadline_at: null } : {}),
        visit_scheduled_at: hasNewVisitSchedule
          ? new Date(visitScheduledAt!).toISOString()
          : (lead.visitaAgendadaEm ?? null),
        visit_executor_id:
          hasNewVisitSchedule && lead.tipoLead === "Aluguel"
            ? (visitExecutorIds?.[0] ?? null)
            : null,
        visit_executor_ids:
          hasNewVisitSchedule && lead.tipoLead === "Aluguel" ? (visitExecutorIds ?? []) : [],
        ...(hasNewVisitSchedule
          ? {
              visit_feedback_at: null,
              visit_started_notified_at: null,
              visit_follow_up_notified_at: null,
              visit_feedback_reminder_sent_at: null,
            }
          : {}),
        visit_completed_at:
          stage === "Visita realizada"
            ? (lead.visitaRealizadaEm ?? now)
            : (lead.visitaRealizadaEm ?? null),
        proposal_at: stage === "Proposta" ? (lead.propostaEm ?? now) : (lead.propostaEm ?? null),
        ...(qualification
          ? {
              ...(qualification.hasPropertyToSell !== undefined
                ? {
                    has_property_to_sell: qualification.hasPropertyToSell,
                    property_to_sell_location: qualification.hasPropertyToSell
                      ? qualification.propertyToSellLocation?.trim() || null
                      : null,
                    property_to_sell_value: qualification.hasPropertyToSell
                      ? qualification.propertyToSellValue
                      : null,
                  }
                : {}),
              ...(qualification.needsFinancing !== undefined
                ? { needs_financing: qualification.needsFinancing }
                : {}),
              ...(qualification.willUseFgts !== undefined
                ? { will_use_fgts: qualification.willUseFgts }
                : {}),
              ...(qualification.bankingCorrespondentPresented !== undefined
                ? {
                    banking_correspondent_presented: qualification.bankingCorrespondentPresented,
                  }
                : {}),
              ...(qualification.visitPropertyCaptured !== undefined
                ? { visit_property_captured: qualification.visitPropertyCaptured }
                : {}),
            }
          : {}),
      };
      // No fluxo simplificado, o corretor só persiste a etapa. Os demais dados
      // continuam sob gestão exclusiva do Administrador.
      const leadUpdate = isAdministradorAdmin(profile.data) ? fullLeadUpdate : { stage };
      let usedLegacyVisitExecutorSchema = false;
      let error: { message: string } | null = null;
      if (isVisitReschedule) {
        const result = await supabase.rpc("reschedule_lead_visit", {
          p_lead_id: leadId,
          p_scheduled_at: new Date(visitScheduledAt!).toISOString(),
          p_visit_executor_ids: lead.tipoLead === "Aluguel" ? (visitExecutorIds ?? []) : null,
        });
        error = result.error;
      } else {
        const result = await supabase.from("crm_leads").update(leadUpdate).eq("id", leadId);
        error = result.error;
        if (error?.message.includes("visit_executor_ids")) {
          usedLegacyVisitExecutorSchema = true;
          const { visit_executor_ids: _unsupported, ...legacyLeadUpdate } = leadUpdate;
          const fallback = await supabase
            .from("crm_leads")
            .update(legacyLeadUpdate)
            .eq("id", leadId);
          error = fallback.error;
        }
      }
      if (error) throw new Error(error.message);
      if (!acceptingAssignment) {
        const { error: activityError } = await supabase.from("crm_lead_activities").insert({
          lead_id: leadId,
          stage: stage === "Visita agendada" && lead.visitaAgendadaEm ? "Visita reagendada" : stage,
          note: activityNote || null,
          scheduled_for: hasNewVisitSchedule ? new Date(visitScheduledAt!).toISOString() : null,
          author_id: userId,
          author_name: profile.data?.fullName || profile.data?.email || "Usuário",
        });
        if (activityError) throw new Error(activityError.message);
      }
      if (hasNewVisitSchedule && lead.tipoLead !== "Aluguel" && companionUserId) {
        const scheduledAt = new Date(visitScheduledAt!).toISOString();
        const { data: agendaEntry, error: agendaError } = await supabase
          .from("crm_agenda_entries")
          .select("id")
          .eq("source_kind", "lead_visit")
          .eq("source_lead_id", leadId)
          .eq("scheduled_at", scheduledAt)
          .single();
        if (agendaError) throw new Error(agendaError.message);
        const { error: companionError } = await supabase.rpc("request_agenda_companion_approval", {
          p_entry_id: agendaEntry.id,
          p_companion_user_ids: [companionUserId],
          p_reason: "Acompanhamento solicitado pelo corretor responsável para a visita do lead.",
        });
        if (companionError) throw new Error(companionError.message);
      }
      if (usedLegacyVisitExecutorSchema && hasNewVisitSchedule && lead.tipoLead === "Aluguel") {
        const scheduledAt = new Date(visitScheduledAt!).toISOString();
        const { data: agendaEntry, error: agendaError } = await supabase
          .from("crm_agenda_entries")
          .select("id")
          .eq("source_kind", "lead_visit")
          .eq("source_lead_id", leadId)
          .eq("scheduled_at", scheduledAt)
          .single();
        if (agendaError) throw new Error(agendaError.message);
        const { error: participantsError } = await supabase.rpc("set_agenda_companions", {
          p_entry_id: agendaEntry.id,
          p_companion_user_ids: (visitExecutorIds ?? []).slice(1),
        });
        if (participantsError) throw new Error(participantsError.message);
      }
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["crm-leads", userId] });
      await queryClient.invalidateQueries({ queryKey: ["crm-lead-activities", userId] });
      await queryClient.invalidateQueries({ queryKey: ["agenda"] });
    },
  });
  const extendAttendance = useMutation({
    mutationFn: async ({ leadId, note }: { leadId: string; note: string }) => {
      const lead = leads.data?.find((item) => item.id === leadId);
      if (!lead) throw new Error("Lead não encontrado. Atualize a lista e tente novamente.");
      if (!note.trim()) throw new Error("Informe o motivo para manter o lead em atendimento.");
      const { error } = await supabase.rpc("extend_lead_attendance", {
        p_lead_id: leadId,
        p_note: note.trim(),
      });
      if (error) throw new Error(error.message);
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["crm-leads", userId] });
      await queryClient.invalidateQueries({ queryKey: ["crm-lead-activities", userId] });
    },
  });
  const addLeadObservation = useMutation({
    mutationFn: async ({ leadId, note }: { leadId: string; note: string }) => {
      if (!note.trim()) throw new Error("Informe a observa\u00e7\u00e3o.");
      const { error } = await supabase.rpc("add_administrative_lead_observation", {
        p_lead_id: leadId,
        p_note: note.trim(),
      });
      if (error) throw new Error(error.message);
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["crm-lead-activities", userId] });
    },
  });
  const editLeadObservation = useMutation({
    mutationFn: async ({ activityId, note }: { activityId: string; note: string }) => {
      if (!note.trim()) throw new Error("Informe a observação.");
      const { error } = await supabase.rpc("edit_administrative_lead_observation", {
        p_activity_id: activityId,
        p_note: note.trim(),
      });
      if (error) throw new Error(error.message);
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["crm-lead-activities", userId] });
    },
  });
  const deleteLeadObservation = useMutation({
    mutationFn: async (activityId: string) => {
      const { error } = await supabase.rpc("delete_administrative_lead_observation", {
        p_activity_id: activityId,
      });
      if (error) throw new Error(error.message);
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["crm-lead-activities", userId] });
    },
  });
  const restartExhaustedLead = useMutation({
    mutationFn: async (leadId: string) => {
      if (!isAdministradorAdmin(profile.data))
        throw new Error("Somente crmallyson pode reiniciar a fila.");
      const { data, error } = await supabase.rpc("restart_exhausted_lead_queue", {
        p_lead_id: leadId,
      });
      if (error) throw new Error(error.message);
      return data as string;
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["crm-leads", userId] });
      await queryClient.invalidateQueries({ queryKey: ["crm-lead-activities", userId] });
      await queryClient.invalidateQueries({ queryKey: LEAD_DISTRIBUTION_QUERY_KEY });
    },
  });
  const startSimilarPropertyOffer = useMutation({
    mutationFn: async ({ leadId, propertyId }: { leadId: string; propertyId: string }) => {
      const { error } = await supabase.rpc("start_similar_property_offer", {
        p_lead_id: leadId,
        p_property_id: propertyId,
      });
      if (error) throw new Error(error.message);
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["crm-leads", userId] });
      await queryClient.invalidateQueries({ queryKey: ["crm-lead-activities", userId] });
    },
  });
  const dismissSimilarPropertyMatches = useMutation({
    mutationFn: async (leadId: string) => {
      const { error } = await supabase.rpc("dismiss_similar_property_matches", {
        p_lead_id: leadId,
      });
      if (error) throw new Error(error.message);
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["crm-leads", userId] });
      await queryClient.invalidateQueries({ queryKey: ["crm-lead-activities", userId] });
    },
  });
  return {
    profile: profile.data,
    leads: leads.data ?? [],
    brokers: brokers.data ?? [],
    activities: activities.data ?? [],
    timelineEvents: timeline.data ?? [],
    loading: profile.isLoading || leads.isLoading || activities.isLoading || timeline.isLoading,
    error: profile.error ?? leads.error ?? brokers.error ?? activities.error ?? timeline.error,
    refetch: async () => {
      await Promise.all([
        profile.refetch(),
        leads.refetch(),
        brokers.refetch(),
        timeline.refetch(),
      ]);
    },
    createLead: createLead.mutateAsync,
    creating: createLead.isPending,
    createError: createLead.error ? message(createLead.error) : null,
    assignLead: assignLead.mutateAsync,
    assigning: assignLead.isPending,
    completeLeadRegistration: completeLeadRegistration.mutateAsync,
    completingLeadRegistration: completeLeadRegistration.isPending,
    deleteLead: deleteLead.mutateAsync,
    deleting: deleteLead.isPending,
    updateLeadProgress: updateLeadProgress.mutateAsync,
    updatingProgress: updateLeadProgress.isPending,
    extendAttendance: extendAttendance.mutateAsync,
    extendingAttendance: extendAttendance.isPending,
    addLeadObservation: addLeadObservation.mutateAsync,
    addingLeadObservation: addLeadObservation.isPending,
    editLeadObservation: editLeadObservation.mutateAsync,
    editingLeadObservation: editLeadObservation.isPending,
    deleteLeadObservation: deleteLeadObservation.mutateAsync,
    deletingLeadObservation: deleteLeadObservation.isPending,
    restartExhaustedLead: restartExhaustedLead.mutateAsync,
    restartingExhaustedLead: restartExhaustedLead.isPending,
    startSimilarPropertyOffer: startSimilarPropertyOffer.mutateAsync,
    startingSimilarPropertyOffer: startSimilarPropertyOffer.isPending,
    dismissSimilarPropertyMatches: dismissSimilarPropertyMatches.mutateAsync,
    dismissingSimilarPropertyMatches: dismissSimilarPropertyMatches.isPending,
  };
}

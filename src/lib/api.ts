import { useEffect, useId } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { canonicalLeadOrigin } from "@/lib/lead-origin";
import { supabase } from "@/lib/supabase";
import { useAuth } from "@/components/auth/AuthProvider";

// ============================================================
// Contrato JSON esperado do Google Apps Script (doGet)
// ============================================================
export type KpiKey =
  | "leads"
  | "atendimentos"
  | "standby"
  | "visitas"
  | "propostas"
  | "vendas"
  | "locacoes"
  | "comissao"
  | "faturamento"
  | "cac"
  | "roi"
  | "ticketMedio"
  | "tempoMedio"
  | "conversao";

export type KpiEntry = { value: number; delta: number };

export type RevenuePoint = { m: string; vendas: number; locacoes: number };
export type ConversionPoint = { m: string; conv: number };
export type ChannelPoint = { c: string; v: number };
export type PortfolioPoint = { name: string; v: number };
export type FunnelPoint = { stage: string; v: number };

export type RankingRow = {
  id?: string;
  nome: string;
  faturamento: number;
  vendas: number;
  tier?: string;
};

export type LeadRow = {
  id?: string;
  nome: string;
  imovel?: string;
  estagio: string;
  canal?: string;
  tipoInteresse?: string;
  valor: number;
  comissaoImb?: number;
  corretor?: string;
  atualizadoEm?: string;
};

export type PropertyRow = {
  id?: string;
  codigoWImoveis?: string;
  codigoDfImoveis?: string;
  titulo: string;
  endereco?: string;
  bairro?: string;
  cidade?: string;
  tipo?: string;
  quartos?: number | null;
  finalidade?: string;
  valor?: number;
  corretor?: string;
  proprietario?: string;
  status?: string;
  cadastradoEm?: string;
  fotos?: string | string[];
  registrationPhase?: string;
  publicModalidade?: string;
  sonialimaExclusivityControl?: string;
  captureRankingEnabled?: boolean;
};

export type MarketingRow = {
  id?: string;
  atualizadoEm?: string;
  criadoEm?: string;
  data?: string;
  campanha: string;
  canal?: string;
  objetivo?: string;
  status?: string;
  valorInvestido: number;
  leadsGerados: number;
  visitasGeradas: number;
  negociosFechados: number;
  receitaGerada: number;
  responsavel?: string;
  observacoes?: string;
};

export type DashboardData = {
  updatedAt?: string;
  kpis: Partial<Record<KpiKey, KpiEntry>>;
  receita: RevenuePoint[];
  conversao: ConversionPoint[];
  canais: ChannelPoint[];
  portfolio: PortfolioPoint[];
  funil: FunnelPoint[];
  ranking: RankingRow[];
  imoveis: PropertyRow[];
  leads: LeadRow[];
  marketing: MarketingRow[];
};

type SpreadsheetRecord = Record<string, unknown>;
type SpreadsheetDashboard = { dados?: Record<string, SpreadsheetRecord[]> };

function field(record: SpreadsheetRecord, ...headers: string[]) {
  for (const header of headers) {
    const value = record[header];
    if (value !== undefined && value !== null) return value;
  }
  return undefined;
}

function text(record: SpreadsheetRecord, ...headers: string[]) {
  const value = field(record, ...headers);
  return value === undefined || value === null ? "" : String(value);
}

function number(record: SpreadsheetRecord, ...headers: string[]) {
  const value = field(record, ...headers);
  if (typeof value === "number") return value;
  return (
    Number(
      String(value ?? "")
        .replace(/[^0-9,.-]/g, "")
        .replace(/\./g, "")
        .replace(",", "."),
    ) || 0
  );
}

function countBy(records: SpreadsheetRecord[], header: string) {
  return records.reduce<Record<string, number>>((counts, record) => {
    const value = text(record, header).trim() || "Não informado";
    counts[value] = (counts[value] ?? 0) + 1;
    return counts;
  }, {});
}

function isRental(record: SpreadsheetRecord) {
  const interest = text(record, "Tipo de interesse");
  return interest === "Locação" || interest === "Aluguel de imóvel";
}

function commissionValue(record: SpreadsheetRecord) {
  return number(record, "Comissão");
}

function recordDate(record: SpreadsheetRecord, ...headers: string[]) {
  const value = text(record, ...headers).trim();
  if (!value) return undefined;
  const direct = new Date(value);
  if (!Number.isNaN(direct.getTime())) return direct;
  const brazilian = value.match(/^(\d{2})\/(\d{2})\/(\d{4})/);
  if (!brazilian) return undefined;
  return new Date(Number(brazilian[3]), Number(brazilian[2]) - 1, Number(brazilian[1]));
}

function percentChange(current: number, previous: number) {
  if (previous === 0) return current === 0 ? 0 : 100;
  return ((current - previous) / Math.abs(previous)) * 100;
}

function fromSpreadsheetDashboard(payload: SpreadsheetDashboard): DashboardData {
  const source = payload.dados ?? {};
  const leadRecords = source.leads ?? [];
  const propertyRecords = source.imoveis ?? [];
  const marketingRecords = source.marketing ?? [];
  const statuses = countBy(leadRecords, "Status");
  const channels = countBy(leadRecords, "Canal de origem");
  const portfolio = countBy(propertyRecords, "Tipo");
  const closedDeals = leadRecords.filter((record) => text(record, "Status") === "Fechado");
  const sales = closedDeals.filter((record) => !isRental(record));
  const rentals = closedDeals.filter(isRental);
  const salesValue = sales.reduce((sum, record) => sum + commissionValue(record), 0);
  const closedRevenue = closedDeals.reduce((sum, record) => sum + commissionValue(record), 0);
  const now = new Date();
  const currentMonthStart = new Date(now.getFullYear(), now.getMonth(), 1);
  const previousMonthStart = new Date(now.getFullYear(), now.getMonth() - 1, 1);
  const monthlyValue = (
    records: SpreadsheetRecord[],
    predicate: (record: SpreadsheetRecord) => boolean,
    value: (record: SpreadsheetRecord) => number = () => 1,
    dateHeaders: string[] = ["Data de entrada", "Data"],
  ) => {
    const values = { current: 0, previous: 0 };
    for (const record of records) {
      if (!predicate(record)) continue;
      const date = recordDate(record, ...dateHeaders);
      if (!date || Number.isNaN(date.getTime())) continue;
      if (date >= currentMonthStart) values.current += value(record);
      else if (date >= previousMonthStart && date < currentMonthStart)
        values.previous += value(record);
    }
    return values;
  };
  const deltaFor = (
    records: SpreadsheetRecord[],
    predicate: (record: SpreadsheetRecord) => boolean,
    value?: (record: SpreadsheetRecord) => number,
    dateHeaders?: string[],
  ) => {
    const months = monthlyValue(records, predicate, value, dateHeaders);
    return percentChange(months.current, months.previous);
  };
  const brokerTotals = leadRecords.reduce<Record<string, { vendas: number; faturamento: number }>>(
    (totals, record) => {
      const nome = text(record, "Corretor responsável").trim();
      if (!nome) return totals;
      const current = totals[nome] ?? { vendas: 0, faturamento: 0 };
      const status = text(record, "Status");
      if (status === "Fechado") {
        current.vendas += 1;
        current.faturamento += commissionValue(record);
      }
      totals[nome] = current;
      return totals;
    },
    {},
  );
  const leads = leadRecords.map((record) => ({
    id: text(record, "_id"),
    nome: text(record, "Nome"),
    imovel: text(record, "Imóvel de interesse"),
    estagio: text(record, "Status"),
    canal: canonicalLeadOrigin(text(record, "Canal de origem")),
    tipoInteresse: text(record, "Tipo de interesse"),
    valor: number(record, "Faixa de orçamento"),
    comissaoImb: commissionValue(record),
    corretor: text(record, "Corretor responsável"),
    atualizadoEm: text(record, "Data de entrada", "Data do 1º contato"),
  }));
  const imoveis = propertyRecords.map((record) => ({
    id: text(record, "_id"),
    codigoWImoveis: text(record, "Código W Imóveis"),
    codigoDfImoveis: text(record, "Código DF Imóveis"),
    titulo: text(record, "Endereço/identificação"),
    endereco: text(record, "Endereço/identificação"),
    bairro: text(record, "Bairro"),
    cidade: text(record, "Cidade"),
    tipo: text(record, "Tipo"),
    quartos:
      text(record, "Número de quartos").trim() === "" ? null : number(record, "Número de quartos"),
    finalidade: text(record, "Finalidade"),
    valor: number(record, "Valor de venda"),
    corretor: text(record, "Corretor responsável"),
    proprietario: text(record, "Proprietário"),
    status: text(record, "Status"),
    cadastradoEm: text(record, "Data de entrada"),
    fotos: text(record, "Possui fotos?"),
    registrationPhase: text(record, "Registration Phase"),
    publicModalidade: text(record, "Public Modalidade"),
    sonialimaExclusivityControl: text(record, "SoniaLima Exclusivity Control"),
    captureRankingEnabled: ["true", "1", "sim"].includes(
      text(record, "Capture Ranking Enabled").trim().toLocaleLowerCase("pt-BR"),
    ),
  }));
  const marketing = marketingRecords.map((record) => ({
    id: text(record, "_id"),
    data: text(record, "Data"),
    campanha: text(record, "Campanha"),
    canal: text(record, "Canal"),
    objetivo: text(record, "Objetivo"),
    status: text(record, "Status"),
    valorInvestido: number(record, "Valor investido"),
    leadsGerados: number(record, "Leads gerados"),
    visitasGeradas: number(record, "Visitas geradas"),
    negociosFechados: number(record, "Negócios fechados"),
    receitaGerada: number(record, "Receita gerada"),
    responsavel: text(record, "Responsável"),
    observacoes: text(record, "Observações"),
  }));
  const marketingTotals = marketing.reduce(
    (totals, campaign) => ({
      invested: totals.invested + campaign.valorInvestido,
      deals: totals.deals + campaign.negociosFechados,
      revenue: totals.revenue + campaign.receitaGerada,
    }),
    { invested: 0, deals: 0, revenue: 0 },
  );
  const leadConversion = leadRecords.reduce<
    Record<string, { date: number; total: number; closed: number }>
  >((months, record) => {
    const dateValue = text(record, "Data de entrada");
    const parsed = dateValue ? new Date(dateValue) : null;
    const validDate = parsed && !Number.isNaN(parsed.getTime());
    const key = validDate
      ? `${parsed.getFullYear()}-${String(parsed.getMonth() + 1).padStart(2, "0")}`
      : "Sem data";
    const current = months[key] ?? {
      date: validDate ? parsed.getTime() : Number.MAX_SAFE_INTEGER,
      total: 0,
      closed: 0,
    };
    current.total += 1;
    if (text(record, "Status") === "Fechado") current.closed += 1;
    months[key] = current;
    return months;
  }, {});
  const conversion = Object.entries(leadConversion)
    .sort(([, left], [, right]) => left.date - right.date)
    .map(([month, values]) => ({
      m:
        month === "Sem data"
          ? month
          : new Date(`${month}-01T12:00:00`).toLocaleDateString("pt-BR", {
              month: "short",
              year: "2-digit",
            }),
      conv: values.total ? (values.closed / values.total) * 100 : 0,
    }));
  const revenueByMonth = closedDeals.reduce<
    Record<string, { date: number; vendas: number; locacoes: number }>
  >((months, record) => {
    const dateValue = text(record, "Data de entrada");
    const parsed = dateValue ? new Date(dateValue) : null;
    const validDate = parsed && !Number.isNaN(parsed.getTime());
    const key = validDate
      ? `${parsed.getFullYear()}-${String(parsed.getMonth() + 1).padStart(2, "0")}`
      : "Sem data";
    const current = months[key] ?? {
      date: validDate ? parsed.getTime() : Number.MAX_SAFE_INTEGER,
      vendas: 0,
      locacoes: 0,
    };
    const value = commissionValue(record);
    if (isRental(record)) current.locacoes += value;
    else current.vendas += value;
    months[key] = current;
    return months;
  }, {});
  const currentYear = new Date().getFullYear();
  const receita = Array.from({ length: 12 }, (_, index) => {
    const month = index + 1;
    const key = `${currentYear}-${String(month).padStart(2, "0")}`;
    const values = revenueByMonth[key] ?? { vendas: 0, locacoes: 0 };
    return {
      m: new Date(currentYear, index, 1).toLocaleDateString("pt-BR", { month: "short" }),
      vendas: values.vendas,
      locacoes: values.locacoes,
    };
  });
  const cac = closedDeals.length ? marketingTotals.invested / closedDeals.length : 0;
  const roi = marketingTotals.invested
    ? ((closedRevenue - marketingTotals.invested) / marketingTotals.invested) * 100
    : 0;
  const monthlyClosed = monthlyValue(leadRecords, (record) => text(record, "Status") === "Fechado");
  const monthlyRevenue = monthlyValue(
    leadRecords,
    (record) => text(record, "Status") === "Fechado",
    commissionValue,
  );
  const monthlyInvestment = monthlyValue(
    marketingRecords,
    () => true,
    (record) => number(record, "Valor investido"),
    ["Data"],
  );
  const currentCac = monthlyClosed.current ? monthlyInvestment.current / monthlyClosed.current : 0;
  const previousCac = monthlyClosed.previous
    ? monthlyInvestment.previous / monthlyClosed.previous
    : 0;
  const currentRoi = monthlyInvestment.current
    ? ((monthlyRevenue.current - monthlyInvestment.current) / monthlyInvestment.current) * 100
    : 0;
  const previousRoi = monthlyInvestment.previous
    ? ((monthlyRevenue.previous - monthlyInvestment.previous) / monthlyInvestment.previous) * 100
    : 0;
  return {
    kpis: {
      leads: { value: leads.length, delta: deltaFor(leadRecords, () => true) },
      atendimentos: {
        value: statuses["Em atendimento"] ?? 0,
        delta: deltaFor(leadRecords, (record) => text(record, "Status") === "Em atendimento"),
      },
      visitas: {
        value: statuses["Visita agendada"] ?? 0,
        delta: deltaFor(leadRecords, (record) => text(record, "Status") === "Visita agendada"),
      },
      propostas: {
        value: (statuses.Proposta ?? 0) + (statuses["Em negociação"] ?? 0),
        delta: deltaFor(leadRecords, (record) =>
          ["Proposta", "Em negociação"].includes(text(record, "Status")),
        ),
      },
      vendas: {
        value: sales.length,
        delta: deltaFor(
          leadRecords,
          (record) => text(record, "Status") === "Fechado" && !isRental(record),
        ),
      },
      locacoes: {
        value: rentals.length,
        delta: deltaFor(
          leadRecords,
          (record) => text(record, "Status") === "Fechado" && isRental(record),
        ),
      },
      // Na planilha, "Comissão" (coluna J) é o faturamento efetivo da imobiliária.
      comissao: {
        value: closedRevenue,
        delta: percentChange(monthlyRevenue.current, monthlyRevenue.previous),
      },
      faturamento: {
        value: closedRevenue,
        delta: percentChange(monthlyRevenue.current, monthlyRevenue.previous),
      },
      cac: { value: cac, delta: percentChange(currentCac, previousCac) },
      roi: { value: roi, delta: percentChange(currentRoi, previousRoi) },
      ticketMedio: {
        value: closedDeals.length ? closedRevenue / closedDeals.length : 0,
        delta: percentChange(
          monthlyClosed.current ? monthlyRevenue.current / monthlyClosed.current : 0,
          monthlyClosed.previous ? monthlyRevenue.previous / monthlyClosed.previous : 0,
        ),
      },
      tempoMedio: { value: 0, delta: 0 },
      conversao: {
        value: leads.length ? ((statuses.Fechado ?? 0) / leads.length) * 100 : 0,
        delta: 0,
      },
    },
    receita,
    conversao: conversion,
    canais: Object.entries(channels).map(([c, v]) => ({ c, v })),
    portfolio: Object.entries(portfolio).map(([name, v]) => ({ name, v })),
    funil: Object.entries(statuses).map(([stage, v]) => ({ stage, v })),
    ranking: Object.entries(brokerTotals)
      .map(([nome, totals]) => ({ id: nome, nome, ...totals }))
      .sort((left, right) => right.faturamento - left.faturamento),
    imoveis,
    leads,
    marketing,
  };
}

// ============================================================
// Fetch
// ============================================================
async function fetchDashboard(): Promise<DashboardData> {
  const [leadsResult, propertiesResult, marketingResult, profilesResult] = await Promise.all([
    supabase.from("crm_leads").select("*"),
    // Keep the portfolio in its original registration order. PostgreSQL does
    // not guarantee row order without ORDER BY and an UPDATE can otherwise
    // make a property jump to another position in the list.
    supabase
      .from("crm_property_catalog")
      .select("*")
      .order("created_at", { ascending: true })
      .order("external_id", { ascending: true }),
    supabase
      .from("crm_marketing_campaigns")
      .select("*")
      .order("campaign_date", { ascending: false }),
    supabase.from("profiles").select("id,full_name"),
  ]);
  const failure = [
    leadsResult.error,
    propertiesResult.error,
    marketingResult.error,
    profilesResult.error,
  ].find(Boolean);
  if (failure) throw new Error(failure.message);

  const names = new Map(
    (profilesResult.data ?? []).map((profile) => [profile.id, profile.full_name]),
  );
  const leads: SpreadsheetRecord[] = (leadsResult.data ?? []).map((lead) => ({
    _id: lead.external_id || lead.id,
    Nome: lead.name,
    Telefone: lead.phone,
    Email: lead.email,
    "Imóvel de interesse": lead.property_interest,
    Status: lead.stage,
    "Canal de origem": lead.channel,
    "Faixa de orçamento": lead.budget || lead.desired_property_value,
    Comissão: lead.commission,
    "Corretor responsável": names.get(lead.owner_id) || "",
    "Tipo de interesse": lead.lead_type === "Aluguel" ? "Aluguel de imóvel" : "Compra",
    "Data de entrada": lead.created_at,
    Observações: lead.notes,
  }));
  const imoveis: SpreadsheetRecord[] = (propertiesResult.data ?? []).map((property) => ({
    _id: property.external_id,
    "Código W Imóveis": property.wimoveis_code,
    "Código DF Imóveis": property.dfimoveis_code,
    "Endereço/identificação": property.title || property.address,
    Bairro: property.neighborhood,
    Cidade: property.city,
    Tipo: property.property_type,
    "Número de quartos": property.bedrooms,
    Finalidade: property.purpose,
    "Valor de venda": property.value,
    "Valor de locação": property.rental_value,
    "Corretor responsável": property.brokers,
    Proprietário: property.owner_name,
    Status: property.status,
    "Possui fotos?": property.has_photos ? "Sim" : "Não",
    "Data de entrada": property.entered_at || property.created_at,
    "Registration Phase": property.registration_phase,
    "Public Modalidade": property.public_modalidade,
    "SoniaLima Exclusivity Control": property.sonialima_exclusivity_control,
    "Capture Ranking Enabled": property.capture_ranking_enabled,
  }));
  const marketing: SpreadsheetRecord[] = (marketingResult.data ?? []).map((campaign) => ({
    _id: campaign.id,
    Data: campaign.campaign_date,
    Campanha: campaign.name,
    Canal: campaign.channel,
    Objetivo: campaign.objective,
    Status: campaign.status,
    "Valor investido": campaign.invested,
    "Leads gerados": campaign.leads_generated,
    "Visitas geradas": campaign.visits_generated,
    "Negócios fechados": campaign.deals_closed,
    "Receita gerada": campaign.revenue,
    Responsável: campaign.responsible,
    Observações: campaign.notes,
  }));
  return {
    ...fromSpreadsheetDashboard({ dados: { leads, imoveis, marketing } }),
    updatedAt: new Date().toISOString(),
  };
}

// ============================================================
// Hook — TanStack Query com revalidação a cada 60s
// ============================================================
export const DASHBOARD_QUERY_KEY = ["dashboard"] as const;

export function useDashboardData() {
  const { session } = useAuth();
  const userId = session?.user.id;
  const queryClient = useQueryClient();
  const subscriptionId = useId();
  const query = useQuery<DashboardData, Error>({
    queryKey: [...DASHBOARD_QUERY_KEY, userId],
    queryFn: fetchDashboard,
    enabled: Boolean(userId),
    refetchOnWindowFocus: true,
    staleTime: 60_000,
    gcTime: 10 * 60_000,
    retry: 1,
  });

  useEffect(() => {
    const refresh = () => void queryClient.invalidateQueries({ queryKey: DASHBOARD_QUERY_KEY });
    const channel = supabase
      .channel(`crm-dashboard-live:${subscriptionId}`)
      .on("postgres_changes", { event: "*", schema: "public", table: "crm_leads" }, refresh)
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "crm_property_catalog" },
        refresh,
      )
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "crm_property_capturer_assignments" },
        refresh,
      )
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "crm_marketing_campaigns" },
        refresh,
      )
      .subscribe();
    return () => {
      void supabase.removeChannel(channel);
    };
  }, [queryClient, subscriptionId]);

  return {
    data: query.data,
    isLoading: Boolean(userId) && query.isLoading,
    isFetching: query.isFetching,
    error: query.error,
    notConfigured: false,
    unavailable: query.isError,
    refetch: query.refetch,
    dataUpdatedAt: query.dataUpdatedAt,
  };
}

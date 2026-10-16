import { createFileRoute } from "@tanstack/react-router";
import { Sidebar } from "@/components/dashboard/Sidebar";
import { Topbar } from "@/components/dashboard/Topbar";
import { KpiCard } from "@/components/dashboard/KpiCard";
import { Panel } from "@/components/dashboard/Panel";
import { ChannelBar, RevenueArea, TypeDonut } from "@/components/dashboard/Charts";
import { Funnel } from "@/components/dashboard/Funnel";
import { Ranking } from "@/components/dashboard/Ranking";
import { CaptureRankingPanel } from "@/components/dashboard/CaptureRankingPanel";
import { ApiAlert } from "@/components/dashboard/ApiAlert";
import { LeadDistributionPanel } from "@/components/dashboard/LeadDistributionPanel";
import { useDashboardData, type KpiKey } from "@/lib/api";
import { useAuth } from "@/components/auth/AuthProvider";
import { reportingDate, useDailyRevenueHistory } from "@/lib/daily-revenue";
import { DashboardFilter, getInitialFilterState, saveFilterState, isSameMonthAndYear, type DashboardFilterState } from "@/components/dashboard/DashboardFilter";
import { displayBrokerName } from "@/lib/broker-names";
import { useLeadAccess } from "@/lib/lead-access";
import { useSystemLeadOrigins } from "@/lib/lead-origin-report";
import {
  Activity,
  ArrowUpRight,
  Building2,
  Handshake,
  Home,
  KeySquare,
  PhoneCall,
  PauseCircle,
  TrendingUp,
  Users,
  Eye,
  EyeOff,
} from "lucide-react";
import { useEffect, useState } from "react";
import { canViewExecutiveDashboard, isAdministradorAdmin } from "@/lib/admin-access";

function getBrasiliaGreeting() {
  const hour = Number(
    new Intl.DateTimeFormat("pt-BR", {
      timeZone: "America/Sao_Paulo",
      hour: "2-digit",
      hourCycle: "h23",
    }).format(new Date()),
  );

  if (hour < 12) return "Bom dia";
  if (hour < 18) return "Boa tarde";
  return "Boa noite";
}

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "Painel Executivo — Sônia Lima" },
      {
        name: "description",
        content:
          "Visão executiva em tempo real: leads, funil, ranking de corretores e desempenho financeiro da Sônia Lima.",
      },
      { property: "og:title", content: "Painel Executivo — Sônia Lima" },
      {
        property: "og:description",
        content:
          "Visão executiva em tempo real: leads, funil, ranking de corretores e desempenho financeiro.",
      },
    ],
  }),
  component: Dashboard,
});

function Dashboard() {
  const { data, isLoading, notConfigured, unavailable } = useDashboardData();
  const { profile, session } = useAuth();
  const isAdmin = canViewExecutiveDashboard({
    id: profile?.id ?? session?.user.id,
    role: profile?.role,
    email: profile?.email ?? session?.user.email,
  });
  const isBroker = profile?.role === "broker";
  const allysonAdmin = isAdministradorAdmin({
    id: profile?.id ?? session?.user.id,
    role: profile?.role,
    email: session?.user.email,
  });
  const [financialKpisHidden, setFinancialKpisHidden] = useState(true);
  const [timeGreeting, setTimeGreeting] = useState(getBrasiliaGreeting);
  const [filter, setFilterState] = useState<DashboardFilterState>(() => getInitialFilterState(session?.user.email));
  useEffect(() => {
    const updateGreeting = () => setTimeGreeting(getBrasiliaGreeting());
    const interval = window.setInterval(updateGreeting, 60_000);
    return () => window.clearInterval(interval);
  }, []);
  const setFilter = (newFilter: DashboardFilterState) => {
    if (session?.user.email !== "unassigned-institutional@example.invalid") saveFilterState(newFilter);
    setFilterState(newFilter);
  };
  const dashboardGreeting =
    session?.user.email === "unassigned-institutional@example.invalid"
      ? "Sônia Lima"
      : isAdmin
        ? "Sônia Lima"
        : displayBrokerName(profile?.fullName) || "Corretor";
  const dailyRevenue = useDailyRevenueHistory(Boolean(profile));
  const leadAccess = useLeadAccess(session?.user.id);
  const systemLeadOrigins = useSystemLeadOrigins(session?.user.id, filter, isBroker);
  const visibleDailyRevenue = (isAdmin
    ? (dailyRevenue.data ?? [])
    : (dailyRevenue.data ?? []).filter((entry) => entry.broker_id === profile?.id))
    .filter((entry) => filter.allTime || isSameMonthAndYear(reportingDate(entry).toISOString(), filter));
    
  const allTimeDailyRevenue = (isAdmin
    ? (dailyRevenue.data ?? [])
    : (dailyRevenue.data ?? []).filter((entry) => entry.broker_id === profile?.id));

  const dailyTotal = visibleDailyRevenue.reduce((total, entry) => total + Number(entry.amount), 0);
  const dailyTransactionCount = visibleDailyRevenue.length;
  const totalVgv = allTimeDailyRevenue.reduce(
    (total, entry) => (entry.kind === "venda" ? total + Number(entry.vgv ?? 0) : total),
    0,
  );
  const crmLeadCounts = leadAccess.leads.reduce(
    (counts, lead) => {
      const stage = lead.estagio.trim().toLocaleLowerCase("pt-BR");
      
      if (["em atendimento", "standby", "visita agendada"].includes(stage))
        counts.atendimentos += 1;
      if (stage === "standby") counts.standby += 1;
      
      if (filter.allTime || isSameMonthAndYear(lead.visitaRealizadaEm, filter)) {
        if (lead.visitaRealizadaEm) counts.visitas += 1;
      }
      if (filter.allTime || isSameMonthAndYear(lead.propostaEm, filter)) {
        if (lead.propostaEm) counts.propostas += 1;
      }
      return counts;
    },
    { atendimentos: 0, standby: 0, visitas: 0, propostas: 0 },
  );
  
  const generatedLeadsCount = leadAccess.leads.filter(
    (lead) => filter.allTime || isSameMonthAndYear(lead.criadoEm, filter)
  ).length;

  const filteredLeadsForChannels = leadAccess.leads.filter(
    (lead) => (isAdmin || lead.ownerId === session?.user.id) &&
      (filter.allTime || isSameMonthAndYear(lead.criadoEm, filter))
  );
  const leadChannels = Object.entries(
    filteredLeadsForChannels.reduce<Record<string, number>>((channels, lead) => {
      const channel = lead.canal?.trim() || "Não informado";
      channels[channel] = (channels[channel] ?? 0) + 1;
      return channels;
    }, {}),
  ).map(([c, v]) => ({ c, v }));
  const dailySales = visibleDailyRevenue.filter((entry) => entry.kind === "venda").length;
  const dailyRentals = visibleDailyRevenue.filter((entry) => entry.kind === "aluguel").length;
  const dashboardSales = dailySales;
  
  const marketingInvestmentForFilter = (data?.marketing ?? [])
    .filter((camp) => filter.allTime || isSameMonthAndYear(camp.data, filter))
    .reduce((total, campaign) => total + Number(campaign.valorInvestido), 0);
  const dashboardRoi = marketingInvestmentForFilter
    ? ((dailyTotal - marketingInvestmentForFilter) / marketingInvestmentForFilter) * 100
    : 0;
  const currentYear = new Date().getFullYear();
  const revenueData = Array.from({ length: 12 }, (_, month) => ({
    m: new Date(currentYear, month, 1).toLocaleDateString("pt-BR", { month: "short" }),
    vendas: 0,
    locacoes: 0,
  }));
  for (const entry of allTimeDailyRevenue) {
    const reportDate = reportingDate(entry);
    const year = reportDate.getFullYear();
    const month = reportDate.getMonth() + 1;
    if (year !== currentYear || !month || !revenueData[month - 1]) continue;
    if (entry.kind === "venda") revenueData[month - 1].vendas += Number(entry.amount);
    else revenueData[month - 1].locacoes += Number(entry.amount);
  }

  type KpiDef = {
    key: KpiKey | "vgv";
    label: string;
    icon: typeof Users;
    format?: "number" | "currency" | "percent" | "time";
  };
  const kpiDefs: KpiDef[] = [
    { key: "leads", label: "Leads", icon: Users },
    { key: "atendimentos", label: "Atendimentos", icon: PhoneCall },
    { key: "standby", label: "Em espera", icon: PauseCircle },
    { key: "visitas", label: "Visitas", icon: KeySquare },
    { key: "propostas", label: "Propostas", icon: Handshake },
    { key: "vendas", label: "Vendas", icon: Home },
    { key: "locacoes", label: "Locações", icon: Building2 },
    { key: "faturamento", label: "Faturamento", icon: TrendingUp, format: "currency" },
    { key: "vgv", label: "VGV", icon: Home, format: "currency" },
    { key: "roi", label: "ROI", icon: Activity, format: "percent" },
    { key: "ticketMedio", label: "Ticket Médio", icon: ArrowUpRight, format: "currency" },
  ];

  const loading = isLoading || (!data && !notConfigured && !unavailable);
  const statusLabel = notConfigured
    ? "Aguardando URL da API"
    : unavailable
      ? "API indisponível"
      : loading
        ? "Carregando planilha…"
        : "Atualizado agora";

  return (
    <div className="crm-shell min-h-dvh">
      <Sidebar />
      <main className="crm-main ml-0 min-w-0 px-4 pb-10 pt-16 sm:px-6 lg:ml-[264px] lg:px-8 lg:pb-16 lg:pt-0">
        <Topbar />

        {notConfigured && <ApiAlert variant="not-configured" />}
        {unavailable && <ApiAlert variant="unavailable" />}

        <section className="mb-8 flex flex-wrap items-end justify-between gap-4 anim-float-in">
          <div>
            <div className="flex items-center gap-2 text-[11px] uppercase tracking-[0.24em] text-muted-foreground">
              <span className="inline-block h-1.5 w-1.5 rounded-full bg-copper shadow-[0_0_10px_var(--copper)]" />
              Visão executiva · {statusLabel}
            </div>
            <h1 className="mt-2 text-3xl font-semibold tracking-tight text-foreground">
              {timeGreeting}, <span className="text-gradient-copper">{dashboardGreeting}</span>.
            </h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Desempenho comercial em tempo real.
            </p>
          </div>
          <div className="flex flex-wrap items-center gap-4">
            <DashboardFilter filter={filter} onChange={setFilter} />
            {isAdmin && (
              <button
                type="button"
                onClick={() => setFinancialKpisHidden(!financialKpisHidden)}
                className="mb-6 flex h-10 items-center gap-2 rounded-lg border border-white/10 bg-white/5 px-4 text-sm font-medium text-muted-foreground transition hover:border-copper/50 hover:text-copper"
                title={financialKpisHidden ? "Exibir valores financeiros" : "Ocultar valores financeiros"}
              >
                {financialKpisHidden ? <Eye size={16} /> : <EyeOff size={16} />}
                {financialKpisHidden ? "Exibir finanças" : "Ocultar finanças"}
              </button>
            )}
          </div>
        </section>

        <LeadDistributionPanel />

        <section className="mb-8 grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 2xl:grid-cols-5">
          {kpiDefs
            .filter(
              (k) =>
                isAdmin || !["faturamento", "vgv", "cac", "roi", "ticketMedio"].includes(k.key),
            )
            .map((k) => {
              const isDailyFinancialKpi = ["faturamento", "vgv", "ticketMedio", "roi"].includes(k.key);
              const entry = isDailyFinancialKpi || k.key === "vgv" ? undefined : data?.kpis?.[k.key];
              const value =
                k.key === "leads"
                  ? generatedLeadsCount
                  : k.key === "vgv"
                    ? totalVgv
                    : k.key === "faturamento"
                      ? dailyTotal
                      : k.key === "atendimentos" && !leadAccess.loading
                        ? crmLeadCounts.atendimentos
                        : k.key === "standby" && !leadAccess.loading
                          ? crmLeadCounts.standby
                          : k.key === "visitas" && !leadAccess.loading
                            ? crmLeadCounts.visitas
                            : k.key === "propostas" && !leadAccess.loading
                              ? crmLeadCounts.propostas
                              : k.key === "vendas"
                                ? dashboardSales
                                : k.key === "locacoes"
                                  ? dailyRentals
                                  : k.key === "ticketMedio"
                                    ? dailyTotal / Math.max(1, dailyTransactionCount)
                                    : k.key === "roi"
                                      ? dashboardRoi
                                      : (entry?.value ?? 0);
              return (
                <KpiCard
                  key={k.key}
                  label={k.label}
                  icon={k.icon}
                  format={k.format}
                  value={value}
                  delta={entry?.delta ?? 0}
                  loading={
                    loading ||
                    (!entry &&
                      ![
                        "leads",
                        "atendimentos",
                        "standby",
                        "visitas",
                        "propostas",
                        "vendas",
                        "locacoes",
                        "faturamento",
                        "vgv",
                        "ticketMedio",
                        "roi",
                      ].includes(k.key)) ||
                    (k.key === "leads" && leadAccess.loading) ||
                    (["faturamento", "ticketMedio", "vgv"].includes(k.key) &&
                      dailyRevenue.isLoading)
                  }
                  valueHidden={isAdmin && isDailyFinancialKpi && financialKpisHidden}
                />
              );
            })}
        </section>

        {isAdmin ? (
          <section className="mb-8 grid grid-cols-1 gap-4 xl:grid-cols-3">
            <Panel
              title="Faturamento mensal"
              subtitle="Linhas separadas para vendas e locações"
              className="xl:col-span-2"
            >
              <RevenueArea data={revenueData} />
            </Panel>
            <Panel title="Mix de portfólio" subtitle="Distribuição por tipologia">
              <TypeDonut data={data?.portfolio} />
            </Panel>
          </section>
        ) : (
          <section className="mb-8">
            <Panel title="Mix de portfólio" subtitle="Distribuição por tipologia">
              <TypeDonut data={data?.portfolio} />
            </Panel>
          </section>
        )}

        <section className="mb-8 grid grid-cols-1 gap-4 lg:grid-cols-2">
          <Panel title="Funil de vendas" subtitle="Da captação ao fechamento">
            <Funnel data={data?.funil} />
          </Panel>
          <Panel
            title="Ranking de corretores"
            subtitle="Faturamento e negócios por mês"
          >
            <Ranking
              data={data?.ranking}
              showRevenue={isAdmin && !financialKpisHidden}
            />
          </Panel>
        </section>

        <section className="mb-8">
          <Panel
            title="Ranking de captação"
            subtitle="Pontuação anual · vendas diárias 10 · imóveis ativados: exclusividade 7 · sem exclusividade 5 · sem autorização 3"
          >
            <CaptureRankingPanel />
          </Panel>
        </section>

        <section className="mb-8">
          <Panel title={isBroker ? "Origem dos meus leads" : "Origem de leads"} subtitle="Volume por canal">
            <ChannelBar data={leadChannels} emptyLabel={leadAccess.loading ? "Carregando leads…" : "Nenhum lead no período selecionado."} />
          </Panel>
        </section>

        {isBroker && (
          <section className="mb-8">
            <Panel title="Origem de leads — geral" subtitle="Todos os leads do sistema · volume por canal">
              {systemLeadOrigins.isError ? (
                <p role="alert" className="py-10 text-center text-sm text-muted-foreground">
                  Não foi possível carregar o relatório geral.
                  <button type="button" className="ml-2 text-blue-400 underline" onClick={() => systemLeadOrigins.refetch()}>Tentar novamente</button>
                </p>
              ) : (
                <ChannelBar data={systemLeadOrigins.data} color="blue" emptyLabel={systemLeadOrigins.isLoading ? "Carregando leads…" : "Nenhum lead no período selecionado."} />
              )}
            </Panel>
          </section>
        )}

        <footer className="mt-12 flex flex-wrap items-center justify-between gap-3 border-t border-white/5 pt-6 text-[11px] text-muted-foreground">
          <div className="flex items-center gap-2">
            <span className="inline-block h-1.5 w-1.5 rounded-full bg-emerald-400 anim-pulse-glow" />
            Todos os sistemas operacionais · v1.0.0
          </div>
          <div>© {new Date().getFullYear()} Sônia Lima · Desenvolvido por Allyson</div>
        </footer>
      </main>
    </div>
  );
}

import { CircleDollarSign, Loader2, Megaphone, Plus, Target } from "lucide-react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { ChannelBar } from "@/components/dashboard/Charts";
import { KpiCard } from "@/components/dashboard/KpiCard";
import { Panel } from "@/components/dashboard/Panel";
import type { DashboardData, MarketingRow } from "@/lib/api";
import { useDailyRevenueHistory } from "@/lib/daily-revenue";
import { useAuth } from "@/components/auth/AuthProvider";
import { useLeadAccess } from "@/lib/lead-access";
import { supabase } from "@/lib/supabase";
import { hasFullAdminAccess } from "@/lib/admin-access";
import { DashboardFilter, getInitialFilterState, saveFilterState, isSameMonthAndYear, type DashboardFilterState } from "@/components/dashboard/DashboardFilter";
import { useState } from "react";
import { reportingDate } from "@/lib/daily-revenue";

export function MarketingDashboard({
  data,
  loading,
  error,
  retry,
}: {
  data?: DashboardData;
  loading: boolean;
  error?: Error | null;
  retry: () => void;
}) {
  const { session, profile } = useAuth();
  const queryClient = useQueryClient();
  const createCampaign = useMutation({
    mutationFn: async (form: FormData) => {
      const number = (name: string) => Number(String(form.get(name) || "0").replace(",", ".")) || 0;
      const { error: createError } = await supabase.from("crm_marketing_campaigns").insert({
        campaign_date: String(form.get("date")),
        name: String(form.get("name")).trim(),
        channel: String(form.get("channel")).trim() || null,
        objective: String(form.get("objective")).trim() || null,
        status: String(form.get("status")) || "Ativa",
        invested: number("invested"),
        leads_generated: number("leads"),
        visits_generated: number("visits"),
        deals_closed: number("deals"),
        revenue: number("revenue"),
        responsible: profile?.fullName || session?.user.email || null,
      });
      if (createError) throw createError;
    },
    onSuccess: async () => queryClient.invalidateQueries({ queryKey: ["dashboard"] }),
  });
  const leadAccess = useLeadAccess(session?.user.id);
  const campaigns = data?.marketing ?? [];
  const dailyRevenue = useDailyRevenueHistory(true);
  const [filter, setFilterState] = useState<DashboardFilterState>(() => getInitialFilterState(session?.user.email));
  const setFilter = (newFilter: DashboardFilterState) => {
    if (session?.user.email !== "unassigned-institutional@example.invalid") saveFilterState(newFilter);
    setFilterState(newFilter);
  };

  const filteredCampaigns = campaigns.filter(
    (camp) => filter.allTime || isSameMonthAndYear(camp.data ?? camp.atualizadoEm ?? camp.criadoEm, filter)
  );
  const filteredDailyRevenue = (dailyRevenue.data ?? []).filter(
    (entry) => filter.allTime || isSameMonthAndYear(reportingDate(entry).toISOString(), filter)
  );
  
  const totals = filteredCampaigns.reduce(
    (value, campaign) => ({
      invested: value.invested + campaign.valorInvestido,
      visits: value.visits + campaign.visitasGeradas,
      deals: value.deals + campaign.negociosFechados,
      revenue: value.revenue + campaign.receitaGerada,
    }),
    { invested: 0, visits: 0, deals: 0, revenue: 0 },
  );
  
  const filteredLeads = leadAccess.leads.filter(
    (lead) => filter.allTime || isSameMonthAndYear(lead.criadoEm, filter)
  );

  const channels = Object.entries(
    filteredLeads.reduce<Record<string, number>>((values, lead) => {
      const channel = lead.canal?.trim() || "Não informado";
      values[channel] = (values[channel] ?? 0) + 1;
      return values;
    }, {}),
  ).map(([c, v]) => ({ c, v }));
  
  const leadsFromCrm = filteredLeads.length;
  
  // Visitas geradas - puxando do funil baseado em visitaRealizadaEm
  const visitsFromDashboard = leadAccess.leads.filter(
    (lead) => lead.visitaRealizadaEm && (filter.allTime || isSameMonthAndYear(lead.visitaRealizadaEm, filter))
  ).length;

  const dailyRevenueTotal = filteredDailyRevenue.reduce(
    (total, entry) => total + Number(entry.amount),
    0,
  );
  // Receita gerada agora puxa do preenchimento diário (dailyRevenueTotal)
  const companyRevenue = dailyRevenueTotal;
  const roi = totals.invested ? ((companyRevenue - totals.invested) / totals.invested) * 100 : 0;
  
  // Negocios fechados = apenas vendas no preenchimento diario
  const closedDeals = filteredDailyRevenue.filter(entry => entry.kind === "venda").length;
  
  // Propostas feitas
  const proposalsMade = leadAccess.leads.filter(
    (lead) => lead.propostaEm && (filter.allTime || isSameMonthAndYear(lead.propostaEm, filter))
  ).length;
  
  const now = new Date();
  const currentMonth = new Date(now.getFullYear(), now.getMonth(), 1);
  const previousMonth = new Date(now.getFullYear(), now.getMonth() - 1, 1);
  const totalsFor = (start: Date, end?: Date) =>
    campaigns
      .filter((campaign) => {
        const date = campaign.data ? new Date(campaign.data) : undefined;
        return date && !Number.isNaN(date.getTime()) && date >= start && (!end || date < end);
      })
      .reduce(
        (value, campaign) => ({
          invested: value.invested + campaign.valorInvestido,
          deals: value.deals + campaign.negociosFechados,
          revenue: value.revenue + campaign.receitaGerada,
        }),
        { invested: 0, deals: 0, revenue: 0 },
      );
  const current = totalsFor(currentMonth);
  const previous = totalsFor(previousMonth, currentMonth);
  const delta = (value: number, prior: number) =>
    prior === 0 ? (value === 0 ? 0 : 100) : ((value - prior) / Math.abs(prior)) * 100;

  return (
    <>
      <section className="mb-8 anim-float-in">
        <div className="flex items-center justify-between gap-4">
          <div>
            <div className="flex items-center gap-2 text-[11px] uppercase tracking-[0.24em] text-muted-foreground">
              <span className="h-1.5 w-1.5 rounded-full bg-copper shadow-[0_0_10px_var(--copper)]" />
              Inteligência de aquisição
            </div>
            <h1 className="mt-2 text-3xl font-semibold tracking-tight">{"Divulga\u00e7\u00e3o"}</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Indicadores e campanhas registrados diretamente no CRM.
            </p>
          </div>
          <DashboardFilter filter={filter} onChange={setFilter} />
        </div>
      </section>
      {hasFullAdminAccess(profile) && (
        <details className="mb-8 rounded-xl border border-border bg-card/70 p-4">
          <summary className="flex cursor-pointer list-none items-center gap-2 text-sm font-medium text-copper">
            <Plus size={16} /> Cadastrar campanha
          </summary>
          <form
            className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4"
            onSubmit={(event) => {
              event.preventDefault();
              const form = event.currentTarget;
              createCampaign.mutate(new FormData(form), { onSuccess: () => form.reset() });
            }}
          >
            <input name="name" required placeholder="Nome da campanha" className={campaignInput} />
            <input
              name="date"
              required
              type="date"
              defaultValue={new Date().toISOString().slice(0, 10)}
              className={campaignInput}
            />
            <input name="channel" placeholder="Canal" className={campaignInput} />
            <input name="objective" placeholder="Objetivo" className={campaignInput} />
            <select name="status" className={campaignInput}>
              <option>Ativa</option>
              <option>Pausada</option>
              <option>Encerrada</option>
            </select>
            <input
              name="invested"
              type="number"
              min="0"
              step="0.01"
              placeholder="Investimento"
              className={campaignInput}
            />
            <input
              name="leads"
              type="number"
              min="0"
              placeholder="Leads gerados"
              className={campaignInput}
            />
            <input
              name="visits"
              type="number"
              min="0"
              placeholder="Visitas geradas"
              className={campaignInput}
            />
            <input
              name="deals"
              type="number"
              min="0"
              placeholder="Negócios fechados"
              className={campaignInput}
            />
            <input
              name="revenue"
              type="number"
              min="0"
              step="0.01"
              placeholder="Receita gerada"
              className={campaignInput}
            />
            <button
              disabled={createCampaign.isPending}
              className="flex items-center justify-center gap-2 rounded-lg bg-copper px-4 py-2 text-sm font-medium text-white disabled:opacity-60"
            >
              {createCampaign.isPending && <Loader2 size={15} className="animate-spin" />} Salvar
              campanha
            </button>
            {createCampaign.error && (
              <p className="text-xs text-red-300 sm:col-span-2">{createCampaign.error.message}</p>
            )}
          </form>
        </details>
      )}
      {error ? (
        <Panel title="Dados de divulga\u00e7\u00e3o">
          <div className="py-10 text-center">
            <p className="text-sm text-muted-foreground">
              {"N\u00e3o foi poss\u00edvel carregar os indicadores de divulga\u00e7\u00e3o."}
            </p>
            <button onClick={retry} className="mt-3 text-sm text-copper underline">
              Tentar novamente
            </button>
          </div>
        </Panel>
      ) : (
        <>
          <section className="mb-8 grid grid-cols-1 gap-4 sm:grid-cols-2">
            <Metric
              label="ROI"
              value={roi}
              delta={delta(current.invested, previous.invested)}
              format="percent"
              icon={Target}
              loading={loading}
            />
            <Metric
              label="Investimento"
              value={totals.invested}
              delta={delta(current.invested, previous.invested)}
              format="currency"
              icon={CircleDollarSign}
              loading={loading}
            />
          </section>
          <section className="mb-8">
            <Panel
              title="Leads gerados por canal"
              subtitle="Origem informada no cadastro dos leads"
            >
              <ChannelBar data={channels} />
            </Panel>
          </section>
          <section className="mb-8">
            <Panel
              title="Resumo de leads em negócios fechados"
              subtitle="Dados consolidados do CRM e dos lançamentos diários."
            >
              <dl className="grid h-full grid-cols-2 gap-4 p-2 text-sm lg:grid-cols-3">
                <Summary label="Campanhas" value={campaigns.length} />
                <Summary label="Leads gerados" value={leadsFromCrm} />
                <Summary label="Visitas geradas" value={visitsFromDashboard} />
                <Summary label="Propostas feitas" value={proposalsMade} />
                <Summary label="Vendas realizadas" value={closedDeals} />
              </dl>
            </Panel>
          </section>
          <section className="mb-8">
            <Panel title="Campanhas" subtitle="Registros existentes no CRM">
              <CampaignList campaigns={campaigns} />
            </Panel>
          </section>
        </>
      )}
    </>
  );
}

const campaignInput =
  "rounded-lg border border-border bg-background/60 px-3 py-2 text-sm outline-none placeholder:text-muted-foreground focus:border-copper";

function Metric({
  label,
  value,
  delta,
  format,
  icon,
  loading,
}: {
  label: string;
  value: number;
  delta: number;
  format: "number" | "currency" | "percent";
  icon: typeof Target;
  loading: boolean;
}) {
  return (
    <KpiCard
      label={label}
      value={value}
      delta={delta}
      format={format}
      icon={icon}
      loading={loading}
    />
  );
}

function Summary({ label, value }: { label: string; value: string | number }) {
  return (
    <div>
      <dt className="text-xs text-muted-foreground">{label}</dt>
      <dd className="mt-1 text-lg font-semibold">{value}</dd>
    </div>
  );
}

function CampaignList({ campaigns }: { campaigns: MarketingRow[] }) {
  if (!campaigns.length)
    return (
      <Empty
        title="Nenhuma campanha cadastrada"
        text="Cadastre a primeira campanha diretamente nesta tela."
      />
    );
  return (
    <div className="space-y-2">
      {campaigns.map((campaign, index) => (
        <div
          key={campaign.id || `${campaign.campanha}-${index}`}
          className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-white/5 bg-white/[0.02] px-4 py-3"
        >
          <div>
            <p className="text-sm font-medium">{campaign.campanha || "Campanha sem nome"}</p>
            <p className="text-xs text-muted-foreground">
              {campaign.canal || "Canal não informado"} ·{" "}
              {campaign.status || "Status não informado"} · {campaign.leadsGerados} leads gerados
            </p>
          </div>
          <span className="rounded-full bg-copper/10 px-2 py-1 text-xs text-copper">
            {campaign.valorInvestido.toLocaleString("pt-BR", {
              style: "currency",
              currency: "BRL",
            })}
          </span>
        </div>
      ))}
    </div>
  );
}

function Empty({ title, text }: { title: string; text: string }) {
  return (
    <div className="flex min-h-[180px] flex-col items-center justify-center px-6 text-center">
      <Megaphone className="text-copper" size={22} />
      <p className="mt-3 text-sm font-medium">{title}</p>
      <p className="mt-1 max-w-sm text-xs leading-relaxed text-muted-foreground">{text}</p>
    </div>
  );
}

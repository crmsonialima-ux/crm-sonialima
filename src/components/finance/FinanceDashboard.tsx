import {
  ArrowDownToLine,
  ArrowUpFromLine,
  BadgeDollarSign,
  Building2,
  Landmark,
  WalletCards,
} from "lucide-react";
import { useMemo, useState } from "react";
import { RevenueArea } from "@/components/dashboard/Charts";
import { KpiCard } from "@/components/dashboard/KpiCard";
import { Panel } from "@/components/dashboard/Panel";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import type { DashboardData, RevenuePoint } from "@/lib/api";

const periods = ["Todos", "3 meses", "6 meses", "12 meses"] as const;
export function FinanceDashboard({
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
  const [period, setPeriod] = useState<(typeof periods)[number]>("12 meses");
  const revenue = useMemo<RevenuePoint[]>(() => {
    const values = data?.receita ?? [];
    if (period === "Todos") return values;
    const count = Number(period.split(" ")[0]);
    return values.slice(-count);
  }, [data?.receita, period]);
  const sales = data?.kpis.vendas;
  const rentals = data?.kpis.locacoes;
  const commission = data?.kpis.comissao;
  const invoicing = data?.kpis.faturamento;
  const cashflow = revenue.reduce((total, item) => total + item.vendas + item.locacoes, 0);
  return (
    <>
      <section className="mb-8 flex flex-wrap items-end justify-between gap-4 anim-float-in">
        <div>
          <div className="flex items-center gap-2 text-[11px] uppercase tracking-[0.24em] text-muted-foreground">
            <span className="h-1.5 w-1.5 rounded-full bg-copper shadow-[0_0_10px_var(--copper)]" />
            Gestão financeira
          </div>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Financeiro</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Receitas, comissões e evolução financeira da operação.
          </p>
        </div>
        <label className="hidden">
          <span className="sr-only">Filtrar período</span>
          <select
            value={period}
            onChange={(event) => setPeriod(event.target.value as typeof period)}
            className="bg-transparent py-2 text-sm outline-none"
          >
            {periods.map((item) => (
              <option key={item}>{item}</option>
            ))}
          </select>
        </label>
        <Select value={period} onValueChange={(value) => setPeriod(value as typeof period)}>
          <SelectTrigger
            aria-label="Filtrar período"
            className="w-36 border-white/10 bg-white/[0.03] text-sm shadow-none"
          >
            <SelectValue />
          </SelectTrigger>
          <SelectContent className="glass-strong border-white/10">
            {periods.map((item) => (
              <SelectItem key={item} value={item}>
                {item}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </section>
      {error ? (
        <Panel title="Dados financeiros">
          <div className="py-12 text-center">
            <p className="text-sm text-muted-foreground">
              Não foi possível carregar os dados financeiros.
            </p>
            <button onClick={retry} className="mt-3 text-sm text-copper underline">
              Tentar novamente
            </button>
          </div>
        </Panel>
      ) : (
        <>
          <section className="mb-8 grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
            <KpiCard
              label="Vendas"
              value={sales?.value ?? 0}
              delta={sales?.delta ?? 0}
              icon={BadgeDollarSign}
              loading={loading || !sales}
            />
            <KpiCard
              label="Locações"
              value={rentals?.value ?? 0}
              delta={rentals?.delta ?? 0}
              icon={Building2}
              loading={loading || !rentals}
            />
            <KpiCard
              label="Comissões"
              value={commission?.value ?? 0}
              delta={commission?.delta ?? 0}
              format="currency"
              icon={WalletCards}
              loading={loading || !commission}
            />
            <KpiCard
              label="Faturamento"
              value={invoicing?.value ?? 0}
              delta={invoicing?.delta ?? 0}
              format="currency"
              icon={Landmark}
              loading={loading || !invoicing}
            />
          </section>
          <section className="mb-8 grid gap-4 xl:grid-cols-3">
            <Panel
              title="Fluxo de caixa"
              subtitle={`Vendas × locações · ${period}`}
              className="xl:col-span-2"
            >
              <RevenueArea data={revenue} />
            </Panel>
            <Panel title="Saldo consolidado" subtitle="Soma das receitas no período">
              <div className="flex h-[280px] flex-col justify-center">
                <div className="text-[11px] uppercase tracking-[0.18em] text-muted-foreground">
                  Receita acumulada
                </div>
                {loading ? (
                  <div className="skeleton mt-3 h-10 w-40" />
                ) : (
                  <div className="mt-2 text-3xl font-semibold tracking-tight">
                    {cashflow.toLocaleString("pt-BR", {
                      style: "currency",
                      currency: "BRL",
                      maximumFractionDigits: 0,
                    })}
                  </div>
                )}
                <p className="mt-3 text-xs leading-relaxed text-muted-foreground">
                  Calculado a partir das séries de vendas e locações retornadas pela API.
                </p>
              </div>
            </Panel>
          </section>
          <section className="mb-8 grid gap-4 lg:grid-cols-2">
            <AccountsPanel
              title="Contas a receber"
              icon={ArrowUpFromLine}
              description="Nenhuma conta a receber foi retornada pela API financeira."
            />
            <AccountsPanel
              title="Contas a pagar"
              icon={ArrowDownToLine}
              description="Nenhuma conta a pagar foi retornada pela API financeira."
            />
          </section>
        </>
      )}
    </>
  );
}
function AccountsPanel({
  title,
  icon: Icon,
  description,
}: {
  title: string;
  icon: typeof ArrowUpFromLine;
  description: string;
}) {
  return (
    <Panel title={title} subtitle="Lançamentos financeiros">
      <div className="flex min-h-44 flex-col items-center justify-center text-center">
        <div className="grid h-11 w-11 place-items-center rounded-xl border border-white/10 bg-white/[0.03] text-copper">
          <Icon size={18} />
        </div>
        <p className="mt-3 text-sm font-medium">Sem lançamentos disponíveis</p>
        <p className="mt-1 max-w-xs text-xs text-muted-foreground">{description}</p>
      </div>
    </Panel>
  );
}

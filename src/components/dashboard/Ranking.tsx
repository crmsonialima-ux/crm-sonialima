import type { RankingRow } from "@/lib/api";
import { displayBrokerName } from "@/lib/broker-names";
import { supabase } from "@/lib/supabase";
import { ChevronLeft, ChevronRight, Loader2 } from "lucide-react";
import { useEffect, useMemo, useState } from "react";

type SalesRankingRow = {
  broker_id: string | null;
  broker_name: string;
  vendas: number;
  faturamento: number | null;
};

const DEFAULT_BROKER_ROSTER = ["crmdanilo", "crmnoemia", "crmsonia", "crmallyson"];

function firstDayOfMonth(date: Date) {
  return new Date(date.getFullYear(), date.getMonth(), 1);
}

function moveMonth(date: Date, amount: number) {
  return new Date(date.getFullYear(), date.getMonth() + amount, 1);
}

function databaseDate(date: Date) {
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${date.getFullYear()}-${month}-${day}`;
}

export function Ranking({ data, showRevenue }: { data?: RankingRow[]; showRevenue: boolean }) {
  const [selectedMonth, setSelectedMonth] = useState(() => firstDayOfMonth(new Date()));
  const [salesRanking, setSalesRanking] = useState<SalesRankingRow[]>([]);
  const [loadingMonth, setLoadingMonth] = useState(true);
  const [refreshToken, setRefreshToken] = useState(0);

  useEffect(() => {
    let active = true;
    const nextMonth = moveMonth(selectedMonth, 1);

    setLoadingMonth(true);
    void supabase
      .rpc("get_sales_ranking", {
        p_start: databaseDate(selectedMonth),
        p_end: databaseDate(nextMonth),
      })
      .then(({ data: rows, error }) => {
        if (!active) return;
        setSalesRanking(error ? [] : ((rows ?? []) as SalesRankingRow[]));
        setLoadingMonth(false);
      });

    return () => {
      active = false;
    };
  }, [selectedMonth, refreshToken]);

  useEffect(() => {
    const channel = supabase
      .channel("sales-ranking-reports")
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "crm_sales" },
        () => setRefreshToken((value) => value + 1),
      )
      .subscribe();

    return () => {
      void supabase.removeChannel(channel);
    };
  }, []);

  useEffect(() => {
    const interval = window.setInterval(() => setRefreshToken((value) => value + 1), 15_000);
    return () => window.clearInterval(interval);
  }, []);

  const ranking = useMemo(() => {
    // Preserve the existing broker roster and tiers, but reset totals because
    // the selected month's values come exclusively from occurred_on.
    const totals = new Map<string, RankingRow>();
    for (const item of data ?? []) {
      const nome = displayBrokerName(item.nome);
      totals.set(nome, { ...item, nome, vendas: 0, faturamento: 0 });
    }
    for (const nome of DEFAULT_BROKER_ROSTER) {
      const displayName = displayBrokerName(nome);
      if (!totals.has(displayName)) {
        totals.set(displayName, { id: displayName, nome: displayName, vendas: 0, faturamento: 0 });
      }
    }

    for (const item of salesRanking) {
      const nome = displayBrokerName(item.broker_name);
      // The legacy dashboard roster identifies brokers by display name while
      // sale reports store their UUID. Keep both sources on the same name
      // key so a sale entered for "Daniel" updates the existing Daniel row.
      const brokerKey = nome;
      const broker = totals.get(brokerKey) ?? { id: brokerKey, nome, vendas: 0, faturamento: 0 };
      broker.faturamento += Number(item.faturamento ?? 0) || 0;
      broker.vendas += Number(item.vendas) || 0;
      totals.set(brokerKey, broker);
    }

    return [...totals.values()].sort(
      (left, right) =>
        (showRevenue ? right.faturamento - left.faturamento : right.vendas - left.vendas) ||
        right.vendas - left.vendas ||
        left.nome.localeCompare(right.nome, "pt-BR"),
    );
  }, [data, salesRanking, showRevenue]);

  const currentMonth = firstDayOfMonth(new Date());
  const isCurrentMonth =
    selectedMonth.getFullYear() === currentMonth.getFullYear() &&
    selectedMonth.getMonth() === currentMonth.getMonth();
  const monthLabel = selectedMonth.toLocaleDateString("pt-BR", {
    month: "long",
    year: "numeric",
  });

  const monthNavigation = (
    <div className="mb-3 flex items-center justify-between rounded-xl border border-white/5 bg-white/[0.02] px-2 py-1.5">
      <button
        type="button"
        onClick={() => setSelectedMonth((month) => moveMonth(month, -1))}
        className="grid h-8 w-8 place-items-center rounded-lg text-muted-foreground transition hover:bg-white/[0.06] hover:text-foreground"
        aria-label="Mês anterior"
        title="Mês anterior"
      >
        <ChevronLeft size={17} />
      </button>
      <div className="min-w-36 text-center">
        <div className="text-xs font-semibold capitalize text-foreground">{monthLabel}</div>
        <div className="mt-0.5 text-[9px] text-muted-foreground">
          Vendas pela data do dia informado
        </div>
      </div>
      <button
        type="button"
        onClick={() => setSelectedMonth((month) => moveMonth(month, 1))}
        disabled={isCurrentMonth}
        className="grid h-8 w-8 place-items-center rounded-lg text-muted-foreground transition hover:bg-white/[0.06] hover:text-foreground disabled:cursor-not-allowed disabled:opacity-30 disabled:hover:bg-transparent"
        aria-label="Próximo mês"
        title={isCurrentMonth ? "Este é o mês atual" : "Próximo mês"}
      >
        <ChevronRight size={17} />
      </button>
    </div>
  );

  if (!data) {
    return (
      <div>
        {monthNavigation}
        <div className="space-y-2">
          {Array.from({ length: 5 }).map((_, i) => (
            <div key={i} className="skeleton h-14 w-full rounded-xl" />
          ))}
        </div>
      </div>
    );
  }

  if (loadingMonth) {
    return (
      <div>
        {monthNavigation}
        <div className="flex h-44 items-center justify-center text-muted-foreground">
          <Loader2 className="h-5 w-5 animate-spin" aria-label="Carregando ranking mensal" />
        </div>
      </div>
    );
  }

  if (ranking.length === 0) {
    return (
      <div>
        {monthNavigation}
        <div className="flex h-44 items-center justify-center rounded-xl border border-dashed border-white/10 text-center text-xs text-muted-foreground">
          Nenhum corretor disponível neste mês.
        </div>
      </div>
    );
  }

  const max = Math.max(
    ...ranking.map((broker) => (showRevenue ? broker.faturamento : broker.vendas)),
    1,
  );

  return (
    <div>
      {monthNavigation}
      <div className="space-y-2">
        {ranking.map((broker, index) => {
          const pct = ((showRevenue ? broker.faturamento : broker.vendas) / max) * 100;
          return (
            <div
              key={`${broker.nome}-${index}`}
              className="group flex items-center gap-3 rounded-xl border border-white/5 bg-white/[0.02] p-3 transition hover:bg-white/[0.04]"
            >
              <div
                className={`grid h-9 w-9 place-items-center rounded-lg text-xs font-bold ${index === 0 ? "bg-gradient-to-br from-copper to-wine text-white shadow-[0_0_20px_var(--copper)]" : "border border-white/5 bg-white/[0.03] text-muted-foreground"}`}
              >
                {index + 1}
              </div>
              <div className="min-w-0 flex-1">
                <div className="flex items-center gap-2">
                  <div className="truncate text-sm font-medium text-foreground">{broker.nome}</div>
                  {broker.tier && (
                    <span className="rounded-full border border-white/5 bg-white/[0.03] px-2 py-0.5 text-[9px] uppercase tracking-wider text-muted-foreground">
                      {broker.tier}
                    </span>
                  )}
                </div>
                <div className="mt-1.5 h-1 overflow-hidden rounded-full bg-white/[0.04]">
                  <div
                    className="h-full rounded-full"
                    style={{
                      width: `${pct}%`,
                      background:
                        "linear-gradient(90deg, oklch(0.60 0.22 25), oklch(0.30 0.18 22))",
                    }}
                  />
                </div>
              </div>
              <div className="text-right">
                {showRevenue && (
                  <div className="text-sm font-semibold tabular-nums text-foreground">
                    {broker.faturamento.toLocaleString("pt-BR", {
                      style: "currency",
                      currency: "BRL",
                      maximumFractionDigits: 0,
                    })}
                  </div>
                )}
                <div className="text-[10px] text-muted-foreground">{broker.vendas} negócios</div>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

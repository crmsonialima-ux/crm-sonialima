import { Pie, PieChart, Cell, Legend, ResponsiveContainer, Tooltip } from "recharts";
import { useEffect, useId, useMemo } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/lib/supabase";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";

type CaptureRankingRow = {
  broker_id: string;
  broker_name: string;
  broker_email: string;
  property_id: string | null;
  cadastrado_em: string | null;
  event_date: string | null;
  event_kind: "capture" | "sale" | null;
  titulo: string | null;
  endereco: string | null;
  valor: number | string | null;
  status: string | null;
  classificacao: string | null;
  sold_from_daily: boolean | null;
};
type CaptureItem = {
  id: string;
  brokerId: string;
  capturer: string;
  cadastradoEm?: string;
  eventDate?: string;
  eventKind?: "capture" | "sale";
  titulo: string;
  endereco?: string;
  valor?: number;
  status?: string;
  source: "Imóveis" | "Relatório de vendas";
  points: number;
  category: string;
};
type Score = {
  id: string;
  name: string;
  sold: number;
  exclusive: number;
  nonExclusive: number;
  noAuthorization: number;
  pending: number;
  points: number;
  captured: number;
};

const COLORS = ["#ef4444", "#3b82f6", "#22c55e", "#f59e0b", "#a855f7", "#14b8a6", "#f97316"];

function normalized(value?: string) {
  return String(value ?? "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .trim()
    .toLocaleLowerCase("pt-BR");
}

function scoreFor(soldFromDaily: boolean, classificationValue?: string | null) {
  const exclusivity = normalized(classificationValue ?? undefined);

  // A venda confirmada no Relatório de vendas tem prioridade: ela concede
  // dez pontos ao captador escolhido, mesmo que a classificação do imóvel
  // ainda esteja pendente. O status isolado do catálogo nunca pontua como venda.
  if (soldFromDaily) return { points: 10, category: "Vendido" };

  // Para imóveis que ainda não possuem venda lançada, a classificação de
  // Administrador determina 7, 5, 3 ou permanece pendente em zero.
  if (!exclusivity) return { points: 0, category: "Aguardando resposta de Administrador" };
  if (exclusivity.includes("com exclusividade"))
    return { points: 7, category: "Com exclusividade" };
  if (exclusivity.includes("sem exclusividade"))
    return { points: 5, category: "Sem exclusividade" };
  if (exclusivity.includes("sem autorizacao"))
    return { points: 3, category: "Sem autorização de venda" };
  return { points: 0, category: "Aguardando resposta de Administrador" };
}

function formatDate(value?: string) {
  if (!value) return "—";
  const date = new Date(/^\d{4}-\d{2}-\d{2}$/.test(value) ? `${value}T12:00:00` : value);
  return Number.isNaN(date.getTime()) ? value : date.toLocaleDateString("pt-BR");
}

export function CaptureRanking() {
  const queryClient = useQueryClient();
  const subscriptionId = useId();
  const rankingYear = new Date().getFullYear();
  const rows = useQuery({
    queryKey: ["capture-ranking-rows", "annual", rankingYear],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("get_capture_ranking_rows");
      if (error) throw error;
      return (data ?? []) as CaptureRankingRow[];
    },
    refetchOnWindowFocus: true,
    refetchInterval: 15_000,
    staleTime: 60_000,
  });

  useEffect(() => {
    const refresh = () =>
      void queryClient.invalidateQueries({ queryKey: ["capture-ranking-rows"] });
    const channel = supabase
      .channel(`capture-ranking-live:${subscriptionId}`)
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "crm_sales" },
        refresh,
      )
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
      .subscribe();
    return () => {
      void supabase.removeChannel(channel);
    };
  }, [queryClient, subscriptionId]);

  const { ranking, captures } = useMemo(() => {
    const scores = new Map<string, Score>();
    const items: CaptureItem[] = [];
    const soldPropertyKeys = new Set<string>();
    const capturersCount = new Map<string, number>();

    for (const row of rows.data ?? []) {
      if (row.property_id) {
        const eventKey = `${row.property_id}_${row.event_kind}`;
        capturersCount.set(eventKey, (capturersCount.get(eventKey) || 0) + 1);
      }
      
      if (!scores.has(row.broker_id)) {
        scores.set(row.broker_id, {
          id: row.broker_id,
          name: row.broker_name || row.broker_email,
          sold: 0,
          exclusive: 0,
          nonExclusive: 0,
          noAuthorization: 0,
          pending: 0,
          points: 0,
          captured: 0,
        });
      }
    }

    for (const row of rows.data ?? []) {
      if (!row.property_id) continue;
      const isSale = row.event_kind === "sale" && Boolean(row.sold_from_daily);

      // Defesa adicional: garante que o mesmo corretor não receba 10 pontos
      // duas vezes para o mesmo imóvel se houver registros duplicados.
      if (isSale) {
        const saleKey = `${row.property_id}_${row.broker_id}`;
        if (soldPropertyKeys.has(saleKey)) continue;
        soldPropertyKeys.add(saleKey);
      }

      const eventKey = `${row.property_id}_${row.event_kind}`;
      const count = capturersCount.get(eventKey) || 1;

      const current = scores.get(row.broker_id)!;
      const scored = scoreFor(isSale, row.classificacao);
      const pointsToAward = scored.points / count;
      
      current.points += pointsToAward;
      current.captured += 1;
      if (scored.category === "Vendido") current.sold += 1;
      else if (scored.category === "Com exclusividade") current.exclusive += 1;
      else if (scored.category === "Sem exclusividade") current.nonExclusive += 1;
      else if (scored.category === "Sem autorização de venda") current.noAuthorization += 1;
      else current.pending += 1;
      
      items.push({
        id: row.property_id,
        brokerId: row.broker_id,
        capturer: row.broker_name || row.broker_email,
        cadastradoEm: row.cadastrado_em ?? undefined,
        eventDate: row.event_date ?? undefined,
        eventKind: row.event_kind ?? undefined,
        titulo: row.titulo || row.endereco || "",
        endereco: row.endereco ?? undefined,
        valor: row.valor == null ? undefined : Number(row.valor),
        status: row.status ?? undefined,
        source: row.sold_from_daily ? "Relatório de vendas" : "Imóveis",
        category: scored.category,
        points: pointsToAward,
      });
    }
    return {
      ranking: [...scores.values()].sort(
        (a, b) => b.points - a.points || a.name.localeCompare(b.name, "pt-BR"),
      ),
      captures: items.sort((a, b) =>
        String(b.eventDate ?? "").localeCompare(String(a.eventDate ?? "")),
      ),
    };
  }, [rows.data]);

  if (rows.isLoading)
    return (
      <div className="grid gap-3 lg:grid-cols-2">
        <div className="skeleton h-72 rounded-xl" />
        <div className="skeleton h-72 rounded-xl" />
      </div>
    );
  if (rows.isError)
    return (
      <div className="rounded-xl border border-destructive/30 bg-destructive/5 p-5 text-sm text-muted-foreground">
        O ranking de captação está temporariamente indisponível. Os demais dados da Dashboard
        continuam disponíveis.
      </div>
    );
  const donut = ranking
    .filter((item) => item.points > 0)
    .map((item) => ({ name: item.name, value: item.points }));
  return (
    <Tabs defaultValue="geral">
      <div className="mb-4 rounded-xl border border-white/8 bg-white/[0.02] px-4 py-2.5 text-center">
        <p className="text-[10px] uppercase tracking-[0.18em] text-muted-foreground">
          Pontuação anual de captação
        </p>
        <p className="mt-0.5 text-sm font-semibold text-foreground">Ano de {rankingYear}</p>
      </div>
      <TabsList className="mb-4 h-auto flex-wrap justify-start gap-1 bg-white/[0.04]">
        <TabsTrigger value="geral">Ranking geral</TabsTrigger>
        <TabsTrigger value="imoveis">Imóveis captados</TabsTrigger>
        <TabsTrigger value="pontos">Pontuação</TabsTrigger>
      </TabsList>
      <TabsContent value="geral" className="mt-0 grid gap-5 xl:grid-cols-[1.15fr_.85fr]">
        <div className="space-y-2">
          {ranking.map((broker, index) => {
            const max = Math.max(...ranking.map((item) => item.points), 1);
            return (
              <div
                key={broker.id}
                className="flex items-center gap-3 rounded-xl border border-white/8 bg-white/[0.02] p-3"
              >
                <span
                  className={`grid h-9 w-9 place-items-center rounded-lg text-sm font-bold ${index === 0 ? "bg-copper text-white" : "bg-white/[0.05] text-muted-foreground"}`}
                >
                  {index + 1}
                </span>
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-medium">{broker.name}</p>
                  <div className="mt-1.5 h-1.5 overflow-hidden rounded-full bg-white/[0.06]">
                    <div
                      className="h-full rounded-full"
                      style={{
                        width: `${(broker.points / max) * 100}%`,
                        backgroundColor: COLORS[index % COLORS.length],
                      }}
                    />
                  </div>
                </div>
                <div className="text-right">
                  <p className="font-semibold tabular-nums">{broker.points.toLocaleString("pt-BR")} pts</p>
                  <p className="text-[10px] text-muted-foreground">{broker.captured} imóveis</p>
                </div>
              </div>
            );
          })}
        </div>
        <div className="min-h-72 rounded-xl border border-white/8 bg-white/[0.02] p-3">
          <p className="text-sm font-medium">Distribuição de pontos</p>
          <ResponsiveContainer width="100%" height={255}>
            <PieChart>
              <Pie
                data={donut}
                dataKey="value"
                nameKey="name"
                innerRadius={58}
                outerRadius={88}
                paddingAngle={3}
              >
                {donut.map((_, index) => (
                  <Cell key={index} fill={COLORS[index % COLORS.length]} />
                ))}
              </Pie>
              <Tooltip formatter={(value) => [`${Number(value).toLocaleString("pt-BR")} pontos`, "Pontuação"]} />
              <Legend />
            </PieChart>
          </ResponsiveContainer>
        </div>
      </TabsContent>
      <TabsContent
        value="imoveis"
        className="mt-0 overflow-x-auto rounded-xl border border-white/8"
      >
        <table className="w-full min-w-[1160px] text-sm">
          <thead className="bg-white/[0.03] text-left text-xs text-muted-foreground">
            <tr>
              <th className="p-3">Data da pontuação</th>
              <th className="p-3">Cadastro</th>
              <th className="p-3">Captador</th>
              <th className="p-3">Endereço</th>
              <th className="p-3">Valor</th>
              <th className="p-3">Status</th>
              <th className="p-3">Autorização</th>
              <th className="p-3">Fonte dos pontos</th>
              <th className="p-3 text-right">Pontos</th>
            </tr>
          </thead>
          <tbody>
            {captures.map((item) => (
              <tr key={`${item.id}-${item.brokerId}`} className="border-t border-white/6">
                <td className="p-3 text-muted-foreground">{formatDate(item.eventDate)}</td>
                <td className="p-3 text-muted-foreground">{formatDate(item.cadastradoEm)}</td>
                <td className="p-3 font-medium">{item.capturer}</td>
                <td className="p-3">{item.titulo || item.endereco || "—"}</td>
                <td className="p-3">
                  {item.valor
                    ? item.valor.toLocaleString("pt-BR", {
                        style: "currency",
                        currency: "BRL",
                        maximumFractionDigits: 0,
                      })
                    : "—"}
                </td>
                <td className="p-3">{item.status || "—"}</td>
                <td className="p-3">{item.category}</td>
                <td className="p-3 text-muted-foreground">{item.source}</td>
                <td className="p-3 text-right font-semibold text-copper">{item.points.toLocaleString("pt-BR")}</td>
              </tr>
            ))}
          </tbody>
        </table>
        {captures.length === 0 && (
          <p className="p-8 text-center text-sm text-muted-foreground">
            Nenhum imóvel pontuado neste ano.
          </p>
        )}
      </TabsContent>
      <TabsContent value="pontos" className="mt-0 overflow-x-auto rounded-xl border border-white/8">
        <table className="w-full min-w-[760px] text-sm">
          <thead className="bg-white/[0.03] text-left text-xs text-muted-foreground">
            <tr>
              <th className="p-3">Corretor</th>
              <th className="p-3 text-center">Vendidos · 10</th>
              <th className="p-3 text-center">Exclusividade · 7</th>
              <th className="p-3 text-center">Sem exclusividade · 5</th>
              <th className="p-3 text-center">Sem autorização · 3</th>
              <th className="p-3 text-right">Total</th>
            </tr>
          </thead>
          <tbody>
            {ranking.map((broker) => (
              <tr key={broker.id} className="border-t border-white/6">
                <td className="p-3 font-medium">{broker.name}</td>
                <td className="p-3 text-center">{broker.sold}</td>
                <td className="p-3 text-center">{broker.exclusive}</td>
                <td className="p-3 text-center">{broker.nonExclusive}</td>
                <td className="p-3 text-center">{broker.noAuthorization}</td>
                <td className="p-3 text-right font-semibold text-copper">{broker.points.toLocaleString("pt-BR")} pts</td>
              </tr>
            ))}
          </tbody>
        </table>
      </TabsContent>
    </Tabs>
  );
}

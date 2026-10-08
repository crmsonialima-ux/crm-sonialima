import { Download } from "lucide-react";
import { useMemo, useState } from "react";
import { Button } from "@/components/ui/button";
import { Panel } from "@/components/dashboard/Panel";
import { brokersFromDashboard } from "@/lib/brokers";
import { propertiesFromDashboard } from "@/lib/properties";
import type { DashboardData } from "@/lib/api";

type Report = "vendas" | "locacoes" | "corretores" | "imoveis" | "financeiro";
type Dataset = { title: string; columns: string[]; rows: Array<Array<string | number>> };
const reports: Array<{ id: Report; label: string }> = [
  { id: "vendas", label: "Vendas" },
  { id: "locacoes", label: "Locações" },
  { id: "corretores", label: "Corretores" },
  { id: "imoveis", label: "Imóveis" },
  { id: "financeiro", label: "Financeiro" },
];
const currency = (value: number) =>
  value.toLocaleString("pt-BR", { style: "currency", currency: "BRL", maximumFractionDigits: 0 });

export function ReportsManager({
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
  const [active, setActive] = useState<Report>("vendas");
  const dataset = useMemo(() => createDataset(active, data), [active, data]);
  const downloadCsv = () => {
    const csv = [dataset.columns, ...dataset.rows]
      .map((row) => row.map((cell) => `"${String(cell).replaceAll('"', '""')}"`).join(";"))
      .join("\r\n");
    const link = document.createElement("a");
    link.href = URL.createObjectURL(new Blob(["\ufeff", csv], { type: "text/csv;charset=utf-8" }));
    link.download = `${dataset.title}.csv`;
    link.click();
    URL.revokeObjectURL(link.href);
  };
  return (
    <>
      <section className="mb-8 flex flex-wrap items-end justify-between gap-4">
        <div>
          <p className="text-[11px] uppercase tracking-[0.24em] text-muted-foreground">
            Análise operacional
          </p>
          <h1 className="mt-2 text-3xl font-semibold">Relatórios</h1>
        </div>
        <Button variant="outline" onClick={downloadCsv}>
          <Download size={16} /> CSV
        </Button>
      </section>
      {error ? (
        <Panel title="Relatórios">
          <p className="py-8 text-center text-muted-foreground">
            Não foi possível carregar os relatórios.
            <br />
            <Button className="mt-3" variant="outline" onClick={retry}>
              Tentar novamente
            </Button>
          </p>
        </Panel>
      ) : (
        <Panel title={dataset.title} subtitle={`${dataset.rows.length} registros disponíveis`}>
          <div className="mb-5 flex flex-wrap gap-2">
            {reports.map((report) => (
              <button
                key={report.id}
                onClick={() => setActive(report.id)}
                className={`rounded-lg border px-3 py-2 text-xs ${active === report.id ? "border-copper/40 bg-copper/10 text-copper" : "border-white/10 text-muted-foreground"}`}
              >
                {report.label}
              </button>
            ))}
          </div>

          <div className="space-y-3 lg:hidden">
            {loading ? (
              Array.from({ length: 4 }).map((_, index) => (
                <div key={index} className="rounded-xl border border-white/5 p-4">
                  <div className="skeleton h-5 w-1/2" />
                  <div className="skeleton mt-3 h-4 w-full" />
                  <div className="skeleton mt-2 h-4 w-3/4" />
                </div>
              ))
            ) : dataset.rows.length === 0 ? (
              <div className="rounded-xl border border-white/5 px-4 py-8 text-center text-sm text-muted-foreground">
                Nenhum registro disponível neste relatório.
              </div>
            ) : (
              dataset.rows.map((row, rowIndex) => (
                <article
                  key={rowIndex}
                  className="rounded-xl border border-white/5 bg-white/[0.02] p-4"
                >
                  <dl className="grid grid-cols-2 gap-x-3 gap-y-4 text-xs">
                    {dataset.columns.map((column, columnIndex) => (
                      <div
                        key={column}
                        className={`min-w-0 ${columnIndex === 0 ? "col-span-2" : ""}`}
                      >
                        <dt className="text-[10px] uppercase tracking-wider text-muted-foreground">
                          {column}
                        </dt>
                        <dd className="mt-1 break-words font-medium text-foreground">
                          {row[columnIndex]}
                        </dd>
                      </div>
                    ))}
                  </dl>
                </article>
              ))
            )}
          </div>

          <div className="hidden overflow-x-auto lg:block">
            <table className="w-full min-w-[720px] text-sm">
              <thead>
                <tr className="text-left text-xs text-muted-foreground">
                  {dataset.columns.map((column) => (
                    <th key={column} className="px-3 py-3">
                      {column}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {loading ? (
                  <tr>
                    <td
                      colSpan={dataset.columns.length}
                      className="px-3 py-8 text-center text-muted-foreground"
                    >
                      Carregando…
                    </td>
                  </tr>
                ) : (
                  dataset.rows.map((row, index) => (
                    <tr key={index} className="border-t border-white/5">
                      {row.map((cell, cellIndex) => (
                        <td key={cellIndex} className="px-3 py-3">
                          {cell}
                        </td>
                      ))}
                    </tr>
                  ))
                )}
              </tbody>
            </table>
          </div>
        </Panel>
      )}
    </>
  );
}

function createDataset(report: Report, data?: DashboardData): Dataset {
  const leads = data?.leads ?? [];
  if (report === "vendas" || report === "locacoes") {
    const rental = report === "locacoes";
    return {
      title: rental ? "Relatório de locações" : "Relatório de vendas",
      columns: ["Lead", "Imóvel", "Corretor", "Faturamento"],
      rows: leads
        .filter(
          (lead) =>
            lead.estagio === "Fechado" &&
            (lead.tipoInteresse === "Locação" || lead.tipoInteresse === "Aluguel de imóvel") ===
              rental,
        )
        .map((lead) => [
          lead.nome,
          lead.imovel ?? "—",
          lead.corretor ?? "—",
          currency(lead.comissaoImb ?? 0),
        ]),
    };
  }
  if (report === "corretores")
    return {
      title: "Relatório de corretores",
      columns: ["Corretor", "Leads", "Vendas", "Faturamento"],
      rows: brokersFromDashboard(data).map((broker) => [
        broker.name,
        broker.leads,
        broker.sales,
        currency(broker.revenue),
      ]),
    };
  if (report === "imoveis")
    return {
      title: "Relatório de imóveis",
      columns: ["Imóvel", "Corretor", "Valor", "Status"],
      rows: propertiesFromDashboard(data).map((property) => [
        property.title,
        property.broker ?? "—",
        property.value ? currency(property.value) : "—",
        property.status ?? "—",
      ]),
    };
  return {
    title: "Relatório financeiro",
    columns: ["Mês", "Vendas", "Locações", "Total"],
    rows: (data?.receita ?? []).map((item) => [
      item.m,
      currency(item.vendas),
      currency(item.locacoes),
      currency(item.vendas + item.locacoes),
    ]),
  };
}

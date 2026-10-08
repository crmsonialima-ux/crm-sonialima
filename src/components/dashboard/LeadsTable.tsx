import { ArrowUpDown, Download, Filter, Search } from "lucide-react";
import { useMemo, useState } from "react";
import type { LeadRow } from "@/lib/api";

const stageColors: Record<string, string> = {
  Lead: "text-slate-300 bg-slate-300/10",
  Contato: "text-sky-300 bg-sky-300/10",
  Qualificado: "text-violet-300 bg-violet-300/10",
  Visita: "text-amber-300 bg-amber-300/10",
  Proposta: "text-amber-700 bg-amber-300/10 dark:text-amber-200",
  Fechamento: "text-emerald-300 bg-emerald-300/10",
};

export function LeadsTable({ data }: { data?: LeadRow[] }) {
  const [q, setQ] = useState("");
  const [sortDesc, setSortDesc] = useState(true);
  const [page, setPage] = useState(1);
  const perPage = 6;

  const filtered = useMemo(() => {
    const src = data ?? [];
    const term = q.toLowerCase();
    const f = src.filter(
      (l) => l.nome.toLowerCase().includes(term) || (l.imovel ?? "").toLowerCase().includes(term),
    );
    return [...f].sort((a, b) => (sortDesc ? b.valor - a.valor : a.valor - b.valor));
  }, [q, sortDesc, data]);

  const pages = Math.max(1, Math.ceil(filtered.length / perPage));
  const rows = filtered.slice((page - 1) * perPage, page * perPage);
  const loading = !data;

  return (
    <div>
      <div className="mb-4 flex flex-wrap items-center gap-2">
        <div className="relative flex-1 min-w-[220px]">
          <Search
            size={14}
            className="absolute left-3 top-1/2 -translate-y-1/2 text-muted-foreground"
          />
          <input
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="Buscar lead ou imóvel..."
            className="w-full rounded-lg border border-white/5 bg-white/[0.02] py-2 pl-9 pr-3 text-xs outline-none transition focus:border-copper/40"
          />
        </div>
        <button className="flex items-center gap-1.5 rounded-lg border border-white/5 bg-white/[0.02] px-3 py-2 text-xs text-muted-foreground transition hover:bg-white/[0.05] hover:text-foreground">
          <Filter size={13} />
          Filtros
        </button>
        <button
          onClick={() => setSortDesc((value) => !value)}
          className="flex items-center gap-1.5 rounded-lg border border-white/5 bg-white/[0.02] px-3 py-2 text-xs text-muted-foreground transition hover:bg-white/[0.05] hover:text-foreground lg:hidden"
        >
          <ArrowUpDown size={13} />
          Valor
        </button>
        <div className="flex items-center gap-1 rounded-lg border border-white/5 bg-white/[0.02] p-1">
          {["Excel", "CSV", "PDF"].map((f) => (
            <button
              key={f}
              className="flex items-center gap-1 rounded-md px-2 py-1 text-[10px] font-medium text-muted-foreground transition hover:bg-white/[0.05] hover:text-foreground"
            >
              <Download size={11} />
              {f}
            </button>
          ))}
        </div>
      </div>

      <div className="space-y-3 lg:hidden">
        {loading ? (
          Array.from({ length: 4 }).map((_, index) => (
            <div key={index} className="rounded-xl border border-white/5 p-4">
              <div className="skeleton h-5 w-2/3" />
              <div className="skeleton mt-3 h-4 w-full" />
              <div className="skeleton mt-2 h-4 w-4/5" />
            </div>
          ))
        ) : rows.length === 0 ? (
          <div className="rounded-xl border border-white/5 px-4 py-10 text-center text-xs text-muted-foreground">
            Nenhum lead disponível.
          </div>
        ) : (
          rows.map((lead, index) => (
            <article
              key={lead.id ?? `${lead.nome}-${index}`}
              className="rounded-xl border border-white/5 bg-white/[0.02] p-4"
            >
              <div className="flex min-w-0 items-start justify-between gap-3">
                <div className="min-w-0">
                  <h3 className="break-words font-medium text-foreground">{lead.nome}</h3>
                  <p className="mt-0.5 break-all font-mono text-[10px] text-muted-foreground">
                    {lead.id ?? `L-${String(index + 1).padStart(4, "0")}`}
                  </p>
                </div>
                <span
                  className={`shrink-0 rounded-full px-2 py-1 text-[10px] font-medium ${stageColors[lead.estagio] ?? "text-slate-300 bg-slate-300/10"}`}
                >
                  {lead.estagio}
                </span>
              </div>
              <dl className="mt-4 grid grid-cols-2 gap-x-3 gap-y-3 text-xs">
                <MobileDashboardLeadDetail label="Imóvel" value={lead.imovel ?? "—"} wide />
                <MobileDashboardLeadDetail label="Canal" value={lead.canal ?? "—"} />
                <MobileDashboardLeadDetail
                  label="Valor"
                  value={`R$ ${(lead.valor / 1000).toLocaleString("pt-BR")}k`}
                />
                <MobileDashboardLeadDetail
                  label="Atualizado"
                  value={lead.atualizadoEm ?? "—"}
                  wide
                />
              </dl>
            </article>
          ))
        )}
      </div>

      <div className="hidden overflow-hidden rounded-xl border border-white/5 lg:block">
        <table className="w-full text-sm">
          <thead>
            <tr className="bg-white/[0.02] text-[10px] uppercase tracking-wider text-muted-foreground">
              <th className="px-4 py-3 text-left font-medium">ID</th>
              <th className="px-4 py-3 text-left font-medium">Cliente</th>
              <th className="px-4 py-3 text-left font-medium">Imóvel</th>
              <th className="px-4 py-3 text-left font-medium">Estágio</th>
              <th className="px-4 py-3 text-left font-medium">Canal</th>
              <th className="px-4 py-3 text-right font-medium">
                <button
                  onClick={() => setSortDesc((s) => !s)}
                  className="inline-flex items-center gap-1 hover:text-foreground"
                >
                  Valor <ArrowUpDown size={11} />
                </button>
              </th>
              <th className="px-4 py-3 text-right font-medium">Atualizado</th>
            </tr>
          </thead>
          <tbody>
            {loading ? (
              Array.from({ length: 6 }).map((_, i) => (
                <tr key={i} className="border-t border-white/5">
                  {Array.from({ length: 7 }).map((__, j) => (
                    <td key={j} className="px-4 py-3">
                      <div className="skeleton h-4 w-full rounded" />
                    </td>
                  ))}
                </tr>
              ))
            ) : rows.length === 0 ? (
              <tr>
                <td colSpan={7} className="px-4 py-10 text-center text-xs text-muted-foreground">
                  Nenhum lead disponível.
                </td>
              </tr>
            ) : (
              rows.map((l, i) => (
                <tr
                  key={l.id ?? `${l.nome}-${i}`}
                  className="border-t border-white/5 transition hover:bg-white/[0.02]"
                >
                  <td className="px-4 py-3 font-mono text-[11px] text-muted-foreground">
                    {l.id ?? `L-${String(i + 1).padStart(4, "0")}`}
                  </td>
                  <td className="px-4 py-3 font-medium text-foreground">{l.nome}</td>
                  <td className="px-4 py-3 text-muted-foreground">{l.imovel ?? "—"}</td>
                  <td className="px-4 py-3">
                    <span
                      className={`rounded-full px-2 py-0.5 text-[10px] font-medium ${stageColors[l.estagio] ?? "text-slate-300 bg-slate-300/10"}`}
                    >
                      {l.estagio}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-xs text-muted-foreground">{l.canal ?? "—"}</td>
                  <td className="px-4 py-3 text-right font-semibold tabular-nums">
                    R$ {(l.valor / 1000).toLocaleString("pt-BR")}k
                  </td>
                  <td className="px-4 py-3 text-right text-xs text-muted-foreground">
                    {l.atualizadoEm ?? "—"}
                  </td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>

      <div className="mt-3 flex items-center justify-between text-xs text-muted-foreground">
        <span>{filtered.length} resultados</span>
        <div className="flex items-center gap-1 lg:hidden">
          <button
            onClick={() => setPage((value) => Math.max(1, value - 1))}
            disabled={page === 1}
            className="rounded-md px-2 py-1.5 transition hover:bg-white/[0.04] disabled:opacity-40"
          >
            Anterior
          </button>
          <span className="px-1 tabular-nums">
            {page}/{pages}
          </span>
          <button
            onClick={() => setPage((value) => Math.min(pages, value + 1))}
            disabled={page === pages}
            className="rounded-md px-2 py-1.5 transition hover:bg-white/[0.04] disabled:opacity-40"
          >
            Próxima
          </button>
        </div>
        <div className="hidden items-center gap-1 md:flex">
          {Array.from({ length: pages }).map((_, i) => (
            <button
              key={i}
              onClick={() => setPage(i + 1)}
              className={`h-7 min-w-[28px] rounded-md px-2 text-xs transition ${page === i + 1 ? "bg-white/[0.08] text-foreground" : "hover:bg-white/[0.04]"}`}
            >
              {i + 1}
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}

function MobileDashboardLeadDetail({
  label,
  value,
  wide = false,
}: {
  label: string;
  value: string;
  wide?: boolean;
}) {
  return (
    <div className={`min-w-0 ${wide ? "col-span-2" : ""}`}>
      <dt className="text-[10px] uppercase tracking-wider text-muted-foreground">{label}</dt>
      <dd className="mt-1 break-words font-medium text-foreground">{value}</dd>
    </div>
  );
}

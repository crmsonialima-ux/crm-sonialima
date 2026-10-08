import type { FunnelPoint } from "@/lib/api";

export function Funnel({ data }: { data?: FunnelPoint[] }) {
  if (!data || data.length === 0) {
    return (
      <div className="space-y-2.5">
        {Array.from({ length: 5 }).map((_, i) => (
          <div key={i} className="skeleton h-10 w-full rounded-lg" />
        ))}
      </div>
    );
  }
  const max = Math.max(...data.map((s) => s.v), 1);
  return (
    <div className="space-y-2.5">
      {data.map((s, i) => {
        const pct = (s.v / max) * 100;
        const prev = i === 0 ? s.v : data[i - 1].v;
        const conv = prev > 0 ? (s.v / prev) * 100 : 0;
        return (
          <div key={s.stage} className="group">
            <div className="mb-1 flex items-center justify-between text-xs">
              <div className="flex items-center gap-2">
                <span className="text-muted-foreground">{String(i + 1).padStart(2, "0")}</span>
                <span className="font-medium text-foreground">{s.stage}</span>
              </div>
              <div className="flex items-center gap-3 tabular-nums">
                <span className="text-muted-foreground">{conv.toFixed(0)}%</span>
                <span className="font-semibold text-foreground">{s.v.toLocaleString("pt-BR")}</span>
              </div>
            </div>
            <div className="relative h-8 overflow-hidden rounded-lg border border-white/5 bg-white/[0.02]">
              <div
                className="h-full rounded-lg transition-all duration-1000 ease-out"
                style={{
                  width: `${pct}%`,
                  background: "linear-gradient(90deg, oklch(0.60 0.22 25), oklch(0.30 0.18 22))",
                  boxShadow: "inset 0 1px 0 oklch(1 0 0 / 0.1), 0 0 20px oklch(0.55 0.22 25 / 0.2)",
                }}
              />
            </div>
          </div>
        );
      })}
    </div>
  );
}
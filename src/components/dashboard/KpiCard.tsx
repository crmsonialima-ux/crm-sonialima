import { useCountUp, formatNumber, formatCurrency } from "@/lib/use-count-up";
import { Eye, EyeOff, TrendingDown, TrendingUp, type LucideIcon } from "lucide-react";

type Props = {
  label: string;
  value: number;
  delta: number;
  format?: "number" | "currency" | "percent" | "time";
  suffix?: string;
  icon: LucideIcon;
  loading?: boolean;
  valueHidden?: boolean;
  onToggleValueVisibility?: () => void;
};

export function KpiCard({
  label,
  value,
  delta,
  format = "number",
  suffix,
  icon: Icon,
  loading,
  valueHidden = false,
  onToggleValueVisibility,
}: Props) {
  const decimals = format === "percent" ? 1 : 0;
  const n = useCountUp(loading ? 0 : value, 1400, decimals);
  const up = delta >= 0;

  const display =
    format === "currency"
      ? formatCurrency(n)
      : format === "percent"
        ? `${n.toFixed(1)}%`
        : format === "time"
          ? `${Math.round(n)} dias`
          : `${formatNumber(n)}${suffix ?? ""}`;

  return (
    <div className="group glass anim-float-in relative overflow-hidden rounded-2xl p-4 transition-all duration-500 hover:-translate-y-0.5 hover:glow-copper sm:p-5">
      <div
        className="pointer-events-none absolute -right-16 -top-16 h-40 w-40 rounded-full opacity-0 blur-2xl transition-opacity duration-500 group-hover:opacity-100"
        style={{ background: "var(--gradient-copper)" }}
      />
      <div className="relative flex items-start justify-between">
        <div className="grid h-10 w-10 place-items-center rounded-xl border border-white/5 bg-white/[0.03] text-copper">
          <Icon size={17} strokeWidth={1.75} />
        </div>
        <div className="flex items-center gap-1.5">
          {onToggleValueVisibility ? (
            <button
              type="button"
              onClick={onToggleValueVisibility}
              aria-label={valueHidden ? `Exibir ${label}` : `Ocultar ${label}`}
              title={valueHidden ? "Exibir valor" : "Ocultar valor"}
              className="grid h-7 w-7 place-items-center rounded-full border border-white/10 bg-white/[0.03] text-muted-foreground transition hover:border-copper/50 hover:text-copper"
            >
              {valueHidden ? <EyeOff size={14} /> : <Eye size={14} />}
            </button>
          ) : null}
          <div
            className={`flex items-center gap-1 rounded-full border px-2 py-0.5 text-[10px] font-semibold ${up ? "border-emerald-400/20 bg-emerald-400/5 text-emerald-300" : "border-rose-400/20 bg-rose-400/5 text-rose-300"}`}
          >
            {up ? <TrendingUp size={11} /> : <TrendingDown size={11} />}
            {up ? "+" : ""}
            {delta.toFixed(1)}%
          </div>
        </div>
      </div>
      <div className="mt-6">
        <div className="text-[11px] uppercase tracking-[0.18em] text-muted-foreground">{label}</div>
        {loading ? (
          <div className="skeleton mt-2 h-8 w-32" />
        ) : (
          <div
            className="mt-1.5 font-semibold tracking-tight text-foreground"
            style={{ fontSize: "1.7rem", lineHeight: 1.1 }}
          >
            {valueHidden ? "••••••" : display}
          </div>
        )}
      </div>
      <div className="pointer-events-none absolute inset-x-0 bottom-0 h-px bg-gradient-to-r from-transparent via-copper/40 to-transparent opacity-0 transition-opacity duration-500 group-hover:opacity-100" />
    </div>
  );
}

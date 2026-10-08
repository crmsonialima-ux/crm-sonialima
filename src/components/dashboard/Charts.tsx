import { useId } from "react";
import {
  Bar,
  BarChart,
  CartesianGrid,
  Cell,
  Legend,
  Line,
  LineChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
  Pie,
  PieChart,
} from "recharts";
import type { ChannelPoint, ConversionPoint, PortfolioPoint, RevenuePoint } from "@/lib/api";

const tooltipStyle = {
  background: "var(--popover)",
  border: "1px solid var(--border)",
  borderRadius: 12,
  fontSize: 12,
  padding: "8px 12px",
  boxShadow: "var(--shadow-card)",
  color: "var(--popover-foreground)",
};

function EmptyChart({
  height = 240,
  label = "Aguardando dados da planilha…",
}: {
  height?: number;
  label?: string;
}) {
  return (
    <div
      className="skeleton flex w-full items-center justify-center rounded-xl text-[11px] text-muted-foreground"
      style={{ height }}
    >
      {label}
    </div>
  );
}

export function RevenueArea({ data }: { data?: RevenuePoint[] }) {
  if (!data || data.length === 0) return <EmptyChart height={280} />;
  return (
    <ResponsiveContainer width="100%" height={280}>
      <LineChart data={data} margin={{ top: 14, right: 20, left: 10, bottom: 0 }}>
        <CartesianGrid strokeDasharray="3 6" stroke="var(--border)" />
        <XAxis
          dataKey="m"
          stroke="var(--muted-foreground)"
          fontSize={11}
          tickLine={false}
          axisLine={false}
        />
        <YAxis
          stroke="var(--muted-foreground)"
          fontSize={11}
          tickLine={false}
          axisLine={false}
          tickFormatter={(value) =>
            value >= 1_000_000
              ? `R$ ${(value / 1_000_000).toFixed(1)}M`
              : `R$ ${(value / 1_000).toFixed(0)}k`
          }
        />
        <Tooltip
          contentStyle={tooltipStyle}
          formatter={(value) =>
            Number(value).toLocaleString("pt-BR", { style: "currency", currency: "BRL" })
          }
        />
        <Legend
          formatter={(value) => (
            <span style={{ color: "var(--muted-foreground)", fontSize: 11 }}>{value}</span>
          )}
        />
        <Line
          name="Vendas"
          type="monotone"
          dataKey="vendas"
          stroke="oklch(0.68 0.22 25)"
          strokeWidth={3}
          dot={{ r: 4, fill: "oklch(0.68 0.22 25)" }}
          activeDot={{ r: 6 }}
          animationDuration={1400}
        />
        <Line
          name="Locações"
          type="monotone"
          dataKey="locacoes"
          stroke="oklch(0.62 0.16 145)"
          strokeWidth={3}
          dot={{ r: 4, fill: "oklch(0.62 0.16 145)" }}
          activeDot={{ r: 6 }}
          animationDuration={1600}
        />
      </LineChart>
    </ResponsiveContainer>
  );
}

export function ConversionLine({ data }: { data?: ConversionPoint[] }) {
  if (!data || data.length === 0) return <EmptyChart height={200} />;
  return (
    <ResponsiveContainer width="100%" height={200}>
      <LineChart data={data} margin={{ top: 10, right: 8, left: -20, bottom: 0 }}>
        <CartesianGrid strokeDasharray="3 6" stroke="var(--border)" />
        <XAxis
          dataKey="m"
          stroke="var(--muted-foreground)"
          fontSize={11}
          tickLine={false}
          axisLine={false}
        />
        <YAxis
          stroke="var(--muted-foreground)"
          fontSize={11}
          tickLine={false}
          axisLine={false}
          tickFormatter={(v) => `${v}%`}
        />
        <Tooltip contentStyle={tooltipStyle} />
        <Line
          type="monotone"
          dataKey="conv"
          stroke="oklch(0.60 0.22 25)"
          strokeWidth={2.5}
          dot={false}
          animationDuration={1600}
        />
      </LineChart>
    </ResponsiveContainer>
  );
}

export function ChannelBar({ data, color = "red", emptyLabel }: { data?: ChannelPoint[]; color?: "red" | "blue"; emptyLabel?: string }) {
  const gradientId = useId();
  if (!data || data.length === 0) return <EmptyChart height={240} label={emptyLabel} />;
  return (
    <ResponsiveContainer width="100%" height={240}>
      <BarChart data={data} margin={{ top: 8, right: 8, left: -20, bottom: 0 }}>
        <defs>
          <linearGradient id={gradientId} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor={color === "blue" ? "#60a5fa" : "oklch(0.70 0.22 25)"} />
            <stop offset="100%" stopColor={color === "blue" ? "#2563eb" : "oklch(0.5 0.14 35)"} />
          </linearGradient>
        </defs>
        <CartesianGrid strokeDasharray="3 6" stroke="var(--border)" vertical={false} />
        <XAxis
          dataKey="c"
          stroke="var(--muted-foreground)"
          fontSize={11}
          tickLine={false}
          axisLine={false}
        />
        <YAxis stroke="var(--muted-foreground)" fontSize={11} tickLine={false} axisLine={false} />
        <Tooltip
          contentStyle={tooltipStyle}
          cursor={{ fill: "var(--muted)" }}
          formatter={(value) => [
            `${Number(value)} lead${Number(value) === 1 ? "" : "s"}`,
            "Quantidade",
          ]}
        />
        <Bar dataKey="v" fill={`url(#${gradientId})`} radius={[8, 8, 2, 2]} animationDuration={1400} />
      </BarChart>
    </ResponsiveContainer>
  );
}

export function TypeDonut({ data }: { data?: PortfolioPoint[] }) {
  if (!data || data.length === 0) return <EmptyChart height={240} />;
  const colors = [
    "oklch(0.68 0.20 25)", // vermelho
    "oklch(0.67 0.17 255)", // azul
    "oklch(0.70 0.16 145)", // verde
    "oklch(0.73 0.17 75)", // dourado
    "oklch(0.65 0.20 315)", // roxo
    "oklch(0.72 0.15 195)", // turquesa
    "oklch(0.70 0.18 45)", // laranja
  ];
  return (
    <ResponsiveContainer width="100%" height={240}>
      <PieChart>
        <Tooltip contentStyle={tooltipStyle} />
        <Pie
          data={data}
          dataKey="v"
          innerRadius={62}
          outerRadius={92}
          paddingAngle={3}
          stroke="none"
          animationDuration={1400}
        >
          {data.map((_, i) => (
            <Cell key={i} fill={colors[i % colors.length]} />
          ))}
        </Pie>
        <Legend
          iconType="circle"
          formatter={(v) => (
            <span style={{ color: "var(--muted-foreground)", fontSize: 11 }}>{v}</span>
          )}
        />
      </PieChart>
    </ResponsiveContainer>
  );
}

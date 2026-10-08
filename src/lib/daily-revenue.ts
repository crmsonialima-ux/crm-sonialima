import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/lib/supabase";

// Formato usado pelo painel, Corretores e Marketing. As vendas agora vêm do
// relatório; a antiga tabela diária permanece apenas para locações.
export type DailyRevenueEntry = {
  id: string;
  occurred_on: string;
  kind: "venda" | "aluguel";
  amount: number;
  broker_id: string;
  broker_name: string;
  property_id: string | null;
  property_title: string | null;
  capturer_id: string | null;
  capturer_name: string | null;
  vgv: number | null;
  created_at: string;
};

export const DAILY_REVENUE_QUERY_KEY = ["daily-broker-revenue"] as const;

export function reportingDate(entry: Pick<DailyRevenueEntry, "occurred_on" | "created_at">) {
  const selected = new Date(`${entry.occurred_on}T12:00:00`);
  const currentYear = new Date().getFullYear();
  if (
    Number.isNaN(selected.getTime()) ||
    selected.getFullYear() < 2000 ||
    selected.getFullYear() > currentYear + 1
  )
    return new Date(entry.created_at);
  return selected;
}

type SaleRow = {
  id: string;
  sold_on: string;
  seller_id: string;
  property_id: string | null;
  property_title: string | null;
  property_address: string;
  capturer_id: string | null;
  capturer_name: string;
  created_at: string;
};
type FinanceRow = {
  sale_id: string;
  purchase_price: number | string;
  commission_amount: number | string;
};
type ProfileRow = { id: string; full_name: string; email: string };

async function getRevenueHistory() {
  const [sales, financials, rentals, profiles] = await Promise.all([
    supabase
      .from("crm_sales")
      .select(
        "id,sold_on,seller_id,property_id,property_title,property_address,capturer_id,capturer_name,created_at",
      ),
    supabase.from("crm_sale_financials").select("sale_id,purchase_price,commission_amount"),
    supabase
      .from("crm_daily_broker_revenue")
      .select(
        "id,occurred_on,kind,amount,broker_id,broker_name,property_id,property_title,capturer_id,capturer_name,vgv,created_at",
      )
      .eq("kind", "aluguel"),
    supabase.rpc("list_agenda_profiles"),
  ]);
  if (sales.error) throw new Error(sales.error.message);
  if (financials.error) throw new Error(financials.error.message);
  if (rentals.error) throw new Error(rentals.error.message);
  if (profiles.error) throw new Error(profiles.error.message);
  const finance = new Map(
    ((financials.data ?? []) as FinanceRow[]).map((row) => [row.sale_id, row]),
  );
  const names = new Map(
    ((profiles.data ?? []) as ProfileRow[]).map((row) => [row.id, row.full_name || row.email]),
  );
  const saleEntries: DailyRevenueEntry[] = ((sales.data ?? []) as SaleRow[]).map((sale) => ({
    id: sale.id,
    occurred_on: sale.sold_on,
    kind: "venda",
    amount: Number(finance.get(sale.id)?.commission_amount ?? 0),
    broker_id: sale.seller_id,
    broker_name: names.get(sale.seller_id) ?? "Corretor",
    property_id: sale.property_id,
    property_title: sale.property_title || sale.property_address,
    capturer_id: sale.capturer_id,
    capturer_name: sale.capturer_name,
    vgv: finance.has(sale.id) ? Number(finance.get(sale.id)!.purchase_price) : null,
    created_at: sale.created_at,
  }));
  return [...saleEntries, ...((rentals.data ?? []) as DailyRevenueEntry[])].sort((left, right) =>
    right.created_at.localeCompare(left.created_at),
  );
}

export function useDailyRevenueHistory(enabled = true) {
  return useQuery({
    queryKey: DAILY_REVENUE_QUERY_KEY,
    queryFn: getRevenueHistory,
    enabled,
    staleTime: 0,
    refetchOnMount: "always",
    refetchInterval: 15_000,
  });
}

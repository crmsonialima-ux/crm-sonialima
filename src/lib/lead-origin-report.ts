import { useQuery } from "@tanstack/react-query";
import type { DashboardFilterState } from "@/components/dashboard/DashboardFilter";
import { canonicalLeadOrigin } from "@/lib/lead-origin";
import { supabase } from "@/lib/supabase";

type OriginSummary = { channel: string | null; source_portal: string | null; total: number | string };

export function useSystemLeadOrigins(userId: string | undefined, filter: DashboardFilterState, enabled: boolean) {
  const start = filter.allTime ? null : new Date(filter.year, filter.month, 1).toISOString();
  const end = filter.allTime ? null : new Date(filter.year, filter.month + 1, 1).toISOString();

  return useQuery({
    queryKey: ["crm-lead-origin-summary", userId, start, end],
    enabled: Boolean(userId) && enabled,
    refetchInterval: 60_000,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("crm_lead_origin_summary", { p_start: start, p_end: end });
      if (error) throw new Error(error.message);
      const channels: Record<string, number> = {};
      for (const row of (data ?? []) as OriginSummary[]) {
        const channel = canonicalLeadOrigin(row.channel) ?? canonicalLeadOrigin(row.source_portal) ?? "Não informado";
        channels[channel] = (channels[channel] ?? 0) + Number(row.total);
      }
      return Object.entries(channels).map(([c, v]) => ({ c, v }));
    },
  });
}

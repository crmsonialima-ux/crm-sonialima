import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/lib/supabase";

export type LeadType = "Venda" | "Aluguel";
export const LEAD_TYPES: LeadType[] = ["Venda"];
export const LEAD_DISTRIBUTION_QUERY_KEY = ["lead-distribution"] as const;

export type QueueBroker = {
  id: string;
  brokerId: string;
  leadType: LeadType;
  position: number;
  fullName: string;
  email: string;
  isBlocked: boolean;
  isPermanentlyBlocked: boolean;
  manuallyDisabled: boolean;
  blockedUntil?: string;
  blockedReason?: string;
};

type QueueRecord = {
  id: string;
  broker_id: string;
  lead_type: LeadType;
  queue_position: number;
  full_name: string;
  email: string;
  is_blocked: boolean;
  is_permanently_blocked: boolean;
  manually_disabled: boolean;
  blocked_until: string | null;
  blocked_reason: string | null;
};

async function getDistributionQueue() {
  const { data, error } = await supabase.rpc("list_lead_distribution_status");
  if (error) throw new Error(error.message);

  return (data as QueueRecord[]).map((item) => ({
    id: item.id,
    brokerId: item.broker_id,
    leadType: item.lead_type,
    position: item.queue_position,
    fullName: item.full_name || item.email || "Corretor",
    email: item.email || "",
    isBlocked: item.is_blocked,
    isPermanentlyBlocked: item.is_permanently_blocked,
    manuallyDisabled: item.manually_disabled,
    blockedUntil: item.blocked_until ?? undefined,
    blockedReason: item.blocked_reason ?? undefined,
  }));
}

export function useLeadDistribution(enabled = true, accessScope = "shared") {
  return useQuery({
    queryKey: [...LEAD_DISTRIBUTION_QUERY_KEY, accessScope],
    queryFn: getDistributionQueue,
    enabled,
    refetchInterval: 30_000,
    staleTime: 10_000,
  });
}

async function setBrokerQueueEnabled(input: { brokerId: string; enabled: boolean }) {
  const { error } = await supabase.rpc("set_broker_lead_queue_enabled", {
    p_broker_id: input.brokerId,
    p_enabled: input.enabled,
  });
  if (error) throw new Error(error.message);
}

export function useSetBrokerQueueEnabled() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: setBrokerQueueEnabled,
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: LEAD_DISTRIBUTION_QUERY_KEY });
    },
  });
}

async function forceUnblockBroker(brokerId: string) {
  const { error } = await supabase.rpc("force_unblock_broker_lead_queue", {
    p_broker_id: brokerId,
  });
  if (error) throw new Error(error.message);
}

export function useForceUnblockBroker() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: forceUnblockBroker,
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: LEAD_DISTRIBUTION_QUERY_KEY });
    },
  });
}

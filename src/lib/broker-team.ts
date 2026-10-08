import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/lib/supabase";

export const BROKER_CANDIDATES_QUERY_KEY = ["crm-broker-candidates"] as const;

export type BrokerCandidate = {
  id: string;
  fullName: string;
  email: string;
  whatsappPhone?: string;
};

type BrokerCandidateRecord = {
  id: string;
  full_name: string | null;
  email: string | null;
  whatsapp_phone: string | null;
};

async function getBrokerCandidates() {
  const { data, error } = await supabase.rpc("admin_list_broker_candidates");
  if (error) throw new Error(error.message);

  return ((data ?? []) as BrokerCandidateRecord[]).map((candidate): BrokerCandidate => ({
    id: candidate.id,
    fullName: candidate.full_name?.trim() || candidate.email?.trim() || "Usuário do Supabase",
    email: candidate.email?.trim() || "",
    whatsappPhone: candidate.whatsapp_phone?.trim() || undefined,
  }));
}

export function useBrokerCandidates(enabled: boolean) {
  return useQuery({
    queryKey: BROKER_CANDIDATES_QUERY_KEY,
    queryFn: getBrokerCandidates,
    enabled,
    staleTime: 15_000,
  });
}

export async function addExistingBroker(userId: string, whatsappPhone?: string) {
  const { data, error } = await supabase.rpc("admin_add_existing_broker", {
    p_user_id: userId,
    p_whatsapp_phone: whatsappPhone?.trim() || null,
  });
  if (error) throw new Error(error.message);
  const broker = Array.isArray(data) ? data[0] : data;
  if (!broker?.id) throw new Error("O Supabase não confirmou a inclusão do corretor.");
  return broker;
}

export async function removeBrokerFromTeam(userId: string) {
  const { error } = await supabase.rpc("admin_remove_broker_from_team", {
    p_user_id: userId,
  });
  if (error) throw new Error(error.message);
}

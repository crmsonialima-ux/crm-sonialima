import type { DashboardData } from "@/lib/api";
import { reportingDate, type DailyRevenueEntry } from "@/lib/daily-revenue";
import { displayBrokerName } from "@/lib/broker-names";
import { mutateApi } from "@/lib/crud-api";

export type Broker = {
  id: string;
  name: string;
  phone?: string;
  email?: string;
  creci?: string;
  status?: "Ativo" | "Inativo";
  properties?: number;
  leads: number;
  sales: number;
  rentals?: number;
  commission?: number;
  revenue: number;
  tier?: string;
};

export type BrokerInput = Pick<Broker, "name" | "phone" | "email" | "creci" | "status">;

const hiddenBrokerNames = new Set(["chuck", "sonialima"]);

function brokerKey(name?: string) {
  return displayBrokerName(name).trim().toLocaleLowerCase("pt-BR");
}

function propertyBrokers(name?: string) {
  return (name ?? "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

function emptyBroker(name: string, key = brokerKey(name)): Broker {
  return { id: `corretor-${key}`, name, leads: 0, sales: 0, rentals: 0, commission: 0, revenue: 0 };
}

export function brokersFromDashboard(
  data?: DashboardData,
  dailyEntries: DailyRevenueEntry[] = [],
  leadRows?: Array<{ corretor?: string }>,
): Broker[] {
  const brokers = new Map<string, Broker>();
  const propertyCounts = new Map<string, number>();

  for (const property of data?.imoveis ?? []) {
    for (const rawName of propertyBrokers(property.corretor)) {
      const name = displayBrokerName(rawName);
      const key = brokerKey(name);
      if (!key || hiddenBrokerNames.has(key)) continue;
      propertyCounts.set(key, (propertyCounts.get(key) ?? 0) + 1);
      if (!brokers.has(key)) brokers.set(key, emptyBroker(name, key));
    }
  }

  // A coluna de Leads é exclusivamente a contagem de leads atribuídos ao corretor.
  for (const lead of leadRows ?? data?.leads ?? []) {
    const name = displayBrokerName(lead.corretor);
    const key = brokerKey(name);
    if (!key || hiddenBrokerNames.has(key)) continue;
    const broker = brokers.get(key) ?? emptyBroker(name, key);
    broker.leads += 1;
    brokers.set(key, broker);
  }

  // Vendas do mês vêm do relatório; locações permanecem no histórico administrativo.
  const currentMonth = new Date().toISOString().slice(0, 7);
  for (const entry of dailyEntries) {
    if (reportingDate(entry).toISOString().slice(0, 7) !== currentMonth) continue;
    const name = displayBrokerName(entry.broker_name);
    const key = brokerKey(name);
    if (!key || hiddenBrokerNames.has(key)) continue;
    const broker = brokers.get(key) ?? emptyBroker(name, key);
    if (entry.kind === "venda") broker.sales += 1;
    else broker.rentals = (broker.rentals ?? 0) + 1;
    broker.commission = (broker.commission ?? 0) + Number(entry.amount);
    broker.revenue += Number(entry.amount);
    brokers.set(key, broker);
  }

  return [...brokers.values()]
    .map((broker) => ({ ...broker, properties: propertyCounts.get(brokerKey(broker.name)) ?? 0 }))
    .sort((left, right) => right.revenue - left.revenue || right.leads - left.leads);
}

export async function saveBroker(input: BrokerInput, id?: string): Promise<Broker> {
  return mutateApi<Broker>(id ? "updateCorretor" : "createCorretor", {
    ...input,
    ...(id ? { id } : {}),
  });
}

export async function deleteBroker(id: string): Promise<{ id: string }> {
  return mutateApi("deleteCorretor", { id });
}

import { createFileRoute } from "@tanstack/react-router";
import { Sidebar } from "@/components/dashboard/Sidebar";
import { Topbar } from "@/components/dashboard/Topbar";
import { BrokersManager } from "@/components/brokers/BrokersManager";
import { useDashboardData } from "@/lib/api";

export const Route = createFileRoute("/corretores")({
  head: () => ({
    meta: [
      { title: "Corretores — Sônia Lima CRM" },
      { name: "description", content: "Gestão profissional da equipe comercial." },
    ],
  }),
  component: BrokersPage,
});
function BrokersPage() {
  const { data, isLoading, error, unavailable, notConfigured, refetch } = useDashboardData();
  return (
    <div className="crm-shell min-h-dvh">
      <Sidebar />
      <main className="crm-main ml-0 min-w-0 px-4 pb-10 pt-16 sm:px-6 lg:ml-[264px] lg:px-8 lg:pb-16 lg:pt-0">
        <Topbar />
        <BrokersManager
          data={data}
          loading={isLoading}
          error={unavailable ? error : notConfigured ? new Error("API não configurada") : null}
          retry={() => void refetch()}
        />
      </main>
    </div>
  );
}

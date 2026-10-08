import { createFileRoute } from "@tanstack/react-router";
import { Sidebar } from "@/components/dashboard/Sidebar";
import { Topbar } from "@/components/dashboard/Topbar";
import { PropertiesManager } from "@/components/properties/PropertiesManager";
import { useAuth } from "@/components/auth/AuthProvider";
import { useDashboardData } from "@/lib/api";
export const Route = createFileRoute("/imoveis")({
  head: () => ({
    meta: [
      { title: "Imóveis — Sônia Lima CRM" },
      { name: "description", content: "Portfólio imobiliário conectado às oportunidades." },
    ],
  }),
  component: PropertiesPage,
});
function PropertiesPage() {
  const { data, isLoading, error, unavailable, notConfigured, refetch } = useDashboardData();
  const { profile } = useAuth();
  return (
    <div className="crm-shell min-h-dvh">
      <Sidebar />
      <main className="crm-main ml-0 min-w-0 px-4 pb-10 pt-16 sm:px-6 lg:ml-[264px] lg:px-8 lg:pb-16 lg:pt-0">
        <Topbar />
        <PropertiesManager
          data={data}
          loading={isLoading}
          error={unavailable ? error : notConfigured ? new Error("API não configurada") : null}
          retry={() => void refetch()}
        />
      </main>
    </div>
  );
}

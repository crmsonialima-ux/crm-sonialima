import { createFileRoute } from "@tanstack/react-router";
import { Sidebar } from "@/components/dashboard/Sidebar";
import { Topbar } from "@/components/dashboard/Topbar";
import { FinancingDashboard } from "@/components/financing/FinancingDashboard";

export const Route = createFileRoute("/financiamento")({
  head: () => ({
    meta: [
      { title: "Financiamento — Sônia Lima CRM" },
      {
        name: "description",
        content: "Gestão progressiva e auditável dos financiamentos imobiliários.",
      },
    ],
  }),
  component: FinancingPage,
});

function FinancingPage() {
  return (
    <div className="crm-shell min-h-dvh">
      <Sidebar />
      <main className="crm-main ml-0 min-w-0 px-4 pb-10 pt-16 sm:px-6 lg:ml-[264px] lg:px-8 lg:pb-16 lg:pt-0">
        <Topbar />
        <FinancingDashboard />
      </main>
    </div>
  );
}

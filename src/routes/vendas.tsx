import { createFileRoute } from "@tanstack/react-router";
import { Sidebar } from "@/components/dashboard/Sidebar";
import { Topbar } from "@/components/dashboard/Topbar";
import { SalesReport } from "@/components/sales/SalesReport";

export const Route = createFileRoute("/vendas")({
  head: () => ({ meta: [{ title: "Relatório de vendas — Sônia Lima CRM" }] }),
  component: SalesPage,
});

function SalesPage() {
  return (
    <div className="crm-shell min-h-dvh">
      <Sidebar />
      <main className="crm-main ml-0 min-w-0 px-4 pb-10 pt-16 sm:px-6 lg:ml-[264px] lg:px-8 lg:pb-16 lg:pt-0">
        <Topbar />
        <SalesReport />
      </main>
    </div>
  );
}

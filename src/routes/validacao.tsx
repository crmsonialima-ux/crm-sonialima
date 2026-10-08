import { createFileRoute } from "@tanstack/react-router";
import { Sidebar } from "@/components/dashboard/Sidebar";
import { Topbar } from "@/components/dashboard/Topbar";
import { ValidationDashboard } from "@/components/validation/ValidationDashboard";

export const Route = createFileRoute("/validacao")({
  head: () => ({
    meta: [
      { title: "Validação e Auditoria — Sônia Lima CRM" },
      {
        name: "description",
        content: "Painel exclusivo de validação operacional e auditoria do CRM.",
      },
    ],
  }),
  component: ValidationPage,
});

function ValidationPage() {
  return (
    <div className="crm-shell min-h-dvh">
      <Sidebar />
      <main className="crm-main ml-0 min-w-0 px-4 pb-10 pt-16 sm:px-6 lg:ml-[264px] lg:px-8 lg:pb-16 lg:pt-0">
        <Topbar />
        <ValidationDashboard />
      </main>
    </div>
  );
}

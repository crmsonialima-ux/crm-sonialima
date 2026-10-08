import { createFileRoute } from "@tanstack/react-router";
import { SettingsPage } from "@/components/settings/SettingsPage";
import { Sidebar } from "@/components/dashboard/Sidebar";
import { Topbar } from "@/components/dashboard/Topbar";

export const Route = createFileRoute("/configuracoes")({
  head: () => ({
    meta: [
      { title: "Configurações — Sônia Lima CRM" },
      {
        name: "description",
        content: "Preferências de conta, segurança, notificações, tema e idioma.",
      },
    ],
  }),
  component: SettingsRoute,
});
function SettingsRoute() {
  return (
    <div className="crm-shell min-h-dvh">
      <Sidebar />
      <main className="crm-main ml-0 min-w-0 px-4 pb-10 pt-16 sm:px-6 lg:ml-[264px] lg:px-8 lg:pb-16 lg:pt-0">
        <Topbar />
        <SettingsPage />
      </main>
    </div>
  );
}

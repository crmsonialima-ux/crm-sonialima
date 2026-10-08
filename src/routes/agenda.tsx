import { createFileRoute } from "@tanstack/react-router";
import { AgendaAvailability } from "@/components/agenda/AgendaAvailability";
import { AgendaManager } from "@/components/agenda/AgendaManager";
import { useAuth } from "@/components/auth/AuthProvider";
import { Sidebar } from "@/components/dashboard/Sidebar";
import { Topbar } from "@/components/dashboard/Topbar";
import { useAgendaProfiles } from "@/lib/lead-access";

export const Route = createFileRoute("/agenda")({ component: Page });

function Page() {
  const { profile } = useAuth();
  const brokers = useAgendaProfiles(Boolean(profile));

  return (
    <div className="crm-shell min-h-dvh">
      <Sidebar />
      <main className="crm-main ml-0 min-w-0 px-4 pb-10 pt-16 sm:px-6 lg:ml-[264px] lg:px-8 lg:pb-16 lg:pt-0">
        <Topbar />
        <AgendaManager profile={profile ?? undefined} brokers={brokers.data ?? []} />
        <AgendaAvailability brokers={brokers.data ?? []} profile={profile ?? undefined} />
      </main>
    </div>
  );
}

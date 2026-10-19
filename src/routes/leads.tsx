import { createFileRoute } from "@tanstack/react-router";
import { Sidebar } from "@/components/dashboard/Sidebar";
import { Topbar } from "@/components/dashboard/Topbar";
import { useAuth } from "@/components/auth/AuthProvider";
import { LeadsManager } from "@/components/leads/LeadsManager";
import { useLeadAccess } from "@/lib/lead-access";
import { isAdministradorAdmin, isRestrictedAdmin } from "@/lib/admin-access";

export const Route = createFileRoute("/leads")({
  head: () => ({
    meta: [
      { title: "Leads — Sônia Lima CRM" },
      { name: "description", content: "Gestão completa de leads, qualificação e conversão." },
    ],
  }),
  component: LeadsPage,
});

function LeadsPage() {
  const { session } = useAuth();
  const access = useLeadAccess(session?.user.id);
  const accessCrm = isRestrictedAdmin(access.profile);
  const canEditLeadData = isAdministradorAdmin(access.profile);
  const canUpdateLeadStage = Boolean(access.profile) && !accessCrm;
  // Somente Allyson pode cadastrar/lancar novos leads.
  const canCreateLead = isAdministradorAdmin(access.profile);
  const canManageAllLeads = isAdministradorAdmin(access.profile);
  const canDeleteLeads = isAdministradorAdmin(access.profile);
  const canTransferLeads = isAdministradorAdmin(access.profile);
  const canAddLeadObservation = isAdministradorAdmin(access.profile);
  return (
    <div className="crm-shell min-h-dvh">
      <Sidebar />
      <main className="crm-main ml-0 min-w-0 px-4 pb-10 pt-16 sm:px-6 lg:ml-[264px] lg:px-8 lg:pb-16 lg:pt-0">
        <Topbar />
        <LeadsManager
          data={access.leads}
          loading={access.loading}
          error={access.error instanceof Error ? access.error : null}
          onRetry={() => void access.refetch()}
          profile={access.profile}
          brokers={access.brokers}
          onCreateLead={canCreateLead ? access.createLead : undefined}
          creating={access.creating}
          onAssignLead={canTransferLeads ? access.assignLead : undefined}
          assigning={access.assigning}
          onCompleteRegistration={canEditLeadData ? access.completeLeadRegistration : undefined}
          completingRegistration={access.completingLeadRegistration}
          onDeleteLead={canDeleteLeads ? access.deleteLead : undefined}
          deleting={access.deleting}
          onUpdateLeadProgress={canUpdateLeadStage ? access.updateLeadProgress : undefined}
          updatingProgress={access.updatingProgress}
          onExtendAttendance={undefined}
          extendingAttendance={false}
          onAddLeadObservation={canAddLeadObservation ? access.addLeadObservation : undefined}
          addingLeadObservation={access.addingLeadObservation}
          onEditLeadObservation={canManageAllLeads ? access.editLeadObservation : undefined}
          editingLeadObservation={access.editingLeadObservation}
          onDeleteLeadObservation={canManageAllLeads ? access.deleteLeadObservation : undefined}
          deletingLeadObservation={access.deletingLeadObservation}
          onRestartExhaustedLead={
            isAdministradorAdmin(access.profile) ? access.restartExhaustedLead : undefined
          }
          restartingExhaustedLead={access.restartingExhaustedLead}
          onStartSimilarPropertyOffer={access.startSimilarPropertyOffer}
          startingSimilarPropertyOffer={access.startingSimilarPropertyOffer}
          onDismissSimilarPropertyMatches={access.dismissSimilarPropertyMatches}
          dismissingSimilarPropertyMatches={access.dismissingSimilarPropertyMatches}
          activities={access.activities}
          timelineEvents={access.timelineEvents}
        />
      </main>
    </div>
  );
}

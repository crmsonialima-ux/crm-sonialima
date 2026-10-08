import { useQuery } from "@tanstack/react-query";
import { useNavigate } from "@tanstack/react-router";
import { Landmark, Loader2 } from "lucide-react";
import { useState } from "react";
import { useAuth } from "@/components/auth/AuthProvider";
import { Button } from "@/components/ui/button";
import {
  getFinancingProcessByLead,
  isFinancingUnavailableError,
  useStartLeadFinancing,
} from "@/lib/financing";
import type { ManagedLead } from "@/lib/lead-access";

export function LeadFinancingAction({ lead }: { lead: ManagedLead }) {
  const { profile } = useAuth();
  const navigate = useNavigate();
  const process = useQuery({
    queryKey: ["crm-financing-process-by-lead", lead.id],
    queryFn: () => getFinancingProcessByLead(lead.id),
    retry: false,
  });
  const starter = useStartLeadFinancing();
  const [error, setError] = useState("");
  const canStart = profile?.role === "admin" || profile?.id === lead.ownerId;
  const unavailable = process.error && isFinancingUnavailableError(process.error);

  if (unavailable) return null;
  if (process.isLoading) {
    return (
      <div className="mt-5 flex items-center gap-2 border-t border-white/10 pt-4 text-xs text-muted-foreground">
        <Loader2 size={14} className="animate-spin" /> Verificando financiamento…
      </div>
    );
  }

  const open = (processId: string) => {
    void navigate({ to: "/financiamento", search: { process: processId } as never });
  };
  const start = async () => {
    setError("");
    try {
      const processId = await starter.mutateAsync(lead.id);
      open(processId);
    } catch (reason) {
      setError(
        reason instanceof Error ? reason.message : "Nao foi possivel iniciar o financiamento.",
      );
    }
  };

  return (
    <section className="mt-5 rounded-xl border border-copper/25 bg-copper/[0.05] p-4">
      <div className="flex items-start gap-3">
        <span className="grid h-9 w-9 shrink-0 place-items-center rounded-xl bg-copper/12 text-copper">
          <Landmark size={18} />
        </span>
        <div className="min-w-0 flex-1">
          <h3 className="text-sm font-semibold text-foreground">Financiamento</h3>
          <p className="mt-1 text-xs text-muted-foreground">
            {process.data
              ? "Este lead ja esta vinculado ao fluxo de financiamento."
              : canStart
                ? "Marque este lead para iniciar o fluxo operacional com o responsavel de financiamento."
                : "Somente o corretor responsavel pode iniciar o financiamento deste lead."}
          </p>
          {error ? <p className="mt-2 text-xs text-rose-300">{error}</p> : null}
          {process.data ? (
            <Button
              size="sm"
              variant="outline"
              className="mt-3"
              onClick={() => open(process.data!)}
            >
              <Landmark size={14} /> Abrir financiamento
            </Button>
          ) : canStart ? (
            <Button
              size="sm"
              className="mt-3 bg-copper text-white hover:bg-copper/90"
              disabled={starter.isPending}
              onClick={() => void start()}
            >
              {starter.isPending ? (
                <Loader2 size={14} className="animate-spin" />
              ) : (
                <Landmark size={14} />
              )}
              Financiamento
            </Button>
          ) : null}
        </div>
      </div>
    </section>
  );
}

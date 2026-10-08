import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Loader2, PauseCircle, PlayCircle, ShieldCheck } from "lucide-react";
import { Button } from "@/components/ui/button";
import { supabase } from "@/lib/supabase";

type Integration = { provider: string; enabled: boolean; updated_at: string };
type IntegrationProvider = "wimoveis_vrsync" | "dfimoveis_vrsync" | "whatsapp_business";

export function PortalLeadIntegrationControl({
  provider = "wimoveis_vrsync",
  title = "W Imóveis — Leads VRSYNC",
  canManage = true,
}: {
  provider?: IntegrationProvider;
  title?: string;
  canManage?: boolean;
}) {
  const queryClient = useQueryClient();
  const status = useQuery({
    queryKey: ["portal-lead-integration", provider],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("crm_portal_lead_integrations")
        .select("provider, enabled, updated_at")
        .eq("provider", provider)
        .single();
      if (error) throw new Error(error.message);
      return data as Integration;
    },
  });
  const changeStatus = useMutation({
    mutationFn: async (enabled: boolean) => {
      const { error } = await supabase.rpc("set_portal_lead_integration_enabled", {
        p_provider: provider,
        p_enabled: enabled,
      });
      if (error) throw new Error(error.message);
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["portal-lead-integration", provider] });
    },
  });
  const enabled = Boolean(status.data?.enabled);

  return (
    <div className="space-y-4">
      <div
        className={`rounded-xl border p-4 ${enabled ? "border-emerald-400/30 bg-emerald-400/10" : "border-amber-400/30 bg-amber-400/10"}`}
      >
        <div className="flex items-start justify-between gap-4">
          <div>
            <div className="flex items-center gap-2 text-sm font-semibold text-foreground">
              <ShieldCheck size={17} /> {title}
            </div>
            <p className="mt-1 text-xs leading-relaxed text-muted-foreground">
              {enabled
                ? "Recebimento liberado: cada lead válido será criado e distribuído pela fila autorizada do imóvel."
                : "Recebimento pausado: o portal pode continuar conectado, mas o CRM não criará nem distribuirá leads."}
            </p>
          </div>
          <span
            className={`shrink-0 rounded-full px-2.5 py-1 text-xs font-semibold ${enabled ? "bg-emerald-400/20 text-emerald-200" : "bg-amber-400/20 text-amber-100"}`}
          >
            {enabled ? "Ativa" : "Pausada"}
          </span>
        </div>
      </div>
      {status.isLoading ? (
        <div className="flex items-center gap-2 text-sm text-muted-foreground">
          <Loader2 size={16} className="animate-spin" /> Carregando status…
        </div>
      ) : status.error ? (
        <p className="text-sm text-red-300">
          Não foi possível ler a integração: {status.error.message}
        </p>
      ) : canManage ? (
        <Button
          onClick={() => changeStatus.mutate(!enabled)}
          disabled={changeStatus.isPending}
          className={
            enabled
              ? "bg-amber-600 text-white hover:bg-amber-500"
              : "bg-emerald-600 text-white hover:bg-emerald-500"
          }
        >
          {changeStatus.isPending ? (
            <Loader2 className="animate-spin" />
          ) : enabled ? (
            <PauseCircle />
          ) : (
            <PlayCircle />
          )}
          {enabled ? "Pausar recebimento" : "Ativar recebimento"}
        </Button>
      ) : (
        <p className="rounded-lg border border-white/10 bg-white/[0.03] px-3 py-2 text-sm text-muted-foreground">
          Seu acesso permite consultar o status, mas não ativar ou pausar esta integração.
        </p>
      )}
      {changeStatus.error && <p className="text-sm text-red-300">{changeStatus.error.message}</p>}
      <p className="text-xs leading-relaxed text-muted-foreground">
        A chave e a URL continuam as mesmas. Ao pausar, o endpoint responde ao portal sem registrar
        lead; ao ativar, a distribuição volta imediatamente.
      </p>
    </div>
  );
}

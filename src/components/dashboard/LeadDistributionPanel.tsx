import { Clock3, LockOpen, RotateCw, Settings2, UserX } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { Panel } from "@/components/dashboard/Panel";
import { LEAD_TYPES, useForceUnblockBroker, useLeadDistribution, useSetBrokerQueueEnabled } from "@/lib/lead-distribution";
import { displayBrokerName } from "@/lib/broker-names";
import { useAuth } from "@/components/auth/AuthProvider";
import { isAdministradorAdmin } from "@/lib/admin-access";
import { Switch } from "@/components/ui/switch";
import { toast } from "sonner";

export function LeadDistributionPanel() {
  const { profile } = useAuth();
  const canManageQueue = isAdministradorAdmin(profile);
  const { data = [], isLoading, error } = useLeadDistribution(
    true,
    canManageQueue ? "allyson" : "shared",
  );
  const queueControl = useSetBrokerQueueEnabled();
  const unblockControl = useForceUnblockBroker();
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 1_000);
    return () => window.clearInterval(timer);
  }, []);

  const blocked = useMemo(() => {
    const unique = new Map<string, (typeof data)[number]>();
    for (const item of data) {
      const timedBlockActive = item.blockedUntil
        ? new Date(item.blockedUntil).getTime() > now
        : false;
      if (item.isPermanentlyBlocked || timedBlockActive) unique.set(item.brokerId, item);
    }
    return [...unique.values()];
  }, [data, now]);

  const brokers = useMemo(() => {
    const unique = new Map<string, (typeof data)[number]>();
    for (const item of data) {
      unique.set(item.brokerId, item);
    }
    return [...unique.values()].sort((left, right) =>
      displayBrokerName(left.fullName).localeCompare(displayBrokerName(right.fullName), "pt-BR"),
    );
  }, [data]);

  const changeQueueParticipation = async (brokerId: string, enabled: boolean) => {
    try {
      await queueControl.mutateAsync({ brokerId, enabled });
      toast.success(enabled ? "Corretor reativado na fila." : "Corretor desativado da fila.");
    } catch (mutationError) {
      toast.error(mutationError instanceof Error ? mutationError.message : "Não foi possível alterar a fila.");
    }
  };

  const unblockBroker = async (brokerId: string) => {
    try {
      await unblockControl.mutateAsync(brokerId);
      toast.success("Corretor desbloqueado e liberado para receber leads.");
    } catch (mutationError) {
      toast.error(mutationError instanceof Error ? mutationError.message : "Não foi possível desbloquear o corretor.");
    }
  };

  return (
    <Panel
      title="Distribuição de leads"
      subtitle="Fila única de vendas e controle de corretores"
      className="mb-8"
    >
      {error ? (
        <p className="text-sm text-red-300">Não foi possível carregar as filas.</p>
      ) : (
        <div className="grid gap-3 lg:grid-cols-3">
          {LEAD_TYPES.map((leadType) => {
            const queue = data.filter(
              (item) =>
                item.leadType === leadType &&
                !item.isBlocked,
            );
            const next = queue[0];
            const upcoming = queue.map((item) => displayBrokerName(item.fullName));

            return (
              <div key={leadType} className="rounded-xl border border-white/8 bg-white/[0.02] p-4">
                <div className="flex items-center justify-between text-xs text-muted-foreground">
                  <span>{leadType}</span>
                  <RotateCw size={14} className="text-copper" />
                </div>
                <p className="mt-2 text-lg font-semibold text-foreground">
                  {isLoading ? "Carregando…" : displayBrokerName(next?.fullName) || "Sem corretor na fila"}
                </p>
                <p className="mt-1 text-xs text-muted-foreground">
                  {next
                    ? `${queue.length} corretor(es) apto(s) na fila`
                    : "Cadastre um corretor para iniciar a fila."}
                </p>
                {next ? (
                  <p className="mt-1 text-[11px] text-muted-foreground">
                    Próximos: {upcoming.join(" → ")}
                  </p>
                ) : null}
              </div>
            );
          })}
          <div className="rounded-xl border border-amber-400/20 bg-amber-400/[0.05] p-4">
            <div className="flex items-center justify-between text-xs text-amber-100/70">
              <span>Corretores bloqueados</span>
              <UserX size={14} className="text-amber-300" />
            </div>
            {isLoading ? (
              <p className="mt-2 text-sm text-muted-foreground">Carregando…</p>
            ) : blocked.length ? (
              <div className="mt-3 space-y-2">
                {blocked.map((item) => {
                  const presentation = blockPresentation(item, canManageQueue, now);
                  return (
                    <div key={item.brokerId} className="rounded-lg border border-white/8 bg-black/10 p-2.5">
                      <p className="text-sm font-medium text-foreground">
                        {displayBrokerName(item.fullName)}
                      </p>
                      <p className="mt-1 flex items-center gap-1 text-[11px] text-amber-100/75">
                        <Clock3 size={12} />
                        {presentation.status}
                      </p>
                      {presentation.detail ? (
                        <p className="mt-1 text-[10px] text-muted-foreground">{presentation.detail}</p>
                      ) : null}
                      {canManageQueue ? (
                        <button
                          type="button"
                          className="mt-2 inline-flex items-center gap-1.5 rounded-md border border-emerald-300/30 bg-emerald-400/10 px-2.5 py-1.5 text-[11px] font-semibold text-emerald-200 transition hover:bg-emerald-400/20 disabled:cursor-not-allowed disabled:opacity-50"
                          disabled={unblockControl.isPending}
                          onClick={() => void unblockBroker(item.brokerId)}
                        >
                          <LockOpen size={12} />
                          {unblockControl.isPending && unblockControl.variables === item.brokerId
                            ? "Desbloqueando…"
                            : "Desbloquear agora"}
                        </button>
                      ) : null}
                    </div>
                  );
                })}
              </div>
            ) : (
              <p className="mt-2 text-sm font-medium text-emerald-200">
                Nenhum corretor bloqueado
              </p>
            )}
          </div>
        </div>
      )}
      {canManageQueue && !error ? (
        <div className="mt-3 rounded-xl border border-copper/20 bg-copper/[0.04] p-4">
          <div className="flex items-center justify-between gap-3">
            <div>
              <p className="flex items-center gap-2 text-sm font-semibold text-foreground">
                <Settings2 size={15} className="text-copper" />
                Participação na fila
              </p>
              <p className="mt-1 text-xs text-muted-foreground">
                Controle exclusivo do crmallyson. Desativar impede o corretor de receber novos leads.
              </p>
            </div>
          </div>
          <div className="mt-3 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
            {brokers.map((broker) => {
              const changing = queueControl.isPending && queueControl.variables?.brokerId === broker.brokerId;
              return (
                <label
                  key={broker.brokerId}
                  className="flex items-center justify-between gap-3 rounded-lg border border-white/8 bg-black/10 px-3 py-2.5"
                >
                  <span className="min-w-0">
                    <span className="block truncate text-sm font-medium text-foreground">
                      {displayBrokerName(broker.fullName)}
                    </span>
                    <span className="block text-[10px] text-muted-foreground">
                      {broker.manuallyDisabled ? "Desativado manualmente" : "Ativo na fila"}
                    </span>
                  </span>
                  <Switch
                    checked={!broker.manuallyDisabled}
                    disabled={queueControl.isPending}
                    aria-label={`${broker.manuallyDisabled ? "Ativar" : "Desativar"} ${displayBrokerName(broker.fullName)} na fila`}
                    onCheckedChange={(enabled) => void changeQueueParticipation(broker.brokerId, enabled)}
                  />
                  {changing ? <span className="sr-only">Salvando</span> : null}
                </label>
              );
            })}
          </div>
        </div>
      ) : null}
    </Panel>
  );
}

function blockPresentation(
  item: {
    blockedUntil?: string;
    blockedReason?: string;
    isPermanentlyBlocked: boolean;
    manuallyDisabled: boolean;
  },
  canSeeManualReason: boolean,
  now: number,
) {
  const reason = item.blockedReason?.toLocaleLowerCase("pt-BR") ?? "";

  if (reason.includes("feedback")) {
    return { status: "Prazo indeterminado até dar o feedback da visita" };
  }
  if (item.manuallyDisabled || reason.includes("desativado manualmente")) {
    if (!canSeeManualReason) return { status: "Indisponível para receber leads" };
    return {
      status: "Aguardando reativação pelo crmallyson",
      detail: "Desativado manualmente pelo crmallyson",
    };
  }
  if (reason.includes("indisponivel") || reason.includes("indisponível")) {
    return { status: "Indisponível para receber leads" };
  }
  if (item.isPermanentlyBlocked) {
    return {
      status: "Prazo indeterminado até resolver a pendência",
      detail: formatBlockReason(item.blockedReason),
    };
  }
  if (!item.blockedUntil) {
    return { status: "Bloqueio ativo", detail: formatBlockReason(item.blockedReason) };
  }

  const remaining = Math.max(0, new Date(item.blockedUntil).getTime() - now);
  const hours = Math.floor(remaining / 3_600_000);
  const minutes = Math.floor((remaining % 3_600_000) / 60_000);
  const seconds = Math.floor((remaining % 60_000) / 1_000);
  const time = hours > 0 ? `${hours}h ${minutes}min` : `${minutes}min ${seconds}s`;
  return {
    status: `Tempo restante: ${time}`,
    detail: formatBlockReason(item.blockedReason),
  };
}

function formatBlockReason(reason?: string) {
  if (!reason) return undefined;
  const normalized = reason.toLocaleLowerCase("pt-BR");
  if (normalized.includes("qualificacao obrigatoria nao concluida")) {
    return "Penalidade: qualificação obrigatória não concluída";
  }
  if (normalized === "feedback_missing") return undefined;
  return reason;
}

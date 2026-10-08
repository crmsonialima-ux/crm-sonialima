import { Eye, Loader2, Search, Trash2, UserPlus } from "lucide-react";
import { useMemo, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { Button } from "@/components/ui/button";
import { Panel } from "@/components/dashboard/Panel";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { brokersFromDashboard, type Broker } from "@/lib/brokers";
import type { DashboardData } from "@/lib/api";
import { useAuth } from "@/components/auth/AuthProvider";
import { displayBrokerName } from "@/lib/broker-names";
import { useDailyRevenueHistory } from "@/lib/daily-revenue";
import { useBrokerProfiles, useLeadAccess } from "@/lib/lead-access";
import {
  addExistingBroker,
  BROKER_CANDIDATES_QUERY_KEY,
  removeBrokerFromTeam,
  useBrokerCandidates,
} from "@/lib/broker-team";
import { LEAD_DISTRIBUTION_QUERY_KEY } from "@/lib/lead-distribution";
import { reportCrmClientError } from "@/lib/audit-client";
import { isRestrictedAdmin } from "@/lib/admin-access";

export function BrokersManager({
  data,
  error,
  retry,
}: {
  data?: DashboardData;
  loading: boolean;
  error?: Error | null;
  retry: () => void;
}) {
  const { profile, session } = useAuth();
  const queryClient = useQueryClient();
  const [query, setQuery] = useState("");
  const [viewing, setViewing] = useState<Broker>();
  const [deleting, setDeleting] = useState<string>();
  const [message, setMessage] = useState("");
  const [addOpen, setAddOpen] = useState(false);
  const [selectedCandidateId, setSelectedCandidateId] = useState("");
  const [whatsappPhone, setWhatsappPhone] = useState("");
  const [adding, setAdding] = useState(false);
  const isAdmin = profile?.role === "admin";
  const canRemoveBrokers = isAdmin && !isRestrictedAdmin(profile);
  const dailyRevenue = useDailyRevenueHistory(Boolean(profile));
  const leadAccess = useLeadAccess(session?.user.id);
  const brokerProfiles = useBrokerProfiles(Boolean(profile));
  const candidates = useBrokerCandidates(isAdmin && addOpen);
  const selectedCandidate = candidates.data?.find(
    (candidate) => candidate.id === selectedCandidateId,
  );
  const allBrokers = useMemo(() => {
    const performance = brokersFromDashboard(data, dailyRevenue.data, leadAccess.leads);
    const performanceByName = new Map(
      performance.map((broker) => [brokerIdentity(broker.name), broker]),
    );

    return (brokerProfiles.data ?? [])
      .map((brokerProfile): Broker => {
        const measured =
          performanceByName.get(brokerIdentity(brokerProfile.fullName)) ??
          performanceByName.get(brokerIdentity(brokerProfile.email));
        return {
          id: brokerProfile.id,
          name: brokerProfile.fullName,
          email: brokerProfile.email,
          phone: measured?.phone,
          creci: measured?.creci,
          status: "Ativo",
          properties: measured?.properties ?? 0,
          leads: measured?.leads ?? 0,
          sales: measured?.sales ?? 0,
          rentals: measured?.rentals ?? 0,
          revenue: measured?.revenue ?? 0,
          tier: "Conta validada no Supabase",
        };
      })
      .sort((left, right) =>
        displayBrokerName(left.name).localeCompare(displayBrokerName(right.name), "pt-BR"),
      );
  }, [brokerProfiles.data, dailyRevenue.data, data, leadAccess.leads]);
  const brokers = useMemo(
    () =>
      allBrokers.filter((broker) =>
        [broker.name, broker.email, broker.creci].some((value) =>
          value?.toLowerCase().includes(query.toLowerCase()),
        ),
      ),
    [allBrokers, query],
  );
  const refreshBrokerQueries = async () => {
    await Promise.all([
      queryClient.invalidateQueries({ queryKey: ["crm-brokers"] }),
      queryClient.invalidateQueries({ queryKey: BROKER_CANDIDATES_QUERY_KEY }),
      queryClient.invalidateQueries({ queryKey: LEAD_DISTRIBUTION_QUERY_KEY }),
      brokerProfiles.refetch(),
    ]);
  };
  const closeAddDialog = () => {
    setAddOpen(false);
    setSelectedCandidateId("");
    setWhatsappPhone("");
  };
  const addBroker = async () => {
    if (!selectedCandidate) {
      setMessage("Selecione um usuário cadastrado no Supabase.");
      return;
    }
    setAdding(true);
    setMessage("");
    try {
      await addExistingBroker(
        selectedCandidate.id,
        selectedCandidate.whatsappPhone || whatsappPhone,
      );
      await refreshBrokerQueries();
      setMessage(
        `${displayBrokerName(selectedCandidate.fullName)} foi adicionado às filas de Venda e Aluguel.`,
      );
      closeAddDialog();
    } catch (reason) {
      await reportCrmClientError(reason, {
        area: "brokers",
        operation: "Adicionar corretor existente",
        details: { candidateId: selectedCandidate.id },
      });
      setMessage(
        reason instanceof Error ? reason.message : "Não foi possível adicionar o corretor.",
      );
    } finally {
      setAdding(false);
    }
  };
  const removeBroker = async (broker: Broker) => {
    if (
      !window.confirm(
        `Remover ${displayBrokerName(broker.name)} das filas comerciais? A conta, os leads e todo o histórico serão preservados.`,
      )
    )
      return;
    setDeleting(broker.id);
    setMessage("");
    try {
      await removeBrokerFromTeam(broker.id);
      await refreshBrokerQueries();
      setMessage(
        "Corretor removido das novas distribuições. A conta e o histórico foram preservados.",
      );
    } catch (reason) {
      await reportCrmClientError(reason, {
        area: "brokers",
        operation: "Remover corretor das filas",
        details: { brokerId: broker.id },
      });
      setMessage(reason instanceof Error ? reason.message : "Não foi possível remover o corretor.");
    } finally {
      setDeleting(undefined);
    }
  };
  return (
    <>
      <section className="mb-8 flex flex-wrap items-end justify-between gap-4 anim-float-in">
        <div>
          <div className="flex items-center gap-2 text-[11px] uppercase tracking-[0.24em] text-muted-foreground">
            <span className="h-1.5 w-1.5 rounded-full bg-copper shadow-[0_0_10px_var(--copper)]" />
            Gestão comercial
          </div>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Corretores</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Contas autorizadas no Supabase e desempenho da equipe comercial.
          </p>
        </div>
        {isAdmin && (
          <Button className="bg-copper text-white" onClick={() => setAddOpen(true)}>
            <UserPlus size={17} /> Adicionar corretor
          </Button>
        )}
      </section>
      <Panel
        title="Equipe comercial"
        subtitle={`${allBrokers.length} corretor${allBrokers.length === 1 ? "" : "es"} ativo${allBrokers.length === 1 ? "" : "s"} no Supabase`}
      >
        <div className="mb-5 relative">
          <Search
            size={16}
            className="absolute left-3 top-1/2 -translate-y-1/2 text-muted-foreground"
          />
          <input
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder="Buscar corretor, e-mail ou CRECI"
            className="w-full rounded-lg border border-white/10 bg-white/[0.03] py-2.5 pl-10 pr-3 text-sm outline-none focus:border-copper/50"
          />
        </div>
        {message && (
          <p role="status" className="mb-4 text-sm text-copper">
            {message}
          </p>
        )}
        {error && !brokerProfiles.error && (
          <p className="mb-4 text-xs text-amber-300">
            A equipe foi carregada do Supabase, mas alguns indicadores da API estão temporariamente
            indisponíveis.
          </p>
        )}
        <div className="space-y-3 lg:hidden">
          {brokerProfiles.isLoading ? (
            Array.from({ length: 4 }).map((_, index) => (
              <div key={index} className="rounded-xl border border-white/5 p-4">
                <div className="skeleton h-5 w-1/2" />
                <div className="skeleton mt-3 h-4 w-full" />
                <div className="skeleton mt-2 h-4 w-3/4" />
              </div>
            ))
          ) : brokerProfiles.error ? (
            <div className="rounded-xl border border-white/5 px-4 py-10 text-center">
              <p className="text-sm text-muted-foreground">Não foi possível carregar a equipe.</p>
              <Button
                variant="outline"
                size="sm"
                className="mt-3"
                onClick={() => {
                  retry();
                  void brokerProfiles.refetch();
                }}
              >
                Tentar novamente
              </Button>
            </div>
          ) : brokers.length === 0 ? (
            <div className="rounded-xl border border-white/5 px-4 py-10 text-center text-sm text-muted-foreground">
              Nenhum corretor ativo foi encontrado nas filas do Supabase.
            </div>
          ) : (
            brokers.map((broker) => (
              <article
                key={broker.id}
                className="rounded-xl border border-white/5 bg-white/[0.02] p-4"
              >
                <div className="flex min-w-0 items-start gap-3">
                  <div className="grid h-10 w-10 shrink-0 place-items-center rounded-lg bg-gradient-to-br from-copper to-wine text-xs font-semibold text-white">
                    {broker.name
                      .split(" ")
                      .slice(0, 2)
                      .map((part) => part[0])
                      .join("")}
                  </div>
                  <div className="min-w-0 flex-1">
                    <div className="flex min-w-0 items-start justify-between gap-2">
                      <div className="min-w-0">
                        <h3 className="break-words font-medium text-foreground">
                          {displayBrokerName(broker.name)}
                        </h3>
                        <p className="mt-0.5 break-words text-[10px] text-muted-foreground">
                          {broker.tier ?? "Equipe comercial"}
                        </p>
                      </div>
                      <span
                        className={`shrink-0 rounded-full px-2 py-1 text-[10px] font-medium ${broker.status === "Ativo" ? "bg-emerald-300/10 text-emerald-300" : broker.status === "Inativo" ? "bg-slate-300/10 text-slate-300" : "bg-white/[0.05] text-muted-foreground"}`}
                      >
                        {broker.status ?? "Não informado"}
                      </span>
                    </div>
                  </div>
                </div>

                <dl className="mt-4 grid grid-cols-2 gap-x-3 gap-y-3 text-xs">
                  <MobileBrokerDetail label="Telefone" value={broker.phone ?? "Não informado"} />
                  <MobileBrokerDetail label="E-mail" value={broker.email ?? "Não informado"} />
                  <MobileBrokerDetail label="CRECI" value={broker.creci ?? "Não informado"} />
                  <MobileBrokerDetail label="Imóveis" value={String(broker.properties ?? "—")} />
                  <MobileBrokerDetail label="Leads" value={String(broker.leads)} />
                  <MobileBrokerDetail label="Vendas no mês" value={String(broker.sales)} />
                  <MobileBrokerDetail
                    label="Locações no mês"
                    value={String(broker.rentals ?? "—")}
                  />
                </dl>

                <div className="mt-4 flex items-center gap-2 border-t border-white/5 pt-3">
                  <Button variant="outline" size="sm" onClick={() => setViewing(broker)}>
                    <Eye size={15} /> Visualizar
                  </Button>
                  {canRemoveBrokers && (
                    <Button
                      variant="ghost"
                      size="sm"
                      className="ml-auto text-red-300 hover:text-red-200"
                      onClick={() => void removeBroker(broker)}
                      disabled={deleting === broker.id}
                    >
                      {deleting === broker.id ? (
                        <Loader2 size={15} className="animate-spin" />
                      ) : (
                        <Trash2 size={15} />
                      )}
                      Remover
                    </Button>
                  )}
                </div>
              </article>
            ))
          )}
        </div>
        <div className="hidden overflow-x-auto rounded-xl border border-white/5 lg:block">
          <table className="w-full min-w-[1180px] text-sm">
            <thead>
              <tr className="bg-white/[0.02] text-left text-[10px] uppercase tracking-wider text-muted-foreground">
                {[
                  "Corretor",
                  "Contato",
                  "CRECI",
                  "Status",
                  "Imóveis",
                  "Leads",
                  "Vendas mês",
                  "Locações mês",
                  <span className="sr-only">Ações</span>,
                ].map((item, index) => (
                  <th key={index} className="px-4 py-3 font-medium">
                    {item}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {brokerProfiles.isLoading ? (
                <Skeleton />
              ) : brokerProfiles.error ? (
                <tr>
                  <td colSpan={10} className="px-4 py-12 text-center">
                    <p className="text-sm text-muted-foreground">
                      Não foi possível carregar a equipe.
                    </p>
                    <Button
                      variant="outline"
                      size="sm"
                      className="mt-3"
                      onClick={() => {
                        retry();
                        void brokerProfiles.refetch();
                      }}
                    >
                      Tentar novamente
                    </Button>
                  </td>
                </tr>
              ) : brokers.length === 0 ? (
                <tr>
                  <td colSpan={10} className="px-4 py-12 text-center text-sm text-muted-foreground">
                    Nenhum corretor ativo foi encontrado nas filas do Supabase.
                  </td>
                </tr>
              ) : (
                brokers.map((broker) => (
                  <tr key={broker.id} className="border-t border-white/5 hover:bg-white/[0.025]">
                    <td className="px-4 py-3">
                      <div className="flex items-center gap-3">
                        <div className="grid h-9 w-9 place-items-center rounded-lg bg-gradient-to-br from-copper to-wine text-xs font-semibold text-white">
                          {broker.name
                            .split(" ")
                            .slice(0, 2)
                            .map((part) => part[0])
                            .join("")}
                        </div>
                        <div>
                          <div className="font-medium">{displayBrokerName(broker.name)}</div>
                          <div className="text-[10px] text-muted-foreground">
                            {broker.tier ?? "Equipe comercial"}
                          </div>
                        </div>
                      </div>
                    </td>
                    <td className="px-4 py-3 text-xs text-muted-foreground">
                      <div>{broker.phone ?? "Não informado"}</div>
                      <div>{broker.email ?? "Não informado"}</div>
                    </td>
                    <td className="px-4 py-3 text-muted-foreground">
                      {broker.creci ?? "Não informado"}
                    </td>
                    <td className="px-4 py-3">
                      <span
                        className={`rounded-full px-2 py-1 text-[10px] font-medium ${broker.status === "Ativo" ? "bg-emerald-300/10 text-emerald-300" : broker.status === "Inativo" ? "bg-slate-300/10 text-slate-300" : "bg-white/[0.05] text-muted-foreground"}`}
                      >
                        {broker.status ?? "Não informado"}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-muted-foreground">{broker.properties ?? "—"}</td>
                    <td className="px-4 py-3">{broker.leads}</td>
                    <td className="px-4 py-3">{broker.sales}</td>
                    <td className="px-4 py-3 text-muted-foreground">{broker.rentals ?? "—"}</td>

                    <td className="px-4 py-3 text-right">
                      <Button
                        variant="ghost"
                        size="icon"
                        aria-label={`Visualizar ${broker.name}`}
                        onClick={() => setViewing(broker)}
                      >
                        <Eye size={15} />
                      </Button>
                      {canRemoveBrokers && (
                        <Button
                          variant="ghost"
                          size="icon"
                          className="text-red-300 hover:text-red-200"
                          aria-label={`Remover ${displayBrokerName(broker.name)} da equipe`}
                          title="Remover das filas sem apagar a conta ou o histórico"
                          onClick={() => void removeBroker(broker)}
                          disabled={deleting === broker.id}
                        >
                          {deleting === broker.id ? (
                            <Loader2 size={15} className="animate-spin" />
                          ) : (
                            <Trash2 size={15} />
                          )}
                        </Button>
                      )}
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </Panel>
      <BrokerView broker={viewing} onOpenChange={(open) => !open && setViewing(undefined)} />
      <Dialog
        open={addOpen}
        onOpenChange={(open) => {
          if (!open && !adding) closeAddDialog();
        }}
      >
        <DialogContent className="glass-strong border-white/10 text-foreground">
          <DialogHeader>
            <DialogTitle>Adicionar corretor</DialogTitle>
            <DialogDescription>
              Somente contas já cadastradas, confirmadas e elegíveis no Supabase aparecem nesta
              lista.
            </DialogDescription>
          </DialogHeader>

          {candidates.isLoading ? (
            <div className="flex items-center gap-2 py-6 text-sm text-muted-foreground">
              <Loader2 size={17} className="animate-spin" /> Consultando o Supabase…
            </div>
          ) : candidates.error ? (
            <div className="rounded-lg border border-red-400/20 bg-red-400/10 p-3 text-sm text-red-200">
              {candidates.error instanceof Error
                ? candidates.error.message
                : "Não foi possível consultar os usuários do Supabase."}
            </div>
          ) : candidates.data?.length ? (
            <div className="space-y-4">
              <label className="block text-xs text-muted-foreground">
                Usuário do Supabase
                <select
                  value={selectedCandidateId}
                  onChange={(event) => {
                    setSelectedCandidateId(event.target.value);
                    setWhatsappPhone("");
                  }}
                  className={inputClass}
                >
                  <option value="">Selecione uma conta</option>
                  {candidates.data.map((candidate) => (
                    <option key={candidate.id} value={candidate.id}>
                      {displayBrokerName(candidate.fullName)} · {candidate.email}
                    </option>
                  ))}
                </select>
              </label>

              {selectedCandidate &&
                (selectedCandidate.whatsappPhone ? (
                  <div className="rounded-lg border border-emerald-300/15 bg-emerald-300/[0.06] p-3 text-sm text-emerald-200">
                    WhatsApp já validado no Supabase: {selectedCandidate.whatsappPhone}
                  </div>
                ) : (
                  <label className="block text-xs text-muted-foreground">
                    WhatsApp com DDI 55
                    <input
                      value={whatsappPhone}
                      onChange={(event) =>
                        setWhatsappPhone(event.target.value.replace(/\D/g, "").slice(0, 13))
                      }
                      inputMode="numeric"
                      placeholder="Ex.: 5561999999999"
                      className={inputClass}
                    />
                    <span className="mt-1 block text-[11px]">
                      Necessário para preservar a distribuição das integrações de WhatsApp.
                    </span>
                  </label>
                ))}

              <Button
                className="w-full bg-copper text-white"
                onClick={() => void addBroker()}
                disabled={
                  adding ||
                  !selectedCandidate ||
                  (!selectedCandidate.whatsappPhone && !/^55[1-9][0-9]{9,10}$/.test(whatsappPhone))
                }
              >
                {adding ? <Loader2 size={17} className="animate-spin" /> : <UserPlus size={17} />}
                Adicionar às filas
              </Button>
            </div>
          ) : (
            <div className="rounded-lg border border-white/10 bg-white/[0.03] p-4 text-sm text-muted-foreground">
              Todos os usuários elegíveis do Supabase já estão na equipe. Para adicionar outro,
              cadastre e confirme primeiro a conta em Authentication → Users.
            </div>
          )}
        </DialogContent>
      </Dialog>
    </>
  );
}

function brokerIdentity(value?: string) {
  return displayBrokerName(value).trim().toLocaleLowerCase("pt-BR");
}

const inputClass =
  "mt-1.5 w-full rounded-lg border border-white/10 bg-white/[0.03] px-3 py-2.5 text-sm text-foreground outline-none focus:border-copper/50";
function BrokerView({
  broker,
  onOpenChange,
}: {
  broker?: Broker;
  onOpenChange: (open: boolean) => void;
}) {
  return (
    <Dialog open={Boolean(broker)} onOpenChange={onOpenChange}>
      <DialogContent className="glass-strong border-white/10 text-foreground">
        <DialogHeader>
          <DialogTitle>{broker?.name}</DialogTitle>
          <DialogDescription>Resumo da performance disponível na API.</DialogDescription>
        </DialogHeader>
        <dl className="grid grid-cols-2 gap-4 text-sm">
          <Item label="Leads ativos" value={String(broker?.leads ?? 0)} />
          <Item label="Vendas" value={String(broker?.sales ?? 0)} />
          <Item
            label="Faturamento"
            value={broker?.revenue.toLocaleString("pt-BR", { style: "currency", currency: "BRL" })}
          />
          <Item label="CRECI" value={broker?.creci ?? "Não informado"} />
        </dl>
      </DialogContent>
    </Dialog>
  );
}
function Item({ label, value }: { label: string; value?: string }) {
  return (
    <div>
      <dt className="text-xs text-muted-foreground">{label}</dt>
      <dd className="mt-1 font-medium">{value ?? "—"}</dd>
    </div>
  );
}
function MobileBrokerDetail({ label, value }: { label: string; value: string }) {
  return (
    <div className="min-w-0">
      <dt className="text-[10px] uppercase tracking-wider text-muted-foreground">{label}</dt>
      <dd className="mt-1 break-words font-medium text-foreground">{value}</dd>
    </div>
  );
}
function Skeleton() {
  return (
    <>
      {Array.from({ length: 7 }).map((_, row) => (
        <tr key={row} className="border-t border-white/5">
          {Array.from({ length: 10 }).map((__, column) => (
            <td key={column} className="px-4 py-4">
              <div className="skeleton h-4 w-full" />
            </td>
          ))}
        </tr>
      ))}
    </>
  );
}

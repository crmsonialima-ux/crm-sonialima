import { useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { supabase } from "@/lib/supabase";
import type { AccessProfile } from "@/lib/lead-access";
import { reportCrmClientError } from "@/lib/audit-client";
import { displayText } from "@/lib/display-text";

const labels = {
  neo_energia: "NEO Energia",
  caesb: "Caesb",
  cartorio: "Cartório",
  observacao: "Observação",
};

export function AgendaManager({
  profile,
  brokers,
}: {
  profile?: AccessProfile;
  brokers: AccessProfile[];
}) {
  const queryClient = useQueryClient();
  const [category, setCategory] = useState<keyof typeof labels>("observacao");
  const [when, setWhen] = useState("");
  const [note, setNote] = useState("");
  const [target, setTarget] = useState(profile?.id ?? "");
  const [companions, setCompanions] = useState<string[]>([]);
  const [companionReason, setCompanionReason] = useState("");
  const [clientName, setClientName] = useState("");
  const [propertyAddress, setPropertyAddress] = useState("");
  const [notaryName, setNotaryName] = useState("");
  const [service, setService] = useState("");
  const [error, setError] = useState("");
  const [creating, setCreating] = useState(false);
  const [draftRestored, setDraftRestored] = useState(false);
  const draftKey = `sonialima:agenda-create-draft:${profile?.id ?? "anonymous"}`;
  const derley = brokers.find(
    (broker) => broker.email.toLowerCase() === "unassigned-agenda@example.invalid",
  );
  const targets = brokers;

  useEffect(() => {
    try {
      const saved = JSON.parse(localStorage.getItem(draftKey) ?? "null") as {
        category?: keyof typeof labels;
        when?: string;
        note?: string;
        target?: string;
        companions?: string[];
        companionReason?: string;
        clientName?: string;
        propertyAddress?: string;
        notaryName?: string;
        service?: string;
      } | null;
      if (!saved) return;
      if (saved.category) setCategory(saved.category);
      setWhen(saved.when ?? "");
      setNote(saved.note ?? "");
      setTarget(saved.target ?? profile?.id ?? "");
      setCompanions(saved.companions ?? []);
      setCompanionReason(saved.companionReason ?? "");
      setClientName(saved.clientName ?? "");
      setPropertyAddress(saved.propertyAddress ?? "");
      setNotaryName(saved.notaryName ?? "");
      setService(saved.service ?? "");
    } catch {
      localStorage.removeItem(draftKey);
    } finally {
      setDraftRestored(true);
    }
  }, [draftKey, profile?.id]);

  useEffect(() => {
    if (!draftRestored) return;
    localStorage.setItem(
      draftKey,
      JSON.stringify({
        category,
        when,
        note,
        target,
        companions,
        companionReason,
        clientName,
        propertyAddress,
        notaryName,
        service,
      }),
    );
  }, [
    category,
    clientName,
    companions,
    companionReason,
    draftKey,
    draftRestored,
    notaryName,
    note,
    propertyAddress,
    service,
    target,
    when,
  ]);

  function showCreateError(reason: { message: string }) {
    setError(displayText(reason.message));
    void reportCrmClientError(reason.message, {
      area: "agenda",
      operation: "Criar compromisso",
      details: { category, targetUserId: target, scheduledAt: when },
    });
  }

  function brokerName(userId: string) {
    const broker = brokers.find((item) => item.id === userId);
    return broker?.fullName || broker?.email?.split("@")[0] || "Usuário";
  }

  async function rollbackCreatedEntries(entryIds: string[]) {
    await Promise.allSettled(
      entryIds.map((entryId) => supabase.rpc("delete_agenda_entry", { p_id: entryId })),
    );
  }

  async function create() {
    setError("");
    if (creating) return;
    if (!when || !target) return setError("Informe data, hora e responsável.");
    if (companions.length > 0 && !companionReason.trim()) {
      return setError("Informe obrigatoriamente o motivo do acompanhante.");
    }
    if (category === "cartorio") {
      if (!clientName.trim() || !propertyAddress.trim() || !notaryName.trim() || !service.trim()) {
        return setError("Para Cartório, informe cliente, endereço do imóvel, cartório e serviço.");
      }
      if (!derley || target !== derley.id)
        return setError("Demandas de Cartório devem ser direcionadas ao Derley.");
    } else if (category === "neo_energia" || category === "caesb") {
      if (!clientName.trim() || !propertyAddress.trim() || !service.trim()) {
        return setError("Informe cliente, endereço do imóvel e serviço.");
      }
    } else {
      if (!note.trim()) return setError("Informe a observação / motivo do compromisso.");
    }

    setCreating(true);
    const createdEntryIds: string[] = [];
    try {
      let rpcError: { message: string } | null = null;
      let entryId: string | null = null;
      const attendeeIds = [target, ...companions.filter((userId) => userId !== target)];
      const attendeeNames = attendeeIds.map(brokerName);
      const togetherText =
        attendeeNames.length > 1 ? `\n\nIrão juntos: ${attendeeNames.join(" e ")}.` : "";
      const sharedObservation = `${note.trim()}${togetherText}`;

      if (category === "cartorio") {
        ({ data: entryId, error: rpcError } = await supabase.rpc("create_cartorio_agenda_entry", {
          p_scheduled_at: new Date(when).toISOString(),
          p_client_name: clientName,
          p_property_address: propertyAddress,
          p_cartorio_name: notaryName,
          p_service: service,
          p_target_user_id: target,
        }));
      } else if (category === "neo_energia" || category === "caesb") {
        ({ data: entryId, error: rpcError } = await supabase.rpc("create_service_agenda_entry", {
          p_category: category,
          p_scheduled_at: new Date(when).toISOString(),
          p_client_name: clientName,
          p_property_address: propertyAddress,
          p_service: service,
          p_target_user_id: target,
        }));
      } else {
        ({ data: entryId, error: rpcError } = await supabase.rpc("create_agenda_entry", {
          p_category: category,
          p_scheduled_at: new Date(when).toISOString(),
          p_observation: sharedObservation,
          p_target_user_id: target,
        }));
      }

      if (rpcError) {
        showCreateError(rpcError);
        return;
      }

      if (entryId) createdEntryIds.push(entryId);

      if (entryId) {
        const { error: participantError } = await supabase.rpc(
          "request_agenda_companion_approval",
          {
            p_entry_id: entryId,
            p_companion_user_ids: companions,
            p_reason: companionReason.trim(),
          },
        );
        if (participantError) {
          await rollbackCreatedEntries(createdEntryIds);
          showCreateError(participantError);
          return;
        }
      }

      setNote("");
      setWhen("");
      setClientName("");
      setPropertyAddress("");
      setNotaryName("");
      setService("");
      setCompanions([]);
      setCompanionReason("");
      localStorage.removeItem(draftKey);
      await queryClient.invalidateQueries({ queryKey: ["agenda"] });
    } catch (reason) {
      await rollbackCreatedEntries(createdEntryIds);
      showCreateError({
        message: reason instanceof Error ? reason.message : "Não foi possível criar o compromisso.",
      });
    } finally {
      setCreating(false);
    }
  }

  return (
    <div>
      <section className="mb-7">
        <p className="text-[11px] uppercase tracking-[.24em] text-muted-foreground">
          Agenda compartilhada
        </p>
        <h1 className="mt-2 text-3xl font-semibold">Agenda</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Todos veem compromissos e observações. Demandas NEO e Caesb seguem a esteira Derley →
          Vitor → admin.
        </p>
      </section>
      {error && (
        <p
          role="alert"
          className="mb-3 rounded-lg border border-red-400/30 bg-red-400/10 p-3 text-sm text-red-200"
        >
          {error}
        </p>
      )}
      <div className="rounded-xl border border-white/10 bg-white/[.03] p-4">
        <div className="grid gap-3 md:grid-cols-5">
          <select
            value={category}
            onChange={(event) => {
              const next = event.target.value as keyof typeof labels;
              setCategory(next);
              if (next === "cartorio" && derley) setTarget(derley.id);
            }}
            className="rounded-lg bg-background p-2"
          >
            {Object.entries(labels).map(([key, value]) => (
              <option key={key} value={key}>
                {value}
              </option>
            ))}
          </select>
          <input
            type="datetime-local"
            value={when}
            min="2000-01-01T00:00"
            max="9999-12-31T23:59"
            onChange={(event) => {
              const value = event.target.value;
              if ((value.split("-")[0] || "").length <= 4) setWhen(value);
            }}
            className="rounded-lg bg-background p-2"
          />
          <select
            value={target}
            onChange={(event) => {
              setTarget(event.target.value);
              setCompanions((current) =>
                current.filter((brokerId) => brokerId !== event.target.value),
              );
            }}
            className="rounded-lg bg-background p-2"
          >
            {targets.map((broker) => (
              <option key={broker.id} value={broker.id}>
                {broker.fullName || broker.email}
              </option>
            ))}
          </select>
          <details className="group relative rounded-lg bg-background">
            <summary className="flex h-full min-h-10 cursor-pointer list-none items-center justify-between gap-2 px-3 py-2 text-sm marker:hidden">
              <span className="truncate">
                {companions.length
                  ? `${companions.length} acompanhante${companions.length > 1 ? "s" : ""}`
                  : "Sem acompanhante"}
              </span>
              <span className="text-muted-foreground group-open:rotate-180">⌄</span>
            </summary>
            <div className="absolute left-0 top-full z-30 mt-1 max-h-64 w-full min-w-56 overflow-y-auto rounded-lg border border-white/15 bg-background p-2 shadow-2xl">
              {targets
                .filter((broker) => broker.id !== target)
                .map((broker) => (
                  <label
                    key={broker.id}
                    className="flex cursor-pointer items-center gap-2 rounded px-2 py-2 text-sm hover:bg-white/10"
                  >
                    <input
                      type="checkbox"
                      checked={companions.includes(broker.id)}
                      onChange={() =>
                        setCompanions((current) =>
                          current.includes(broker.id)
                            ? current.filter((brokerId) => brokerId !== broker.id)
                            : [...current, broker.id],
                        )
                      }
                      className="accent-copper"
                    />
                    Ir junto: {broker.fullName || broker.email}
                  </label>
                ))}
            </div>
          </details>
          <Button disabled={creating} onClick={() => void create()}>
            {creating ? "Adicionando..." : "Adicionar"}
          </Button>
        </div>
        {category === "cartorio" ? (
          <div className="mt-3 grid gap-3 md:grid-cols-2">
            <input
              value={clientName}
              onChange={(event) => setClientName(event.target.value)}
              placeholder="Nome do cliente"
              className="rounded-lg bg-background p-2"
            />
            <input
              value={propertyAddress}
              onChange={(event) => setPropertyAddress(event.target.value)}
              placeholder="Endereço do imóvel"
              className="rounded-lg bg-background p-2"
            />
            <input
              value={notaryName}
              onChange={(event) => setNotaryName(event.target.value)}
              placeholder="Cartório"
              className="rounded-lg bg-background p-2"
            />
            <input
              value={service}
              onChange={(event) => setService(event.target.value)}
              placeholder="Serviço a ser realizado"
              className="rounded-lg bg-background p-2"
            />
          </div>
        ) : category === "neo_energia" || category === "caesb" ? (
          <div className="mt-3 grid gap-3 md:grid-cols-2">
            <input
              value={clientName}
              onChange={(event) => setClientName(event.target.value)}
              placeholder="Nome do cliente"
              className="rounded-lg bg-background p-2"
            />
            <input
              value={propertyAddress}
              onChange={(event) => setPropertyAddress(event.target.value)}
              placeholder="Endereço do imóvel"
              className="rounded-lg bg-background p-2"
            />
            <input
              value={service}
              onChange={(event) => setService(event.target.value)}
              placeholder="Serviço a ser realizado"
              className="rounded-lg bg-background p-2 md:col-span-2"
            />
          </div>
        ) : (
          <textarea
            value={note}
            onChange={(event) => setNote(event.target.value)}
            placeholder="Observação / motivo do compromisso"
            className="mt-3 min-h-20 w-full rounded-lg bg-background p-2"
          />
        )}
        {companions.length > 0 && (
          <textarea
            required
            value={companionReason}
            onChange={(event) => setCompanionReason(event.target.value)}
            placeholder="Motivo obrigatório para o acompanhante"
            className="mt-3 min-h-20 w-full rounded-lg border border-amber-400/30 bg-background p-2"
          />
        )}
      </div>
    </div>
  );
}

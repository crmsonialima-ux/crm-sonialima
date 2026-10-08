import { useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { DAILY_REVENUE_QUERY_KEY, useDailyRevenueHistory } from "@/lib/daily-revenue";
import { supabase } from "@/lib/supabase";
import type { AccessProfile } from "@/lib/lead-access";

function formatCurrencyInput(value: string) {
  const clean = value.replace(/[^\d,]/g, "");
  const [whole, cents] = clean.split(",");
  const grouped = whole.replace(/^0+(?=\d)/, "").replace(/\B(?=(\d{3})+(?!\d))/g, ".");
  return clean.includes(",") ? `${grouped},${(cents ?? "").slice(0, 2)}` : grouped;
}

export function RentalReport({
  month,
  brokers,
  canManage,
}: {
  month: string;
  brokers: AccessProfile[];
  canManage: boolean;
}) {
  const history = useDailyRevenueHistory(true);
  const queryClient = useQueryClient();
  const [date, setDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [brokerId, setBrokerId] = useState("");
  const [amount, setAmount] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const rentals = (history.data ?? []).filter(
    (entry) => entry.kind === "aluguel" && entry.occurred_on.startsWith(month),
  );

  async function save() {
    setError("");
    setNotice("");
    const number = Number(amount.replace(/\./g, "").replace(",", "."));
    if (!date || !brokerId || !Number.isFinite(number) || number <= 0) {
      setError("Informe data, corretor e faturamento da locação.");
      return;
    }
    setSaving(true);
    const { error: saveError } = await supabase.rpc("save_crm_rental", {
      p_date: date,
      p_broker_id: brokerId,
      p_amount: number,
    });
    setSaving(false);
    if (saveError) {
      setError(saveError.message);
      return;
    }
    setAmount("");
    setBrokerId("");
    setNotice("Locação registrada no relatório e no painel.");
    await queryClient.invalidateQueries({ queryKey: DAILY_REVENUE_QUERY_KEY });
  }

  return (
    <section className="rounded-xl border border-white/10 bg-white/[.03] p-4 sm:p-5">
      <div>
        <p className="text-xs uppercase tracking-widest text-copper">
          Histórico de locações
        </p>
        <h2 className="mt-1 text-lg font-semibold">Locações</h2>
        <p className="mt-1 text-xs text-muted-foreground">
          As vendas antigas aparecem acima; as locações ficam aqui.
        </p>
      </div>
      {canManage && (
        <div className="mt-4 grid gap-3 sm:grid-cols-[160px_1fr_180px_auto]">
          <input
            aria-label="Data da locação"
            type="date"
            value={date}
            onChange={(event) => setDate(event.target.value)}
            className="rounded-lg border border-white/10 bg-background p-2 text-sm"
          />
          <select
            aria-label="Corretor da locação"
            value={brokerId}
            onChange={(event) => setBrokerId(event.target.value)}
            className="rounded-lg border border-white/10 bg-background p-2 text-sm"
          >
            <option value="">Corretor</option>
            {brokers
              .filter((broker) => broker.role === "broker")
              .map((broker) => (
                <option key={broker.id} value={broker.id}>
                  {broker.fullName}
                </option>
              ))}
          </select>
          <input
            aria-label="Faturamento da locação"
            value={amount}
            onChange={(event) => setAmount(formatCurrencyInput(event.target.value))}
            inputMode="decimal"
            placeholder="R$ 0,00"
            className="rounded-lg border border-white/10 bg-background p-2 text-sm"
          />
          <Button disabled={saving} onClick={() => void save()}>
            {saving ? "Salvando..." : "Registrar locação"}
          </Button>
        </div>
      )}
      {error && (
        <p role="alert" className="mt-3 text-sm text-red-300">
          {error}
        </p>
      )}
      {notice && <p className="mt-3 text-sm text-emerald-300">{notice}</p>}
      {history.error && (
        <p role="alert" className="mt-3 text-sm text-red-300">
          {history.error.message}
        </p>
      )}
      <div className="mt-4 space-y-2">
        {rentals.length === 0 ? (
          <p className="text-sm text-muted-foreground">Nenhuma locação neste mês.</p>
        ) : (
          rentals.map((rental) => (
            <div
              key={rental.id}
              className="flex flex-wrap justify-between gap-2 rounded-lg border border-white/10 p-3 text-sm"
            >
              <span>
                {rental.broker_name} ·{" "}
                {new Date(`${rental.occurred_on}T12:00:00`).toLocaleDateString("pt-BR")}
              </span>
              {canManage && (
                <b>
                  {Number(rental.amount).toLocaleString("pt-BR", {
                    style: "currency",
                    currency: "BRL",
                  })}
                </b>
              )}
            </div>
          ))
        )}
      </div>
    </section>
  );
}

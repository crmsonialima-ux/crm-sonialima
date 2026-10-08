import { useEffect, useState } from "react";
import type { AccessProfile } from "@/lib/lead-access";
import { displayBrokerName } from "@/lib/broker-names";
import { supabase } from "@/lib/supabase";

export const SONIALIMA_CAPTURER = "__sonialima__";

export function PropertyCapturerSelect({
  propertyId,
  value,
  brokers,
  onChanged,
}: {
  propertyId: string;
  value?: string[];
  brokers: AccessProfile[];
  onChanged: (brokerIds: string[]) => void;
}) {
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [saved, setSaved] = useState(false);
  const sonialimaId = brokers.find(
    (broker) => broker.email.trim().toLowerCase() === "unassigned-institutional@example.invalid",
  )?.id;
  const normalizeCapturer = (capturerId?: string) =>
    capturerId === SONIALIMA_CAPTURER ? (sonialimaId ?? "") : (capturerId ?? "");
  const [selections, setSelections] = useState<string[]>(() => [
    normalizeCapturer(value?.[0]),
    normalizeCapturer(value?.[1]),
  ]);
  const capturerOptions = Array.from(
    new Map(brokers.map((broker) => [broker.id, broker])).values(),
  ).sort((left, right) => {
    if ((left.id === sonialimaId) !== (right.id === sonialimaId)) {
      return left.id === sonialimaId ? -1 : 1;
    }
    return (displayBrokerName(left.fullName) || left.email).localeCompare(
      displayBrokerName(right.fullName) || right.email,
      "pt-BR",
    );
  });

  useEffect(() => {
    setSelections([
      value?.[0] === SONIALIMA_CAPTURER ? (sonialimaId ?? "") : (value?.[0] ?? ""),
      value?.[1] === SONIALIMA_CAPTURER ? (sonialimaId ?? "") : (value?.[1] ?? ""),
    ]);
    setError("");
  }, [propertyId, value, sonialimaId]);

  const save = async () => {
    if (!selections[0]) {
      setError("Selecione ao menos um captador.");
      return;
    }
    if (selections[1] && selections[0] === selections[1]) {
      setError("Escolha dois captadores diferentes.");
      return;
    }
    setSaving(true);
    setError("");
    setSaved(false);
    const { error: saveError } = await supabase.rpc("set_property_capturers", {
      p_property_id: propertyId,
      p_selections: selections,
    });
    setSaving(false);
    if (saveError) {
      setError(saveError.message);
      return;
    }
    onChanged(selections);
    setSaved(true);
  };

  return (
    <div className="min-w-44" onPointerDown={(event) => event.stopPropagation()}>
      {[0, 1].map((position) => (
        <select
          key={position}
          aria-label={`Captador ${position + 1}`}
          title={error || "Um captador obrigatório e um segundo opcional"}
          value={selections[position] ?? ""}
          disabled={saving}
          onChange={(event) => {
            setSelections((current) => {
              const updated = [current[0] ?? "", current[1] ?? ""];
              updated[position] = event.target.value;
              return updated;
            });
            setError("");
            setSaved(false);
          }}
          className={`w-full rounded-lg border bg-background px-2 py-1.5 text-xs outline-none ${
            error ? "border-red-400/60 text-red-200" : "border-white/10"
          } ${position === 1 ? "mt-1.5" : ""}`}
        >
          <option value="">
            {position === 0 ? "Selecionar captador 1" : "Captador 2 (opcional)"}
          </option>
          {capturerOptions.map((broker) => (
            <option key={broker.id} value={broker.id}>
              {displayBrokerName(broker.fullName) || broker.email}
            </option>
          ))}
        </select>
      ))}
      <button
        type="button"
        disabled={saving || !selections[0]}
        onClick={() => void save()}
        className="mt-1.5 w-full rounded-lg border border-copper/40 bg-copper/10 px-2 py-1.5 text-[11px] font-medium text-copper transition hover:bg-copper/20 disabled:cursor-not-allowed disabled:opacity-50"
      >
        {saving ? "Salvando..." : "Salvar captadores"}
      </button>
      {error && <p className="mt-1 text-[10px] leading-tight text-red-300">{error}</p>}
      {saved && <p className="mt-1 text-[10px] text-emerald-300">Captadores salvos.</p>}
    </div>
  );
}

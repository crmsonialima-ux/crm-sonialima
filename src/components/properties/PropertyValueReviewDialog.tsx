import { ExternalLink, Loader2, X } from "lucide-react";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import type { Property } from "@/lib/properties";
import { supabase } from "@/lib/supabase";

type Decision = "" | "keep" | "change";

function formatIntegerDigits(value: string) {
  const digits = value.replace(/\D/g, "").replace(/^0+(?=\d)/, "");
  return digits ? Number(digits).toLocaleString("pt-BR") : "";
}

function propertyValue(value?: number) {
  return value
    ? value.toLocaleString("pt-BR", {
        style: "currency",
        currency: "BRL",
        minimumFractionDigits: 2,
      })
    : "Não informado";
}

export function PropertyValueReviewDialog({
  property,
  canRespond,
  notificationTitle,
  notificationBody,
  reviewRequestId,
  onClose,
  onSaved,
}: {
  property?: Property;
  canRespond: boolean;
  notificationTitle?: string;
  notificationBody?: string;
  reviewRequestId?: string;
  onClose: () => void;
  onSaved: (newValue?: number) => void;
}) {
  const [decision, setDecision] = useState<Decision>("");
  const [newValueDigits, setNewValueDigits] = useState("");
  const [changeNote, setChangeNote] = useState("");
  const [reviewText, setReviewText] = useState("");
  const [reviewTextRequested, setReviewTextRequested] = useState(false);
  const [sonialimaNote, setSoniaLimaNote] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    setDecision("");
    setNewValueDigits("");
    setChangeNote("");
    const draftKey = property?.id ? `sonialima-crm:property-review-draft:${property.id}` : "";
    try {
      const draft = draftKey
        ? (JSON.parse(sessionStorage.getItem(draftKey) ?? "null") as {
            decision?: Decision;
            newValueDigits?: string;
            changeNote?: string;
            reviewTextRequested?: boolean;
            reviewText?: string;
            sonialimaNote?: string;
          } | null)
        : null;
      setDecision(draft?.decision ?? "");
      setNewValueDigits(draft?.newValueDigits ?? "");
      setChangeNote(draft?.changeNote ?? "");
      setReviewTextRequested(draft?.reviewTextRequested ?? false);
      setReviewText(draft?.reviewText ?? "");
      setSoniaLimaNote(draft?.sonialimaNote ?? "");
    } catch {
      setReviewTextRequested(false);
      setReviewText("");
      setSoniaLimaNote("");
    }
    setError("");
  }, [property?.id, reviewRequestId]);

  useEffect(() => {
    if (!property?.id) return;
    sessionStorage.setItem(
      `sonialima-crm:property-review-draft:${property.id}`,
      JSON.stringify({
        decision,
        newValueDigits,
        changeNote,
        reviewTextRequested,
        reviewText,
        sonialimaNote,
      }),
    );
  }, [
    changeNote,
    decision,
    sonialimaNote,
    newValueDigits,
    property?.id,
    reviewText,
    reviewTextRequested,
  ]);

  if (!property) return null;

  const save = async () => {
    if (!decision) return setError("Escolha manter ou alterar o valor.");
    const newValue = Number(newValueDigits.replace(/\D/g, ""));
    if (decision === "change" && !newValue) return setError("Informe o novo valor do imóvel.");

    setSaving(true);
    setError("");
    try {
      let requestId = reviewRequestId ?? "";
      if (!requestId) {
        const { data: ensuredId, error: ensureError } = await supabase.rpc(
          "ensure_property_value_review",
          {
            p_property_id: property.id,
            p_property_title: property.title,
            p_property_address: property.address ?? "",
            p_current_value: property.value ?? null,
            p_public_url: property.publicUrl ?? "",
          },
        );
        if (ensureError) throw ensureError;
        requestId = String(ensuredId ?? "");
      }
      if (!requestId) throw new Error("Não foi possível identificar a revisão semanal.");

      const { error: responseError } = await supabase.rpc("respond_property_value_review_details", {
        p_request_id: requestId,
        p_decision: decision,
        p_new_value: decision === "change" ? newValue : null,
        p_change_note: decision === "change" ? changeNote : "",
        p_review_text: reviewText.trim(),
        p_sonialima_note: sonialimaNote.trim(),
        p_review_text_requested: reviewTextRequested,
      });
      if (responseError) throw responseError;

      sessionStorage.removeItem(`sonialima-crm:property-review-draft:${property.id}`);
      onSaved(decision === "change" ? newValue : undefined);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Não foi possível salvar a revisão.");
    } finally {
      setSaving(false);
    }
  };

  return (
    <div
      className="fixed inset-0 z-[70] flex items-center justify-center bg-black/75 p-3 sm:p-5"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      <div className="glass-strong max-h-[calc(100dvh-1.5rem)] w-full max-w-xl overflow-y-auto rounded-2xl border border-amber-400/30 p-4 shadow-2xl sm:p-6">
        <div className="flex items-start justify-between gap-4">
          <div>
            <p className="text-[11px] font-semibold uppercase tracking-[.2em] text-amber-400">
              Revisão de valor
            </p>
            <h2 className="mt-1 text-xl font-semibold text-foreground">
              {notificationTitle || property.title}
            </h2>
          </div>
          <button
            type="button"
            aria-label="Fechar"
            onClick={onClose}
            className="rounded-lg p-2 text-muted-foreground hover:bg-white/10 hover:text-foreground"
          >
            <X size={20} />
          </button>
        </div>

        {notificationBody && (
          <p className="mt-3 rounded-lg border border-amber-400/20 bg-amber-400/[.06] p-3 text-sm text-foreground">
            {notificationBody}
          </p>
        )}

        <div className="mt-4 rounded-xl border border-white/10 bg-white/[.03] p-4">
          <h3 className="font-semibold text-foreground">{property.title}</h3>
          <p className="mt-1 text-sm text-muted-foreground">
            {[property.address, property.neighborhood, property.city].filter(Boolean).join(" · ")}
          </p>
          <p className="mt-3 text-sm">
            Valor atual:{" "}
            <strong className="text-foreground">{propertyValue(property.value)}</strong>
          </p>
          {property.publicUrl && (
            <Button asChild size="sm" variant="outline" className="mt-3">
              <a href={property.publicUrl} target="_blank" rel="noopener noreferrer">
                <ExternalLink size={14} /> Ver imóvel
              </a>
            </Button>
          )}
        </div>

        {canRespond && (
          <div className="mt-4 grid gap-2 sm:grid-cols-2">
            <button
              type="button"
              aria-pressed={decision === "keep"}
              onClick={() => setDecision("keep")}
              className={`rounded-xl border p-4 text-left transition ${
                decision === "keep"
                  ? "border-emerald-400/50 bg-emerald-400/10 text-emerald-300"
                  : "border-white/10 bg-white/[.03] text-foreground"
              }`}
            >
              <strong className="block text-sm">Manter valor atual</strong>
              <span className="mt-1 block text-xs opacity-75">Nada será alterado no imóvel.</span>
            </button>
            <button
              type="button"
              aria-pressed={decision === "change"}
              onClick={() => setDecision("change")}
              className={`rounded-xl border p-4 text-left transition ${
                decision === "change"
                  ? "border-amber-400/50 bg-amber-400/10 text-amber-300"
                  : "border-white/10 bg-white/[.03] text-foreground"
              }`}
            >
              <strong className="block text-sm">Propor alteração</strong>
              <span className="mt-1 block text-xs opacity-75">
                O novo valor será enviado ao Administrador para aprovação.
              </span>
            </button>
          </div>
        )}

        {canRespond && (
          <div className="mt-4 space-y-3 rounded-xl border border-white/10 bg-white/[.02] p-4">
            <button
              type="button"
              aria-pressed={reviewTextRequested}
              onClick={() => setReviewTextRequested((current) => !current)}
              className={`w-full rounded-lg border px-3 py-2.5 text-left text-sm font-medium transition ${
                reviewTextRequested
                  ? "border-amber-400/50 bg-amber-400/10 text-amber-200"
                  : "border-white/10 bg-background text-foreground"
              }`}
            >
              {reviewTextRequested ? "Revisão do texto selecionada" : "Selecionar revisão do texto"}
            </button>
            {reviewTextRequested ? (
              <label className="block text-xs text-muted-foreground">
                Sugestão de texto (opcional)
                <textarea
                  value={reviewText}
                  onChange={(event) => setReviewText(event.target.value)}
                  placeholder="Escreva a versão revisada do texto que deverá ser utilizada no anúncio."
                  className="mt-1.5 min-h-28 w-full resize-y rounded-lg border border-white/10 bg-background px-3 py-2.5 text-sm text-foreground outline-none focus:border-amber-400/50"
                />
              </label>
            ) : null}
            <label className="block text-xs text-muted-foreground">
              Observação da Sônia Lima (opcional)
              <textarea
                value={sonialimaNote}
                onChange={(event) => setSoniaLimaNote(event.target.value)}
                placeholder="Acrescente uma orientação complementar, se necessário."
                className="mt-1.5 min-h-20 w-full resize-y rounded-lg border border-white/10 bg-background px-3 py-2.5 text-sm text-foreground outline-none focus:border-amber-400/50"
              />
            </label>
          </div>
        )}

        {canRespond && decision === "change" && (
          <div className="mt-4 space-y-3 rounded-xl border border-amber-400/20 p-4">
            <label className="block text-xs text-muted-foreground">
              Novo valor do imóvel
              <span className="mt-1.5 flex items-center rounded-lg border border-white/10 bg-background px-3 focus-within:border-amber-400/50">
                <span className="text-sm text-muted-foreground">R$</span>
                <input
                  inputMode="numeric"
                  value={formatIntegerDigits(newValueDigits)}
                  onChange={(event) => setNewValueDigits(event.target.value.replace(/\D/g, ""))}
                  placeholder="500.000"
                  className="min-w-0 flex-1 bg-transparent px-2 py-2.5 text-right text-sm text-foreground outline-none"
                />
                <span className="text-sm text-muted-foreground">,00</span>
              </span>
            </label>
            <label className="block text-xs text-muted-foreground">
              Observação da alteração
              <input
                value={changeNote}
                onChange={(event) => setChangeNote(event.target.value)}
                placeholder="Ex.: foto 3"
                className="mt-1.5 w-full rounded-lg border border-white/10 bg-background px-3 py-2.5 text-sm text-foreground outline-none focus:border-amber-400/50"
              />
            </label>
          </div>
        )}

        {error && (
          <p role="alert" className="mt-4 rounded-lg bg-red-400/10 p-3 text-sm text-red-200">
            {error}
          </p>
        )}

        <div className="mt-5 flex justify-end gap-2">
          <Button variant="ghost" onClick={onClose} disabled={saving}>
            {canRespond ? "Cancelar" : "Fechar"}
          </Button>
          {canRespond && (
            <Button
              className="bg-amber-500 text-black hover:bg-amber-400"
              onClick={() => void save()}
              disabled={saving || !decision}
            >
              {saving && <Loader2 size={16} className="animate-spin" />}
              Salvar resposta
            </Button>
          )}
        </div>
      </div>
    </div>
  );
}

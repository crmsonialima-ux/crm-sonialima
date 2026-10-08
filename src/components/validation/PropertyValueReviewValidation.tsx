import { Check, ExternalLink, Loader2, Pencil, RefreshCw, X } from "lucide-react";
import { useCallback, useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Panel } from "@/components/dashboard/Panel";
import { useAuth } from "@/components/auth/AuthProvider";
import { updatePropertyValue } from "@/lib/properties";
import { supabase } from "@/lib/supabase";
import { displayText } from "@/lib/display-text";

type PropertyReview = {
  id: string;
  property_id: string;
  review_week: string;
  property_title: string;
  property_address: string | null;
  public_url: string | null;
  current_value: number | null;
  decision: "pending" | "keep" | "change";
  new_value: number | null;
  change_note: string | null;
  requested_at: string;
  responded_at: string | null;
  approval_status: "not_required" | "pending" | "approved";
  approved_value: number | null;
  approved_at: string | null;
};

function formatIntegerDigits(value: string) {
  const digits = value.replace(/\D/g, "").replace(/^0+(?=\d)/, "");
  return digits ? Number(digits).toLocaleString("pt-BR") : "";
}

function money(value: number | null) {
  return value === null
    ? "Não informado"
    : Number(value).toLocaleString("pt-BR", {
        style: "currency",
        currency: "BRL",
        minimumFractionDigits: 2,
      });
}

export function PropertyValueReviewValidation() {
  const { profile } = useAuth();
  const [reviews, setReviews] = useState<PropertyReview[]>([]);
  const [loading, setLoading] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [valueDigits, setValueDigits] = useState("");
  const [savingId, setSavingId] = useState<string | null>(null);
  const [error, setError] = useState("");
  const isAdministrador = Boolean(
    profile?.isValidator || profile?.email?.trim().toLowerCase() === "crmsoniaallyson@gmail.com",
  );

  const load = useCallback(async () => {
    if (!isAdministrador) return;
    setLoading(true);
    const { data, error: loadError } = await supabase.rpc(
      "get_property_value_reviews_for_validation",
    );
    if (loadError) {
      setError(displayText(loadError.message));
    } else {
      setReviews((data ?? []) as PropertyReview[]);
      setError("");
    }
    setLoading(false);
  }, [isAdministrador]);

  useEffect(() => {
    void load();
    const timer = window.setInterval(() => void load(), 5_000);
    return () => window.clearInterval(timer);
  }, [load]);

  useEffect(() => {
    if (!reviews.length || typeof window === "undefined") return;
    const reviewRequestId = new URL(window.location.href).searchParams.get("reviewRequestId");
    if (!reviewRequestId) return;
    window.setTimeout(() => {
      document
        .getElementById(`property-review-${reviewRequestId}`)
        ?.scrollIntoView({ behavior: "smooth", block: "center" });
    }, 100);
  }, [reviews]);

  const approve = async (review: PropertyReview) => {
    const approvedValue = Number(
      (editingId === review.id ? valueDigits : String(review.new_value ?? "")).replace(/\D/g, ""),
    );
    if (!approvedValue) {
      setError("Informe um valor válido para o imóvel.");
      return;
    }

    setSavingId(review.id);
    setError("");
    try {
      await updatePropertyValue(review.property_id, approvedValue);
      const { error: approvalError } = await supabase.rpc("approve_property_value_review", {
        p_request_id: review.id,
        p_approved_value: approvedValue,
      });
      if (approvalError) throw approvalError;
      setEditingId(null);
      setValueDigits("");
      await load();
    } catch (reason) {
      setError(
        reason instanceof Error
          ? displayText(reason.message)
          : "N\u00e3o foi poss\u00edvel alterar o valor no CRM.",
      );
    } finally {
      setSavingId(null);
    }
  };

  if (!isAdministrador) return null;

  return (
    <div className="mb-6">
      <Panel
        title="Revisões semanais de imóveis"
        subtitle="Analise as propostas do acessocrm e confirme o valor que será aplicado no CRM."
      >
        <div className="mb-4 flex justify-end">
          <Button size="sm" variant="outline" onClick={() => void load()} disabled={loading}>
            <RefreshCw size={14} className={loading ? "animate-spin" : ""} /> Atualizar
          </Button>
        </div>
        {error && (
          <p role="alert" className="mb-4 rounded-lg bg-red-400/10 p-3 text-sm text-red-200">
            {error}
          </p>
        )}
        {!reviews.length ? (
          <p className="rounded-xl border border-white/5 px-4 py-8 text-center text-sm text-muted-foreground">
            Nenhuma revisão semanal registrada.
          </p>
        ) : (
          <div className="space-y-3">
            {reviews.map((review) => {
              const focusUrl = new URL("/imoveis", window.location.origin);
              focusUrl.searchParams.set("focusPropertyId", review.property_id);
              focusUrl.searchParams.set("notificationTitle", "Revisão semanal do imóvel");
              focusUrl.searchParams.set(
                "notificationBody",
                review.decision === "pending"
                  ? "Aguardando resposta do acessocrm."
                  : review.decision === "keep"
                    ? "O valor atual foi mantido."
                    : review.approval_status === "approved"
                      ? "A alteração foi aprovada e aplicada no CRM."
                      : "O novo valor está aguardando sua aprovação.",
              );
              return (
                <article
                  key={review.id}
                  id={`property-review-${review.id}`}
                  className={`rounded-xl border bg-white/[.025] p-4 ${
                    review.approval_status === "pending" ? "border-amber-400/35" : "border-white/10"
                  }`}
                >
                  <div className="flex flex-wrap items-start justify-between gap-3">
                    <div className="min-w-0">
                      <div className="flex flex-wrap items-center gap-2">
                        <span
                          className={`rounded-full px-2 py-1 text-[10px] font-semibold uppercase ${
                            review.decision === "pending" || review.approval_status === "pending"
                              ? "bg-amber-400/15 text-amber-300"
                              : review.decision === "keep"
                                ? "bg-sky-400/15 text-sky-300"
                                : "bg-emerald-400/15 text-emerald-300"
                          }`}
                        >
                          {review.decision === "pending"
                            ? "Aguardando"
                            : review.decision === "keep"
                              ? "Valor mantido"
                              : review.approval_status === "approved"
                                ? "Alterado no CRM"
                                : "Alteração proposta"}
                        </span>
                        <span className="text-[10px] text-muted-foreground">
                          Semana de{" "}
                          {new Date(`${review.review_week}T12:00:00`).toLocaleDateString("pt-BR")}
                        </span>
                      </div>
                      <h3 className="mt-2 font-semibold text-foreground">
                        {review.property_title}
                      </h3>
                      {review.property_address && (
                        <p className="mt-1 text-xs text-muted-foreground">
                          {review.property_address}
                        </p>
                      )}
                      <p className="mt-2 text-sm text-muted-foreground">
                        Valor anterior:{" "}
                        <strong className="text-foreground">{money(review.current_value)}</strong>
                        {review.decision === "change" && (
                          <>
                            {" "}
                            · Valor proposto:{" "}
                            <strong className="text-amber-300">{money(review.new_value)}</strong>
                          </>
                        )}
                      </p>
                      {review.approval_status === "approved" && (
                        <p className="mt-1 text-sm text-emerald-300">
                          Valor aplicado no CRM: <strong>{money(review.approved_value)}</strong>
                        </p>
                      )}
                      {review.change_note && (
                        <p className="mt-2 rounded-lg bg-white/[.04] px-3 py-2 text-xs text-foreground">
                          Observação: {review.change_note}
                        </p>
                      )}
                      <p className="mt-2 text-[10px] text-muted-foreground">
                        Solicitado em {new Date(review.requested_at).toLocaleString("pt-BR")}
                        {review.responded_at &&
                          ` · Respondido em ${new Date(review.responded_at).toLocaleString("pt-BR")}`}
                        {review.approved_at &&
                          ` · Aprovado em ${new Date(review.approved_at).toLocaleString("pt-BR")}`}
                      </p>
                    </div>
                    <div className="flex flex-wrap gap-2">
                      <Button asChild size="sm" variant="outline">
                        <a href={`${focusUrl.pathname}${focusUrl.search}`}>
                          <ExternalLink size={14} /> Abrir imóvel
                        </a>
                      </Button>
                      {review.public_url && (
                        <Button asChild size="sm" variant="ghost">
                          <a href={review.public_url} target="_blank" rel="noopener noreferrer">
                            Ver anúncio
                          </a>
                        </Button>
                      )}
                    </div>
                  </div>
                  {review.decision === "change" && review.approval_status === "pending" && (
                    <div className="mt-4 rounded-xl border border-amber-400/25 bg-amber-400/[.05] p-4">
                      <div className="flex flex-wrap items-center justify-between gap-3">
                        <div>
                          <p className="text-sm font-semibold text-foreground">
                            Alterar este valor no CRM?
                          </p>
                          <p className="mt-1 text-xs text-muted-foreground">
                            Confirme a proposta ou use o lápis para ajustar o valor antes de
                            aplicar.
                          </p>
                        </div>
                        {editingId !== review.id ? (
                          <div className="flex items-center gap-2">
                            <strong className="text-lg text-amber-300">
                              {money(review.new_value)}
                            </strong>
                            <Button
                              type="button"
                              size="icon"
                              variant="outline"
                              aria-label="Editar valor antes de aprovar"
                              onClick={() => {
                                setEditingId(review.id);
                                setValueDigits(String(Math.round(Number(review.new_value ?? 0))));
                                setError("");
                              }}
                            >
                              <Pencil size={15} />
                            </Button>
                          </div>
                        ) : (
                          <div className="flex items-center gap-2">
                            <label className="flex items-center rounded-lg border border-amber-400/40 bg-background px-3">
                              <span className="text-sm text-muted-foreground">R$</span>
                              <input
                                autoFocus
                                inputMode="numeric"
                                aria-label="Valor aprovado para o imóvel"
                                value={formatIntegerDigits(valueDigits)}
                                onChange={(event) =>
                                  setValueDigits(event.target.value.replace(/\D/g, ""))
                                }
                                className="w-32 bg-transparent px-2 py-2 text-right text-sm text-foreground outline-none"
                              />
                              <span className="text-sm text-muted-foreground">,00</span>
                            </label>
                            <Button
                              type="button"
                              size="icon"
                              variant="ghost"
                              aria-label="Cancelar ajuste do valor"
                              onClick={() => {
                                setEditingId(null);
                                setValueDigits("");
                              }}
                            >
                              <X size={15} />
                            </Button>
                          </div>
                        )}
                      </div>
                      <div className="mt-4 flex justify-end">
                        <Button
                          className="bg-emerald-500 text-black hover:bg-emerald-400"
                          disabled={savingId === review.id}
                          onClick={() => void approve(review)}
                        >
                          {savingId === review.id ? (
                            <Loader2 size={16} className="animate-spin" />
                          ) : (
                            <Check size={16} />
                          )}
                          Sim, alterar no CRM
                        </Button>
                      </div>
                    </div>
                  )}
                </article>
              );
            })}
          </div>
        )}
      </Panel>
    </div>
  );
}

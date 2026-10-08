import { FileUp, Loader2, Eye } from "lucide-react";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import type { ManagedLead } from "@/lib/lead-access";
import { supabase } from "@/lib/supabase";

const BUCKET = "lead-documents";

export function PostAcceptanceQualification({ lead, currentUserId }: { lead: ManagedLead; currentUserId?: string }) {
  const [called, setCalled] = useState<"" | "yes" | "no">(lead.postAcceptanceCallMade === undefined ? "" : lead.postAcceptanceCallMade ? "yes" : "no");
  const [result, setResult] = useState<"" | "Falou com o cliente" | "Não atendeu">((lead.postAcceptanceCallResult as any) ?? "");
  const [interaction, setInteraction] = useState(lead.postAcceptanceInteraction ?? "");
  const [whatsapp, setWhatsapp] = useState<"" | "yes" | "no">(lead.postAcceptanceWhatsappContacted === undefined ? "" : lead.postAcceptanceWhatsappContacted ? "yes" : "no");
  const [hasWhatsapp, setHasWhatsapp] = useState<"" | "yes" | "no">(lead.postAcceptanceWhatsappHasWhatsapp === undefined ? "" : lead.postAcceptanceWhatsappHasWhatsapp ? "yes" : "no");
  const [path, setPath] = useState(lead.postAcceptanceWhatsappPrintPath ?? "");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  
  if (lead.assignmentStatus !== "accepted" || !lead.postAcceptanceQualificationDeadlineAt) return null;
  const mine = lead.ownerId === currentUserId;
  const done = Boolean(lead.postAcceptanceQualificationCompletedAt);
  const expired = Boolean(lead.postAcceptanceQualificationExpiredAt);
  
  async function upload(file?: File) {
    if (!file) return;
    setBusy(true);
    setError("");
    const ext = file.name.includes(".") ? `.${file.name.split(".").pop()}` : "";
    const next = `lead-qualification/${lead.id}/whatsapp-print${ext}`;
    const { error: e } = await supabase.storage.from(BUCKET).upload(next, file, { contentType: file.type || undefined, upsert: true });
    if (e) setError(e.message);
    else setPath(next);
    setBusy(false);
  }
  
  async function save() {
    setBusy(true);
    setError("");
    const { error: e } = await supabase.rpc("save_post_acceptance_lead_qualification", {
      p_lead_id: lead.id,
      p_call_made: called === "yes",
      p_call_result: called === "yes" ? (result || null) : null,
      p_interaction: called === "yes" && result === "Falou com o cliente" ? interaction || null : null,
      p_whatsapp: called === "yes" && result === "Não atendeu" ? (whatsapp === "yes" ? true : whatsapp === "no" ? false : null) : null,
      p_print_path: called === "yes" && result === "Não atendeu" && whatsapp === "yes" ? path || null : null,
      p_has_whatsapp: called === "no" || (called === "yes" && result === "Não atendeu" && whatsapp === "no") ? (hasWhatsapp === "yes" ? true : hasWhatsapp === "no" ? false : null) : null
    });
    if (e) setError(e.message);
    else window.location.reload();
    setBusy(false);
  }

  async function viewPrint() {
    if (!path) return;

    const printWindow = window.open("", "_blank");
    if (!printWindow) {
      setError("O navegador bloqueou a abertura do anexo. Permita pop-ups para este site.");
      return;
    }

    setBusy(true);

    const { data, error: signedUrlError } = await supabase.storage
      .from(BUCKET)
      .createSignedUrl(path, 300);

    setBusy(false);

    if (signedUrlError || !data?.signedUrl) {
      printWindow.close();
      setError("N?o foi poss?vel carregar o anexo.");
      return;
    }

    printWindow.location.href = data.signedUrl;
  }

  return (
    <section className="mt-5 rounded-xl border border-copper/30 bg-copper/5 p-4">
      <h3 className="text-sm font-semibold">Qualificação após aceite</h3>
      <div className="flex items-center justify-between mt-1">
        <p className="text-xs text-muted-foreground">
          {done ? "Concluída e registrada no histórico." : expired ? "Prazo expirado; aguardando redistribuição pelo Administrador." : `Prazo: ${new Date(lead.postAcceptanceQualificationDeadlineAt).toLocaleString("pt-BR")}.`}
        </p>
        {done && path && (
          <Button size="sm" variant="outline" className="h-7 text-xs" onClick={() => void viewPrint()} disabled={busy}>
            {busy ? <Loader2 size={12} className="mr-1 animate-spin"/> : <Eye size={12} className="mr-1"/>}
            Ver Print
          </Button>
        )}
      </div>
      {mine && !done && !expired && (
        <div className="mt-3 space-y-3 text-sm">
          <label>
            Já ligou para o cliente?
            <select value={called} onChange={e => setCalled(e.target.value as typeof called)} className="ml-2 rounded border bg-transparent p-1">
              <option value="">Selecione</option>
              <option value="yes">Sim</option>
              <option value="no">Não</option>
            </select>
          </label>

          {called === "no" && (
            <div className="space-y-2 mt-2">
              <label>
                O cliente possui WhatsApp?
                <select value={hasWhatsapp} onChange={e => setHasWhatsapp(e.target.value as typeof hasWhatsapp)} className="ml-2 rounded border bg-transparent p-1">
                  <option value="">Selecione</option>
                  <option value="yes">Sim</option>
                  <option value="no">Não</option>
                </select>
              </label>
              {hasWhatsapp === "yes" && (
                <p className="text-xs text-red-500 font-medium">Você precisa chamar o cliente no WhatsApp para não sofrer penalidade.</p>
              )}
            </div>
          )}
          
          {called === "yes" && (
            <>
              <label className="block">
                Resultado da ligação:
                <select value={result} onChange={e => setResult(e.target.value as typeof result)} className="ml-2 rounded border bg-transparent p-1">
                  <option value="">Selecione</option>
                  <option value="Falou com o cliente">Falou com o cliente</option>
                  <option value="Não atendeu">Não atendeu</option>
                </select>
              </label>

              {result === "Falou com o cliente" && (
                <textarea value={interaction} onChange={e => setInteraction(e.target.value)} placeholder="Como foi a interação?" className="min-h-20 w-full rounded border bg-transparent p-2 mt-2" />
              )}

              {result === "Não atendeu" && (
                <div className="space-y-2 mt-2">
                  <label>
                    Chamou no WhatsApp?
                    <select value={whatsapp} onChange={e => setWhatsapp(e.target.value as typeof whatsapp)} className="ml-2 rounded border bg-transparent p-1">
                      <option value="">Selecione</option>
                      <option value="yes">Sim</option>
                      <option value="no">Não</option>
                    </select>
                  </label>
                  {whatsapp === "yes" && (
                    <label className="flex items-center gap-2 text-xs cursor-pointer">
                      <FileUp size={15}/> Anexar print
                      <input type="file" className="sr-only" onChange={e => void upload(e.target.files?.[0])}/>
                      {path && "Print selecionado"}
                    </label>
                  )}
                  {whatsapp === "no" && (
                    <div className="space-y-2 mt-2">
                      <label>
                        O cliente possui WhatsApp?
                        <select value={hasWhatsapp} onChange={e => setHasWhatsapp(e.target.value as typeof hasWhatsapp)} className="ml-2 rounded border bg-transparent p-1">
                          <option value="">Selecione</option>
                          <option value="yes">Sim</option>
                          <option value="no">Não</option>
                        </select>
                      </label>
                      {hasWhatsapp === "yes" && (
                        <p className="text-xs text-red-500 font-medium">Você precisa chamar o cliente no WhatsApp para não sofrer penalidade.</p>
                      )}
                    </div>
                  )}
                </div>
              )}
            </>
          )}

          <Button size="sm" disabled={busy || !called} onClick={() => void save()}>
            {busy && <Loader2 size={14} className="animate-spin"/>}
            Salvar qualificação
          </Button>
          {error && <p className="text-xs text-red-500">{error}</p>}
        </div>
      )}
    </section>
  );
}

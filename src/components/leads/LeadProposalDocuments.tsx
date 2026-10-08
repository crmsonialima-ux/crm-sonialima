import { Download, FileUp, Loader2 } from "lucide-react";
import { useCallback, useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { supabase } from "@/lib/supabase";

const BUCKET = "lead-documents";
const DOCUMENTS = [
  { id: "certidao-onus", label: "Certidão de Ônus" },
  { id: "certidao-iptu", label: "Certidão de IPTU" },
  { id: "pgfn", label: "PGFN" },
  { id: "tjdft", label: "TJDFT" },
  { id: "trf1-criminal", label: "TRF1 Criminal" },
  { id: "trf1-civil", label: "TRF1 Civil" },
  { id: "trt10", label: "TRT10" },
  { id: "tst", label: "TST" },
  { id: "sefaz-df", label: "Sefaz DF" },
] as const;
type DocumentId = (typeof DOCUMENTS)[number]["id"];

export function LeadProposalDocuments({ leadId, leadName }: { leadId: string; leadName: string }) {
  const [files, setFiles] = useState<Record<DocumentId, string | undefined>>(
    {} as Record<DocumentId, string | undefined>,
  );
  const [loading, setLoading] = useState(true);
  const [uploading, setUploading] = useState<DocumentId>();
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    setLoading(true);
    const { data, error: listError } = await supabase.storage
      .from(BUCKET)
      .list(leadId, { limit: 100 });
    if (listError) {
      setError(
        "Não foi possível carregar os documentos. Verifique se o armazenamento foi configurado.",
      );
      setLoading(false);
      return;
    }
    const next = {} as Record<DocumentId, string | undefined>;
    for (const documentItem of DOCUMENTS) {
      next[documentItem.id] = data?.find(
        (file) => file.name === documentItem.id || file.name.startsWith(`${documentItem.id}.`),
      )?.name;
    }
    setFiles(next);
    setLoading(false);
  }, [leadId]);

  useEffect(() => {
    void load();
  }, [load]);

  const upload = async (documentId: DocumentId, file?: File) => {
    if (!file) return;
    setUploading(documentId);
    setError("");
    const extension = file.name.includes(".") ? `.${file.name.split(".").pop()}` : "";
    const { error: uploadError } = await supabase.storage
      .from(BUCKET)
      .upload(`${leadId}/${documentId}${extension}`, file, {
        upsert: true,
        contentType: file.type || undefined,
      });
    if (uploadError) setError(`Não foi possível anexar o documento: ${uploadError.message}`);
    else await load();
    setUploading(undefined);
  };

  const download = async (fileName: string) => {
    const { data, error: downloadError } = await supabase.storage
      .from(BUCKET)
      .download(`${leadId}/${fileName}`);
    if (downloadError || !data) {
      setError("Não foi possível baixar o documento.");
      return;
    }
    const url = URL.createObjectURL(data);
    const link = document.createElement("a");
    link.href = url;
    link.download = `${leadName} - ${fileName}`;
    document.body.appendChild(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
  };

  return (
    <section className="mt-5 border-t border-white/10 pt-4">
      <h3 className="text-sm font-medium">Documentos da proposta</h3>
      <p className="mt-1 text-xs text-muted-foreground">
        O lead já está em Proposta. Anexe os nove documentos pendentes sem bloquear esta etapa.
      </p>
      <div className="mt-3 space-y-2">
        {DOCUMENTS.map((documentItem) => {
          const fileName = files[documentItem.id];
          const attached = Boolean(fileName);
          return (
            <div
              key={documentItem.id}
              className="flex items-center gap-2 rounded-lg border border-white/10 bg-white/[0.03] px-3 py-2.5"
            >
              <span
                className={`min-w-0 flex-1 text-sm font-medium ${attached ? "text-emerald-300" : "text-red-300"}`}
              >
                {documentItem.label}
              </span>
              {attached && (
                <Button
                  type="button"
                  variant="ghost"
                  size="icon"
                  aria-label={`Baixar ${documentItem.label}`}
                  onClick={() => fileName && void download(fileName)}
                >
                  <Download size={16} />
                </Button>
              )}
              <label className="inline-flex cursor-pointer items-center gap-1 rounded-md border border-white/10 px-2 py-1.5 text-xs font-medium hover:border-copper/50">
                {uploading === documentItem.id ? (
                  <Loader2 size={14} className="animate-spin" />
                ) : (
                  <FileUp size={14} />
                )}
                {attached ? "Substituir" : "Anexar"}
                <input
                  type="file"
                  className="sr-only"
                  disabled={Boolean(uploading)}
                  onChange={(event) => {
                    void upload(documentItem.id, event.target.files?.[0]);
                    event.currentTarget.value = "";
                  }}
                />
              </label>
            </div>
          );
        })}
      </div>
      {loading && (
        <p className="mt-3 flex items-center gap-2 text-xs text-muted-foreground">
          <Loader2 size={14} className="animate-spin" /> Carregando documentos...
        </p>
      )}
      {error && (
        <p role="alert" className="mt-3 text-xs text-red-300">
          {error}
        </p>
      )}
    </section>
  );
}

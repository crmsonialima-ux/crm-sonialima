import { Download, FileUp, Loader2, Paperclip } from "lucide-react";
import { useCallback, useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import type { Property } from "@/lib/properties";
import { supabase } from "@/lib/supabase";

const BUCKET = "property-documents";
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
type ClearanceStatus = "" | "Nada consta" | "Consta";

export function PropertyDocumentsDialog({ property }: { property: Property }) {
  const [open, setOpen] = useState(false);
  const [files, setFiles] = useState<Record<DocumentId, string | undefined>>(
    {} as Record<DocumentId, string | undefined>,
  );
  const [loading, setLoading] = useState(false);
  const [uploading, setUploading] = useState<DocumentId>();
  const [savingStatus, setSavingStatus] = useState<DocumentId>();
  const [clearance, setClearance] = useState<Record<DocumentId, ClearanceStatus>>(
    {} as Record<DocumentId, ClearanceStatus>,
  );
  const [error, setError] = useState("");
  const folder = property.id;

  const loadDocuments = useCallback(async () => {
    setLoading(true);
    setError("");
    const [documentsResult, clearanceResult] = await Promise.all([
      supabase.storage.from(BUCKET).list(folder, { limit: 100 }),
      supabase
        .from("crm_property_document_clearance_status")
        .select("document_id, status")
        .eq("property_id", folder),
    ]);
    const { data, error: listError } = documentsResult;
    if (listError) {
      setError(
        "Não foi possível carregar os documentos. Verifique se o armazenamento foi configurado.",
      );
      setLoading(false);
      return;
    }
    const next = {} as Record<DocumentId, string | undefined>;
    for (const document of DOCUMENTS) {
      const matchingFile = data?.find(
        (file) => file.name === document.id || file.name.startsWith(`${document.id}.`),
      );
      next[document.id] = matchingFile?.name;
    }
    setFiles(next);
    if (clearanceResult.error) {
      setError("Não foi possível carregar o consta/nada consta dos documentos.");
    } else {
      setClearance(
        Object.fromEntries(
          (clearanceResult.data ?? []).map((item) => [item.document_id, item.status]),
        ) as Record<DocumentId, ClearanceStatus>,
      );
    }
    setLoading(false);
  }, [folder]);

  useEffect(() => {
    if (open) void loadDocuments();
  }, [loadDocuments, open]);

  const upload = async (documentId: DocumentId, file?: File) => {
    if (!file) return;
    setUploading(documentId);
    setError("");
    const extension = file.name.includes(".") ? `.${file.name.split(".").pop()}` : "";
    const fileName = `${documentId}${extension}`;
    const { error: uploadError } = await supabase.storage
      .from(BUCKET)
      .upload(`${folder}/${fileName}`, file, { upsert: true, contentType: file.type || undefined });
    if (uploadError) setError(`Não foi possível anexar o documento: ${uploadError.message}`);
    else await loadDocuments();
    setUploading(undefined);
  };

  const download = async (fileName: string) => {
    setError("");
    const { data, error: downloadError } = await supabase.storage
      .from(BUCKET)
      .download(`${folder}/${fileName}`);
    if (downloadError || !data) {
      setError("Não foi possível baixar o documento.");
      return;
    }
    const url = URL.createObjectURL(data);
    const link = document.createElement("a");
    link.href = url;
    link.download = `${property.title} - ${fileName}`;
    document.body.appendChild(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
  };

  const updateClearance = async (documentId: DocumentId, status: ClearanceStatus) => {
    setSavingStatus(documentId);
    setError("");
    const { error: statusError } = await supabase.rpc("set_property_document_clearance_status", {
      p_property_id: property.id,
      p_document_id: documentId,
      p_status: status,
    });
    if (statusError) setError(statusError.message);
    else setClearance((current) => ({ ...current, [documentId]: status }));
    setSavingStatus(undefined);
  };

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <Button
        variant="ghost"
        size="icon"
        aria-label={`Anexar documentos de ${property.title}`}
        onClick={() => setOpen(true)}
      >
        <Paperclip size={15} />
      </Button>
      <DialogContent className="glass-strong max-h-[calc(100dvh-2rem)] overflow-y-auto border-white/10 text-foreground sm:max-w-xl">
        <DialogHeader>
          <DialogTitle>Documentos do imóvel</DialogTitle>
          <DialogDescription>{property.title}</DialogDescription>
        </DialogHeader>
        <div className="space-y-2">
          {DOCUMENTS.map((documentItem) => {
            const fileName = files[documentItem.id];
            const attached = Boolean(fileName);
            const isUploading = uploading === documentItem.id;
            return (
              <div
                key={documentItem.id}
                className="flex flex-wrap items-center gap-2 rounded-lg border border-white/10 bg-white/[0.03] px-3 py-2.5"
              >
                <span
                  className={`min-w-0 flex-1 text-sm font-medium ${attached ? "text-emerald-300" : "text-red-300"}`}
                >
                  {documentItem.label}
                </span>
                <select
                  aria-label={`Consta ou nada consta de ${documentItem.label}`}
                  value={clearance[documentItem.id] ?? ""}
                  disabled={savingStatus === documentItem.id}
                  onChange={(event) =>
                    void updateClearance(documentItem.id, event.target.value as ClearanceStatus)
                  }
                  className={`rounded-md border border-white/10 bg-white/[0.03] px-2 py-1.5 text-xs outline-none disabled:cursor-not-allowed disabled:opacity-70 ${
                    clearance[documentItem.id] === "Nada consta"
                      ? "text-emerald-300"
                      : clearance[documentItem.id] === "Consta"
                        ? "text-red-300"
                        : "text-muted-foreground"
                  }`}
                >
                  <option value="">Selecionar</option>
                  <option value="Nada consta">Nada consta</option>
                  <option value="Consta">Consta</option>
                </select>
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
                  {isUploading ? (
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
          <div className="flex items-center justify-center gap-2 py-3 text-sm text-muted-foreground">
            <Loader2 size={16} className="animate-spin" /> Carregando documentos...
          </div>
        )}
        {error && (
          <p role="alert" className="text-sm text-red-300">
            {error}
          </p>
        )}
      </DialogContent>
    </Dialog>
  );
}

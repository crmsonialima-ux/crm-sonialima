import { useQuery, useQueryClient } from "@tanstack/react-query";
import { CheckCircle2, Download, Loader2, Paperclip } from "lucide-react";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { supabase } from "@/lib/supabase";

const required = [
  ["neoenergia", "Neoenergia"],
  ["condominio", "Condomínio"],
  ["caesb", "CAESB"],
  ["iptu", "Alteração de nome no IPTU"],
] as const;
type Document = {
  sale_id: string;
  document_kind: string;
  storage_path: string;
  file_name: string;
  uploaded_at: string;
};

export function SaleTransferDocuments({
  saleId,
  canUpload,
  dueAt,
  onCompleted,
}: {
  saleId: string;
  canUpload: boolean;
  dueAt?: string | null;
  onCompleted: () => void;
}) {
  const queryClient = useQueryClient();
  const [uploading, setUploading] = useState<string | null>(null);
  const [error, setError] = useState("");
  const documents = useQuery({
    queryKey: ["sale-transfer-documents", saleId],
    queryFn: async () => {
      const { data, error: queryError } = await supabase
        .from("crm_sale_delivery_documents")
        .select("sale_id,document_kind,storage_path,file_name,uploaded_at")
        .eq("sale_id", saleId);
      if (queryError) throw queryError;
      return (data ?? []) as Document[];
    },
  });
  const uploaded = new Map((documents.data ?? []).map((item) => [item.document_kind, item]));
  const complete = uploaded.size === 4;

  async function upload(kind: string, file: File) {
    setError("");
    if (
      !file ||
      !["application/pdf", "image/jpeg", "image/png", "image/webp"].includes(file.type)
    ) {
      setError("Envie um PDF, JPG, PNG ou WebP.");
      return;
    }
    if (file.size > 10 * 1024 * 1024) {
      setError("O arquivo deve ter até 10 MB.");
      return;
    }
    setUploading(kind);
    const extension =
      file.name
        .split(".")
        .pop()
        ?.replace(/[^a-z0-9]/gi, "")
        .toLowerCase() || "pdf";
    const path = `${saleId}/${kind}/${crypto.randomUUID()}.${extension}`;
    try {
      const { error: storageError } = await supabase.storage
        .from("sale-delivery-documents")
        .upload(path, file, { contentType: file.type });
      if (storageError) throw storageError;
      const { error: saveError } = await supabase.rpc("save_sale_delivery_document", {
        p_sale_id: saleId,
        p_document_kind: kind,
        p_storage_path: path,
        p_file_name: file.name,
      });
      if (saveError) throw saveError;
      await queryClient.invalidateQueries({ queryKey: ["sale-transfer-documents", saleId] });
      await queryClient.invalidateQueries({ queryKey: ["agenda"] });
      if (uploaded.size === 3 && !uploaded.has(kind)) onCompleted();
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Não foi possível anexar o arquivo.");
    } finally {
      setUploading(null);
    }
  }
  async function download(path: string) {
    setError("");
    const { data, error: downloadError } = await supabase.storage
      .from("sale-delivery-documents")
      .download(path);
    if (downloadError || !data) {
      setError(downloadError?.message ?? "Não foi possível abrir o arquivo.");
      return;
    }
    const url = URL.createObjectURL(data);
    window.open(url, "_blank", "noopener");
    window.setTimeout(() => URL.revokeObjectURL(url), 60_000);
  }

  return (
    <div
      className={`mt-4 rounded-xl border p-4 ${complete ? "border-emerald-400/40 bg-emerald-500/10" : "border-red-400/40 bg-red-500/10"}`}
    >
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className={`font-semibold ${complete ? "text-emerald-300" : "text-red-300"}`}>
          {complete ? "Transferências concluídas" : "Transferências pendentes"}
        </p>
        <span className="text-xs text-muted-foreground">{uploaded.size}/4 anexos</span>
      </div>
      <p className="mt-1 text-xs text-muted-foreground">
        Prazo de 48 horas: {dueAt ? new Date(dueAt).toLocaleString("pt-BR") : "—"}
      </p>
      {documents.error && (
        <p role="alert" className="mt-2 text-sm text-red-300">
          {documents.error.message}
        </p>
      )}
      {error && (
        <p role="alert" className="mt-2 text-sm text-red-300">
          {error}
        </p>
      )}
      <div className="mt-3 grid gap-2 sm:grid-cols-2">
        {required.map(([kind, label]) => {
          const document = uploaded.get(kind);
          return (
            <div key={kind} className="rounded-lg border border-white/10 bg-background/50 p-3">
              <div className="flex items-center gap-2 text-sm">
                {document ? (
                  <CheckCircle2 size={16} className="text-emerald-300" />
                ) : (
                  <Paperclip size={16} className="text-red-300" />
                )}
                <span>{label}</span>
              </div>
              {document ? (
                <Button
                  size="sm"
                  variant="ghost"
                  className="mt-2 max-w-full"
                  onClick={() => void download(document.storage_path)}
                >
                  <Download size={14} className="mr-1" />{" "}
                  <span className="truncate">{document.file_name}</span>
                </Button>
              ) : (
                <p className="mt-2 text-xs text-red-300">Aguardando comprovante</p>
              )}
              {canUpload && (
                <label className="mt-2 inline-flex cursor-pointer items-center rounded-lg border border-white/10 px-2 py-1.5 text-xs hover:bg-white/5">
                  {uploading === kind ? (
                    <Loader2 size={14} className="mr-1 animate-spin" />
                  ) : (
                    <Paperclip size={14} className="mr-1" />
                  )}
                  {document ? "Substituir" : "Anexar"}
                  <input
                    type="file"
                    accept="application/pdf,image/jpeg,image/png,image/webp"
                    className="sr-only"
                    disabled={Boolean(uploading)}
                    onChange={(event) => {
                      const file = event.currentTarget.files?.[0];
                      if (file) void upload(kind, file);
                      event.currentTarget.value = "";
                    }}
                  />
                </label>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}

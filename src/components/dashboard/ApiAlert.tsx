import { AlertTriangle, Settings2, WifiOff } from "lucide-react";

export function ApiAlert({ variant }: { variant: "not-configured" | "unavailable" }) {
  if (variant === "not-configured") {
    return (
      <div className="glass anim-float-in mb-6 flex flex-wrap items-center gap-3 rounded-2xl border border-copper/20 bg-copper/[0.04] p-4">
        <div className="grid h-10 w-10 place-items-center rounded-xl border border-copper/20 bg-copper/10 text-copper">
          <Settings2 size={18} strokeWidth={1.75} />
        </div>
        <div className="min-w-0 flex-1">
          <div className="text-sm font-semibold text-foreground">API não configurada</div>
          <div className="text-xs text-muted-foreground">
            Cole a URL do Web App do Google Apps Script em <code className="rounded bg-white/5 px-1.5 py-0.5 font-mono text-[11px] text-copper">src/config/config.ts</code> — os dados aparecerão automaticamente.
          </div>
        </div>
      </div>
    );
  }
  return (
    <div className="glass anim-float-in mb-6 flex flex-wrap items-center gap-3 rounded-2xl border border-rose-400/20 bg-rose-500/[0.04] p-4">
      <div className="grid h-10 w-10 place-items-center rounded-xl border border-rose-400/20 bg-rose-500/10 text-rose-300">
        <WifiOff size={18} strokeWidth={1.75} />
      </div>
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2 text-sm font-semibold text-foreground">
          <AlertTriangle size={14} className="text-rose-300" /> API indisponível
        </div>
        <div className="text-xs text-muted-foreground">
          Não foi possível ler a planilha. Verifique se o Web App está publicado como "Qualquer pessoa" e se o JSON está no formato esperado. Nova tentativa automática em instantes.
        </div>
      </div>
    </div>
  );
}
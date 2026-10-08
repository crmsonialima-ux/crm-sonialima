import { X } from "lucide-react";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { displayText } from "@/lib/display-text";

type NotificationContext = { title: string; body: string } | null;

export function NotificationSubjectDialog() {
  const [context, setContext] = useState<NotificationContext>(null);

  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const opensRealRecord =
      params.has("focusLeadId") ||
      params.has("focusPropertyId") ||
      params.has("focusAgendaId") ||
      params.has("reviewRequestId");
    if (opensRealRecord) return;
    const title = params.get("notificationTitle") ?? "";
    const body = params.get("notificationBody") ?? "";
    if (title || body) setContext({ title, body });
  }, []);

  const close = () => {
    setContext(null);
    const url = new URL(window.location.href);
    for (const key of [
      "notificationId",
      "notificationKind",
      "notificationTitle",
      "notificationBody",
    ])
      url.searchParams.delete(key);
    window.history.replaceState({}, "", `${url.pathname}${url.search}${url.hash}`);
  };

  if (!context) return null;

  return (
    <div
      className="pointer-events-auto fixed inset-0 z-[80] flex items-center justify-center bg-black/75 p-3"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) close();
      }}
    >
      <div className="glass-strong w-full max-w-lg rounded-2xl border border-white/15 p-5 shadow-2xl">
        <div className="flex items-start justify-between gap-4">
          <div>
            <p className="text-[10px] font-semibold uppercase tracking-[.2em] text-copper">
              Assunto da notificação
            </p>
            <h2 className="mt-2 text-xl font-semibold text-foreground">
              {displayText(context.title || "Notificação")}
            </h2>
          </div>
          <button
            type="button"
            aria-label="Fechar assunto"
            onClick={close}
            className="rounded-lg p-2 text-muted-foreground hover:bg-white/10 hover:text-foreground"
          >
            <X size={20} />
          </button>
        </div>
        {context.body && (
          <p className="mt-4 whitespace-pre-wrap rounded-xl bg-white/[.04] p-4 text-sm leading-relaxed text-foreground">
            {displayText(context.body)}
          </p>
        )}
        <div className="mt-5 flex justify-end">
          <Button onClick={close}>Fechar</Button>
        </div>
      </div>
    </div>
  );
}

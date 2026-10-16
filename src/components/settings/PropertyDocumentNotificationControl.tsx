import { BellRing, CalendarClock, Loader2, ShieldCheck } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useAdministradorOperationalSettings } from "@/lib/operational-settings";

export function PropertyDocumentNotificationControl() {
  const { query, propertyDocumentNotificationsMutation, deferredLeadsMutation } =
    useAdministradorOperationalSettings();

  if (query.isLoading) {
    return (
      <div className="flex items-center gap-2 rounded-xl border border-white/10 bg-white/[0.02] p-4 text-sm text-muted-foreground">
        <Loader2 size={16} className="animate-spin" /> Carregando controles operacionais…
      </div>
    );
  }

  if (query.error || !query.data) {
    return (
      <div
        role="alert"
        className="rounded-xl border border-red-400/30 bg-red-400/10 p-4 text-sm text-red-200"
      >
        <p>
          Não foi possível carregar os controles operacionais:{" "}
          {query.error?.message ?? "resposta inválida do CRM."}
        </p>
        <Button
          type="button"
          size="sm"
          variant="outline"
          className="mt-3"
          onClick={() => void query.refetch()}
        >
          Tentar novamente
        </Button>
      </div>
    );
  }

  const settings = query.data;
  const documentsPending = propertyDocumentNotificationsMutation.isPending;
  const leadsPending = deferredLeadsMutation.isPending;

  return (
    <section className="space-y-4 rounded-2xl border border-copper/20 bg-copper/[0.04] p-4 sm:p-5">
      <div className="flex items-start gap-3">
        <span className="grid h-9 w-9 shrink-0 place-items-center rounded-lg bg-copper/10 text-copper">
          <ShieldCheck size={18} />
        </span>
        <div>
          <h3 className="text-sm font-semibold text-foreground">
            Controles operacionais do crmallyson
          </h3>
          <p className="mt-1 text-xs leading-relaxed text-muted-foreground">
            Estas alterações são persistidas imediatamente no CRM e valem para toda a equipe.
          </p>
        </div>
      </div>

      <OperationalControl
        icon={BellRing}
        title="Notificações dos anexos dos imóveis"
        description="Controla os três lembretes diários de documentos pendentes, enviados às 10:30, 13:30 e 16:00. Quando desativados, nenhum novo lembrete de imóvel será disparado até crmallyson ativá-los novamente; os lembretes de propostas continuam normalmente."
        enabled={settings.propertyDocumentNotificationsEnabled}
        enabledLabel="Notificações ativas"
        disabledLabel="Notificações desativadas"
        pending={documentsPending}
        error={propertyDocumentNotificationsMutation.error}
        onChange={(nextEnabled) => propertyDocumentNotificationsMutation.mutate(nextEnabled)}
      />

      <OperationalControl
        icon={CalendarClock}
        title="Enviar novos leads às 9h do dia seguinte"
        description="Quando ativado, os novos leads cadastrados ficam aguardando e entram na esteira somente às 9:00 do dia seguinte. Ao desativar, apenas os leads cadastrados depois voltam ao fluxo normal; os que já foram programados continuam reservados para as 9h."
        enabled={settings.deferNewLeadsToNextDayNine}
        enabledLabel="Envio no dia seguinte ativo"
        disabledLabel="Envio no dia seguinte desativado"
        pending={leadsPending}
        error={deferredLeadsMutation.error}
        onChange={(nextEnabled) => deferredLeadsMutation.mutate(nextEnabled)}
      />
    </section>
  );
}

function OperationalControl({
  icon: Icon,
  title,
  description,
  enabled,
  enabledLabel,
  disabledLabel,
  pending,
  error,
  onChange,
}: {
  icon: typeof BellRing;
  title: string;
  description: string;
  enabled: boolean;
  enabledLabel: string;
  disabledLabel: string;
  pending: boolean;
  error: Error | null;
  onChange: (enabled: boolean) => void;
}) {
  return (
    <div className="rounded-xl border border-white/10 bg-background/40 p-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2 text-sm font-medium text-foreground">
            <Icon size={16} className="shrink-0 text-copper" /> {title}
          </div>
          <p className="mt-1.5 text-xs leading-relaxed text-muted-foreground">{description}</p>
        </div>
        <span
          aria-live="polite"
          className={`shrink-0 rounded-full px-2.5 py-1 text-[11px] font-semibold ${
            enabled ? "bg-emerald-400/15 text-emerald-300" : "bg-amber-400/15 text-amber-200"
          }`}
        >
          {pending ? "Salvando…" : enabled ? enabledLabel : disabledLabel}
        </span>
      </div>

      <div className="mt-4 flex flex-wrap gap-2">
        <Button
          type="button"
          size="sm"
          className="bg-emerald-600 text-white hover:bg-emerald-500"
          disabled={pending || enabled}
          onClick={() => onChange(true)}
        >
          {pending && !enabled && <Loader2 className="animate-spin" />}
          Ativar
        </Button>
        <Button
          type="button"
          size="sm"
          className="bg-amber-600 text-white hover:bg-amber-500"
          disabled={pending || !enabled}
          onClick={() => onChange(false)}
        >
          {pending && enabled && <Loader2 className="animate-spin" />}
          Desativar
        </Button>
      </div>

      {error && (
        <p role="alert" className="mt-3 text-xs text-red-300">
          Não foi possível salvar: {error.message}
        </p>
      )}
    </div>
  );
}

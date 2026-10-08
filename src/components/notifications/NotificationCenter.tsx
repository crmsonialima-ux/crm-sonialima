import {
  Bell,
  CalendarDays,
  CheckCheck,
  CircleAlert,
  FileWarning,
  Handshake,
  Info,
  Trash2,
  UserPlus,
} from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { useDashboardData, type DashboardData } from "@/lib/api";
import { displayText } from "@/lib/display-text";

type NotificationKind = "lead" | "visit" | "contract" | "proposal" | "important" | "system";
type CrmNotification = {
  id: string;
  kind: NotificationKind;
  title: string;
  description: string;
  createdAt: string;
  read: boolean;
};
type NotificationState = { readIds: string[]; dismissedIds: string[] };
const storageKey = "sonialima:notification-state";

/** Adapter boundary: future API or websocket events can return CrmNotification directly. */
function notificationsFromDashboard(data?: DashboardData): CrmNotification[] {
  if (!data) return [];
  const recent = data.leads.slice(0, 12);
  const notifications: CrmNotification[] = [];
  recent
    .filter((lead) => lead.estagio === "Lead")
    .slice(0, 3)
    .forEach((lead, index) =>
      notifications.push({
        id: `lead-${lead.id ?? index}`,
        kind: "lead",
        title: "Novo lead recebido",
        description: `${lead.nome} entrou pelo canal ${lead.canal ?? "não informado"}.`,
        createdAt: lead.atualizadoEm ?? "Agora",
        read: false,
      }),
    );
  recent
    .filter((lead) => lead.estagio === "Visita")
    .slice(0, 2)
    .forEach((lead, index) =>
      notifications.push({
        id: `visit-${lead.id ?? index}`,
        kind: "visit",
        title: "Visita agendada",
        description: `${lead.nome} · ${lead.imovel ?? "Imóvel a definir"}.`,
        createdAt: lead.atualizadoEm ?? "Hoje",
        read: false,
      }),
    );
  recent
    .filter((lead) => lead.estagio === "Proposta")
    .slice(0, 2)
    .forEach((lead, index) =>
      notifications.push({
        id: `proposal-${lead.id ?? index}`,
        kind: "proposal",
        title: "Nova proposta em andamento",
        description: `${lead.nome} avançou para proposta${lead.imovel ? ` · ${lead.imovel}` : ""}.`,
        createdAt: lead.atualizadoEm ?? "Hoje",
        read: false,
      }),
    );
  if (data.updatedAt)
    notifications.push({
      id: `sync-${data.updatedAt}`,
      kind: "system",
      title: "Dados sincronizados",
      description: "A central comercial foi atualizada com os dados da operação.",
      createdAt: data.updatedAt,
      read: true,
    });
  return notifications;
}

const config = {
  lead: { icon: UserPlus, color: "text-sky-300 bg-sky-300/10" },
  visit: { icon: CalendarDays, color: "text-amber-300 bg-amber-300/10" },
  contract: { icon: FileWarning, color: "text-rose-300 bg-rose-300/10" },
  proposal: { icon: Handshake, color: "text-violet-300 bg-violet-300/10" },
  important: { icon: CircleAlert, color: "text-copper bg-copper/10" },
  system: { icon: Info, color: "text-slate-300 bg-slate-300/10" },
} satisfies Record<NotificationKind, { icon: typeof Bell; color: string }>;

export function NotificationCenter() {
  const { data } = useDashboardData();
  const [state, setState] = useState<NotificationState>({ readIds: [], dismissedIds: [] });
  useEffect(() => {
    try {
      setState(JSON.parse(localStorage.getItem(storageKey) ?? '{"readIds":[],"dismissedIds":[]}'));
    } catch {
      setState({ readIds: [], dismissedIds: [] });
    }
  }, []);
  const save = (next: NotificationState) => {
    setState(next);
    localStorage.setItem(storageKey, JSON.stringify(next));
  };
  const notifications = useMemo(
    () =>
      notificationsFromDashboard(data)
        .filter((notification) => !state.dismissedIds.includes(notification.id))
        .map((notification) => ({
          ...notification,
          read: notification.read || state.readIds.includes(notification.id),
        })),
    [data, state],
  );
  const unread = notifications.filter((notification) => !notification.read).length;
  const markRead = (id: string) =>
    save({ ...state, readIds: [...new Set([...state.readIds, id])] });
  const markAllRead = () =>
    save({
      ...state,
      readIds: [...new Set([...state.readIds, ...notifications.map((item) => item.id)])],
    });
  const clear = () =>
    save({
      ...state,
      dismissedIds: [...new Set([...state.dismissedIds, ...notifications.map((item) => item.id)])],
    });
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <button
          className="glass relative grid h-10 w-10 place-items-center rounded-xl transition hover:bg-white/[0.05]"
          aria-label="Abrir central de notificações"
        >
          <Bell size={17} strokeWidth={1.75} />
          {unread > 0 && (
            <span className="absolute -right-1 -top-1 grid h-4 min-w-4 place-items-center rounded-full bg-copper px-1 text-[9px] font-bold text-white">
              {unread > 9 ? "9+" : unread}
            </span>
          )}
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent
        align="end"
        className="glass-strong w-[min(94vw,410px)] border-white/10 p-0"
      >
        <div className="flex items-center justify-between px-4 py-3">
          <DropdownMenuLabel className="p-0 text-sm text-foreground">
            Notificações{" "}
            {unread > 0 && (
              <span className="ml-1.5 rounded-full bg-copper/15 px-1.5 py-0.5 text-[10px] text-copper">
                {unread} novas
              </span>
            )}
          </DropdownMenuLabel>
          <div className="flex gap-1">
            <Button
              variant="ghost"
              size="icon"
              aria-label="Marcar todas como lidas"
              title="Marcar todas como lidas"
              disabled={!unread}
              onClick={markAllRead}
            >
              <CheckCheck size={15} />
            </Button>
            <Button
              variant="ghost"
              size="icon"
              aria-label="Limpar notificações"
              title="Limpar notificações"
              disabled={!notifications.length}
              onClick={clear}
            >
              <Trash2 size={15} />
            </Button>
          </div>
        </div>
        <DropdownMenuSeparator className="m-0" />
        <div className="max-h-[min(420px,calc(100dvh-8rem))] overscroll-contain overflow-y-auto p-1.5">
          {notifications.length === 0 ? (
            <div className="px-4 py-10 text-center text-sm text-muted-foreground">
              Sua central está em dia.
            </div>
          ) : (
            notifications.map((notification) => {
              const item = config[notification.kind];
              const Icon = item.icon;
              return (
                <button
                  key={notification.id}
                  onClick={() => markRead(notification.id)}
                  className={`flex w-full gap-3 rounded-lg p-3 text-left transition hover:bg-white/[0.05] ${notification.read ? "opacity-65" : ""}`}
                >
                  <span
                    className={`grid h-8 w-8 shrink-0 place-items-center rounded-lg ${item.color}`}
                  >
                    <Icon size={15} />
                  </span>
                  <span className="min-w-0 flex-1">
                    <span className="flex items-center gap-2">
                      <span className="truncate text-xs font-medium text-foreground">
                        {displayText(notification.title)}
                      </span>
                      {!notification.read && (
                        <span className="h-1.5 w-1.5 shrink-0 rounded-full bg-copper" />
                      )}
                    </span>
                    <span className="mt-0.5 block text-xs leading-relaxed text-muted-foreground">
                      {displayText(notification.description)}
                    </span>
                    <span className="mt-1 block text-[10px] text-muted-foreground/70">
                      {notification.createdAt}
                    </span>
                  </span>
                </button>
              );
            })
          )}
        </div>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

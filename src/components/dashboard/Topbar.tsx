import { Loader2, LogOut, RefreshCw, UserRound } from "lucide-react";
import { useEffect, useState } from "react";
import { GlobalSearch } from "@/components/search/GlobalSearch";
import { BrokerPushNotifications } from "@/components/notifications/BrokerPushNotifications";
import { InboxNotificationCenter } from "@/components/notifications/InboxNotificationCenter";
import { useAuth } from "@/components/auth/AuthProvider";
import { supabase } from "@/lib/supabase";
import { displayBrokerName } from "@/lib/broker-names";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";

export function Topbar() {
  const { profile, session } = useAuth();
  const isAdmin = profile?.role === "admin";
  const [signingOut, setSigningOut] = useState(false);
  const email = session?.user.email ?? "Conta autenticada";
  const initials = (profile?.fullName || email).slice(0, 2).toUpperCase();

  const signOut = async () => {
    setSigningOut(true);
    await supabase.auth.signOut({ scope: "local" });
    setSigningOut(false);
  };

  return (
    <header className="mobile-safe-top topbar-surface fixed inset-x-0 top-0 z-20 mb-6 border-b border-border px-4 pb-3 pl-4 backdrop-blur-xl lg:sticky lg:inset-x-auto lg:-mx-8 lg:mb-8 lg:px-8 lg:py-5">
      <img
        src="/favicon-transparent.png"
        alt="Sônia Lima"
        className="safe-mobile-topbar-logo absolute left-1/2 h-10 w-10 -translate-x-1/2 object-contain lg:hidden"
      />
      <div className="flex items-center gap-2 sm:gap-4">
        <div className="min-w-0 flex-1 max-w-xl">
          {isAdmin ? (
            <GlobalSearch />
          ) : (
            <div className="text-sm font-medium text-foreground">Minha carteira de leads</div>
          )}
        </div>

        <CurrentDateTime />
        <SyncIndicator />

        <InboxNotificationCenter userId={session?.user.id} />
        <BrokerPushNotifications userId={session?.user.id} watchLeadAssignments={!isAdmin} />

        <div className="hidden items-center gap-2 rounded-xl border border-border bg-card/80 py-1.5 pl-1.5 pr-2 sm:flex">
          <div className="grid h-8 w-8 place-items-center rounded-lg bg-gradient-to-br from-copper to-wine text-[10px] font-semibold text-white">
            {initials}
          </div>
          <div className="max-w-40 leading-tight">
            <div className="truncate text-xs font-medium text-foreground">
              {displayBrokerName(profile?.fullName) || "Usuário"}
            </div>
            <div className="truncate text-[10px] text-muted-foreground">{email}</div>
          </div>
          <button
            onClick={() => void signOut()}
            disabled={signingOut}
            aria-label="Sair do CRM"
            title="Sair"
            className="ml-1 grid h-8 w-8 place-items-center rounded-lg text-muted-foreground transition hover:bg-white/[0.06] hover:text-red-300 disabled:opacity-60"
          >
            {signingOut ? <Loader2 size={15} className="animate-spin" /> : <LogOut size={15} />}
          </button>
        </div>
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <button
              type="button"
              aria-label="Abrir menu do perfil"
              className="grid h-10 w-10 place-items-center rounded-xl border border-border bg-card/80 text-muted-foreground transition hover:text-foreground sm:hidden"
            >
              <UserRound size={17} />
            </button>
          </DropdownMenuTrigger>
          <DropdownMenuContent
            align="end"
            sideOffset={8}
            className="glass-strong w-[min(18rem,calc(100vw-1rem))] border-border p-2 sm:hidden"
          >
            <DropdownMenuLabel className="min-w-0 px-2 py-2">
              <span className="block truncate text-sm text-foreground">
                {displayBrokerName(profile?.fullName) || "Usuário"}
              </span>
              <span className="mt-0.5 block truncate text-xs font-normal text-muted-foreground">
                {email}
              </span>
            </DropdownMenuLabel>
            <DropdownMenuSeparator />
            <DropdownMenuItem
              disabled={signingOut}
              onClick={() => void signOut()}
              className="cursor-pointer rounded-lg px-2 py-2.5 text-red-300 focus:text-red-300"
            >
              {signingOut ? <Loader2 className="animate-spin" /> : <LogOut />}
              <span>{signingOut ? "Saindo..." : "Sair da conta"}</span>
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
    </header>
  );
}

function CurrentDateTime() {
  const [now, setNow] = useState(new Date());
  useEffect(() => {
    const timer = window.setInterval(() => setNow(new Date()), 1_000);
    return () => window.clearInterval(timer);
  }, []);
  const date = now.toLocaleDateString("pt-BR", { weekday: "long", day: "2-digit", month: "long" });
  const time = now.toLocaleTimeString("pt-BR", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
  return (
    <div className="hidden items-center gap-3 rounded-xl border border-border bg-card/80 px-4 py-2 text-xs text-muted-foreground xl:flex">
      <div className="capitalize">{date}</div>
      <div className="h-3 w-px bg-border" />
      <div className="font-medium tabular-nums text-foreground/90">{time}</div>
    </div>
  );
}

function SyncIndicator() {
  const [seconds, setSeconds] = useState(0);
  useEffect(() => {
    const timer = window.setInterval(() => setSeconds((value) => (value + 1) % 60), 1_000);
    return () => window.clearInterval(timer);
  }, []);
  return (
    <div className="hidden items-center gap-2 rounded-xl border border-border bg-card/80 px-3 py-2 text-xs text-muted-foreground 2xl:flex">
      <RefreshCw size={13} className="text-copper anim-pulse-glow" />
      <span>Sinc. há {seconds}s</span>
    </div>
  );
}

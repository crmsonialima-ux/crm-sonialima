import type { Session } from "@supabase/supabase-js";
import { Navigate, useLocation } from "@tanstack/react-router";
import { Fingerprint, Loader2, LockKeyhole } from "lucide-react";
import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import { supabase } from "@/lib/supabase";
import { isAdministradorAdmin } from "@/lib/admin-access";
import type { Theme } from "@/hooks/use-theme";
import {
  installCrmClientErrorCapture,
  recordNotificationClientEvent,
  reportCrmClientError,
} from "@/lib/audit-client";
import {
  clearPasskeySessionUnlock,
  formatPasskeyError,
  getPasskeySupport,
  isPasskeyCeremonyActive,
  isPasskeyLockEnabled,
  isPasskeySessionUnlocked,
  PASSKEY_CEREMONY_EVENT,
  PASSKEY_STATE_EVENT,
  setPasskeySessionUnlocked,
  withPasskeyCeremony,
  isInstalledCrmApp,
} from "@/lib/passkeys";

const BROWSER_TAB_SESSION_KEY = "sonialima:browser-tab-authenticated";

export type AuthProfile = {
  id: string;
  fullName: string;
  email: string;
  role: "admin" | "broker";
  isValidator: boolean;
  preferredTheme: Theme;
};
type AuthContextValue = {
  session: Session | null;
  profile: AuthProfile | null;
  loading: boolean;
  profileLoading: boolean;
};
const AuthContext = createContext<AuthContextValue>({
  session: null,
  profile: null,
  loading: true,
  profileLoading: true,
});

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [profile, setProfile] = useState<AuthProfile | null>(null);
  const [loading, setLoading] = useState(true);
  const [profileLoading, setProfileLoading] = useState(true);
  const profileUserIdRef = useRef<string | null>(null);

  useEffect(() => {
    let active = true;
    const loadingFallback = window.setTimeout(() => {
      if (!active) return;
      setLoading(false);
      setProfileLoading(false);
    }, 3_000);
    const setCurrentSession = async (nextSession: Session | null) => {
      if (!active) return;
      window.clearTimeout(loadingFallback);
      setSession(nextSession);
      setLoading(false);
      if (!nextSession) {
        profileUserIdRef.current = null;
        setProfile(null);
        setProfileLoading(false);
        return;
      }

      // TOKEN_REFRESHED e a retomada do Android nao mudam o perfil. Manter o
      // componente montado e essencial enquanto a camera/galeria devolve seu
      // FileList ao input da Agenda.
      if (profileUserIdRef.current === nextSession.user.id) {
        setProfileLoading(false);
        return;
      }

      setProfileLoading(true);
      const { data, error } = await supabase
        .from("profiles")
        .select("id, full_name, email, role, is_validator, preferred_theme")
        .eq("id", nextSession.user.id)
        .maybeSingle();
      if (error) {
        await reportCrmClientError(error, {
          area: "authentication",
          operation: "Carregar perfil do usuário",
          details: { userId: nextSession.user.id },
        });
      }
      if (!active) return;
      profileUserIdRef.current = data ? nextSession.user.id : null;
      setProfile(
        data
          ? {
              id: data.id,
              fullName: data.full_name || data.email,
              email: data.email,
              role: data.role as AuthProfile["role"],
              isValidator: Boolean(data.is_validator),
              preferredTheme: data.preferred_theme === "light" ? "light" : "dark",
            }
          : null,
      );
      setProfileLoading(false);
    };
    void supabase.auth
      .getSession()
      .then(async ({ data }) => {
        const restoredSession = data.session;
        if (
          restoredSession &&
          !isInstalledCrmApp() &&
          sessionStorage.getItem(BROWSER_TAB_SESSION_KEY) !== "true"
        ) {
          await supabase.auth.signOut({ scope: "local" });
          await setCurrentSession(null);
          return;
        }
        await setCurrentSession(restoredSession);
      })
      .catch(() => {
        if (!active) return;
        setSession(null);
        setProfile(null);
        setLoading(false);
        setProfileLoading(false);
      });
    const { data } = supabase.auth.onAuthStateChange((event, nextSession) => {
      if (!isInstalledCrmApp() && event === "SIGNED_IN") {
        sessionStorage.setItem(BROWSER_TAB_SESSION_KEY, "true");
      }
      if (!nextSession) sessionStorage.removeItem(BROWSER_TAB_SESSION_KEY);
      void setCurrentSession(nextSession);
    });
    return () => {
      active = false;
      window.clearTimeout(loadingFallback);
      data.subscription.unsubscribe();
    };
  }, []);

  return (
    <AuthContext.Provider value={{ session, profile, loading, profileLoading }}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  return useContext(AuthContext);
}

export function AuthGate({ children }: { children: ReactNode }) {
  const { session, profile, loading, profileLoading } = useAuth();
  const location = useLocation();
  if (loading) return <div className="min-h-dvh bg-background" />;
  if (!session && location.pathname !== "/login") return <Navigate to="/login" replace />;
  if (session && location.pathname === "/login") return <Navigate to="/" replace />;
  if (session)
    return (
      <BiometricLock session={session}>
        <RoleGate profile={profile} loading={profileLoading}>
          {children}
        </RoleGate>
      </BiometricLock>
    );
  return <>{children}</>;
}

function RoleGate({
  children,
  profile,
  loading,
}: {
  children: ReactNode;
  profile: AuthProfile | null;
  loading: boolean;
}) {
  const location = useLocation();
  const brokerRoutes = ["/leads", "/imoveis", "/agenda"];
  if (loading) return <div className="min-h-dvh bg-background" />;
  if (location.pathname === "/validacao" && !profile?.isValidator)
    return <Navigate to="/" replace />;
  if (location.pathname === "/laboratorio" && profile?.role !== "admin" && !profile?.isValidator)
    return <Navigate to="/leads" replace />;
  if (!isAdministradorAdmin(profile) && !brokerRoutes.includes(location.pathname))
    return <Navigate to="/leads" replace />;
  return <>{children}</>;
}

export function ClientAuditBridge() {
  const { session } = useAuth();

  useEffect(() => {
    if (!session) return;
    return installCrmClientErrorCapture();
  }, [session]);

  useEffect(() => {
    if (!session || !("serviceWorker" in navigator)) return;
    const onMessage = async (event: MessageEvent) => {
      const data = event.data as {
        type?: string;
        notificationId?: string;
        eventType?:
          "browser_presented" | "push_clicked" | "push_closed" | "notification_client_error";
        details?: Record<string, unknown>;
        events?: Array<{
          id: string;
          notificationId: string;
          eventType:
            "browser_presented" | "push_clicked" | "push_closed" | "notification_client_error";
          happenedAt: string;
          clientEventId: string;
          details?: Record<string, unknown>;
        }>;
      };
      if (data?.type === "crm-notification-events" && Array.isArray(data.events)) {
        const acknowledgedIds: string[] = [];
        for (const queuedEvent of data.events) {
          const recorded = await recordNotificationClientEvent(
            queuedEvent.notificationId,
            queuedEvent.eventType,
            {
              happenedAt: queuedEvent.happenedAt,
              clientEventId: queuedEvent.clientEventId,
              source: "service_worker_queue",
              ...(queuedEvent.details ?? {}),
            },
          );
          if (recorded) acknowledgedIds.push(queuedEvent.id);
        }
        if (acknowledgedIds.length) {
          const worker =
            (event.source as ServiceWorker | null) ?? navigator.serviceWorker.controller;
          worker?.postMessage({
            type: "crm-notification-events:ack",
            ids: acknowledgedIds,
          });
        }
        return;
      }
      if (data?.type !== "crm-notification-event" || !data.notificationId || !data.eventType)
        return;
      void recordNotificationClientEvent(data.notificationId, data.eventType, data.details ?? {});
    };
    navigator.serviceWorker.addEventListener("message", onMessage);
    void navigator.serviceWorker.ready.then((registration) => {
      (navigator.serviceWorker.controller ?? registration.active)?.postMessage({
        type: "crm-notification-events:flush",
      });
    });
    return () => navigator.serviceWorker.removeEventListener("message", onMessage);
  }, [session]);

  useEffect(() => {
    if (!session || typeof window === "undefined") return;
    const url = new URL(window.location.href);
    const notificationId =
      url.searchParams.get("crmNotification") ?? url.searchParams.get("crmNotificationId");
    const eventType = url.searchParams.get("crmNotificationEvent");
    const happenedAt = url.searchParams.get("crmNotificationAt");
    const clientEventId = url.searchParams.get("crmNotificationClientEvent");
    if (!notificationId || eventType !== "push_clicked") return;
    void (async () => {
      const recorded = await recordNotificationClientEvent(notificationId, "push_clicked", {
        source: "service_worker_navigation",
        happenedAt: happenedAt ?? undefined,
        clientEventId: clientEventId ?? undefined,
      });
      if (!recorded) return;
      url.searchParams.delete("crmNotification");
      url.searchParams.delete("crmNotificationId");
      url.searchParams.delete("crmNotificationEvent");
      url.searchParams.delete("crmNotificationAt");
      url.searchParams.delete("crmNotificationClientEvent");
      window.history.replaceState(
        window.history.state,
        "",
        `${url.pathname}${url.search}${url.hash}`,
      );
    })();
  }, [session]);

  return null;
}

function BiometricLock({ children, session }: { children: ReactNode; session: Session }) {
  const userId = session.user.id;
  const [locked, setLocked] = useState(true);
  const [ready, setReady] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const installedApp = isInstalledCrmApp();

  useEffect(() => {
    if (!installedApp) return;
    const hiddenKey = `sonialima:app-hidden-at:${userId}`;
    const handleVisibility = () => {
      if (document.visibilityState === "hidden") {
        sessionStorage.setItem(hiddenKey, String(Date.now()));
        return;
      }
      const hiddenAt = Number(sessionStorage.getItem(hiddenKey));
      sessionStorage.removeItem(hiddenKey);
      if (Number.isFinite(hiddenAt) && Date.now() - hiddenAt >= 5 * 60_000) {
        clearPasskeySessionUnlock(userId);
      }
    };
    const handlePageHide = () => clearPasskeySessionUnlock(userId);
    document.addEventListener("visibilitychange", handleVisibility);
    window.addEventListener("pagehide", handlePageHide);
    return () => {
      document.removeEventListener("visibilitychange", handleVisibility);
      window.removeEventListener("pagehide", handlePageHide);
    };
  }, [installedApp, userId]);

  useEffect(() => {
    let active = true;
    setReady(false);
    setLocked(true);

    const refreshLock = () => {
      if (!active) return;
      const enabled = isPasskeyLockEnabled(userId);
      const unlocked = isPasskeySessionUnlocked(userId);
      setLocked(isPasskeyCeremonyActive() || (enabled && !unlocked));
      setReady(true);
    };

    const handleStateChange = (event: Event) => {
      const changedUserId = (event as CustomEvent<{ userId?: string }>).detail?.userId;
      if (!changedUserId || changedUserId === userId) refreshLock();
    };

    const handleStorage = (event: StorageEvent) => {
      if (!event.key || event.key.includes(userId) || event.key === "sonialima-crm-passkey") {
        refreshLock();
      }
    };

    const handleCeremonyChange = (event: Event) => {
      const ceremonyActive = Boolean((event as CustomEvent<{ active?: boolean }>).detail?.active);
      if (ceremonyActive) {
        setLocked(true);
        setReady(true);
        return;
      }
      refreshLock();
    };

    refreshLock();
    void getPasskeySupport().then((support) => {
      if (active && isPasskeyLockEnabled(userId) && !support.canUsePasskeys) {
        setError(`${support.reason} Use e-mail e senha para continuar.`);
      }
    });
    window.addEventListener("storage", handleStorage);
    window.addEventListener(PASSKEY_STATE_EVENT, handleStateChange);
    window.addEventListener(PASSKEY_CEREMONY_EVENT, handleCeremonyChange);
    return () => {
      active = false;
      window.removeEventListener("storage", handleStorage);
      window.removeEventListener(PASSKEY_STATE_EVENT, handleStateChange);
      window.removeEventListener(PASSKEY_CEREMONY_EVENT, handleCeremonyChange);
    };
  }, [userId]);

  const unlock = async () => {
    setLoading(true);
    setError("");
    try {
      const support = await getPasskeySupport();
      if (!support.canUsePasskeys) {
        setError(`${support.reason} Use e-mail e senha para continuar.`);
        return;
      }

      const result = await withPasskeyCeremony(async () => {
        const authentication = await supabase.auth.signInWithPasskey();
        if (authentication.error) return { error: authentication.error, mismatch: false };
        if (authentication.data.user?.id !== userId) {
          const restored = await supabase.auth.setSession({
            access_token: session.access_token,
            refresh_token: session.refresh_token,
          });
          if (restored.error) await supabase.auth.signOut({ scope: "local" });
          return { error: restored.error, mismatch: true };
        }
        setPasskeySessionUnlocked(userId);
        return { error: null, mismatch: false };
      });

      if (result.mismatch) {
        setError("A passkey escolhida pertence a outra conta. Entre novamente com e-mail e senha.");
        return;
      }
      if (result.error) {
        setError(
          formatPasskeyError(
            result.error,
            "Não foi possível confirmar a passkey. Use e-mail e senha para entrar.",
          ),
        );
        return;
      }
      setLocked(false);
    } catch (unlockError) {
      setError(
        formatPasskeyError(
          unlockError,
          "Não foi possível confirmar a passkey. Use e-mail e senha para entrar.",
        ),
      );
    } finally {
      setLoading(false);
    }
  };

  const usePassword = async () => {
    clearPasskeySessionUnlock(userId);
    await supabase.auth.signOut({ scope: "local" });
  };

  if (!installedApp) return <>{children}</>;
  if (!ready) return <div className="min-h-dvh bg-background" aria-label="Verificando acesso" />;
  if (!locked) return <>{children}</>;
  return (
    <div className="fixed inset-0 z-[100] flex min-h-dvh items-center justify-center overflow-y-auto bg-background px-5 py-[max(1.25rem,env(safe-area-inset-top))]">
      <div className="glass w-full max-w-sm rounded-3xl p-7 text-center">
        <div className="mx-auto grid h-14 w-14 place-items-center rounded-2xl border border-copper/20 bg-copper/10 text-copper">
          <LockKeyhole size={24} />
        </div>
        <h1 className="mt-5 text-xl font-semibold text-foreground">Desbloqueie o CRM</h1>
        <p className="mt-2 text-sm leading-relaxed text-muted-foreground">
          Confirme sua identidade com Face ID ou digital para continuar.
        </p>
        {error && (
          <p role="alert" className="mt-4 text-xs text-red-300">
            {error}
          </p>
        )}
        <button
          onClick={unlock}
          disabled={loading}
          className="mt-6 flex w-full items-center justify-center gap-2 rounded-xl bg-copper px-4 py-3 text-sm font-semibold text-white disabled:opacity-70"
        >
          {loading ? (
            <>
              <Loader2 size={17} className="animate-spin" />
              Verificando...
            </>
          ) : (
            <>
              <Fingerprint size={18} />
              Usar Face ID ou digital
            </>
          )}
        </button>
        <button
          onClick={usePassword}
          className="mt-3 text-xs text-muted-foreground underline underline-offset-4"
        >
          Usar e-mail e senha
        </button>
      </div>
    </div>
  );
}

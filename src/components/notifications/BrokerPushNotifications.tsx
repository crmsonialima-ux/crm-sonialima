import { Bell, BellOff, BellRing, Loader2 } from "lucide-react";
import { useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";
import { reportCrmClientError } from "@/lib/audit-client";

const vapidPublicKey =
  (import.meta.env.VITE_VAPID_PUBLIC_KEY as string | undefined) ||
  "BJAriG5aiKwCmd0EHbdyzn6adHBwK4mLVprKe_lQFn1T_gI9Be7ay9eRCCbUqjbAncbd4uWoggWwUQ9FNJ6HAxE";

function vapidKey(value: string) {
  const padding = "=".repeat((4 - (value.length % 4)) % 4);
  const base64 = (value + padding).replace(/-/g, "+").replace(/_/g, "/");
  const raw = atob(base64);
  return Uint8Array.from(raw, (character) => character.charCodeAt(0));
}

async function ensurePushSubscription() {
  if (!window.isSecureContext) {
    throw new Error("As notifica\u00e7\u00f5es instant\u00e2neas exigem acesso seguro por HTTPS.");
  }
  if (!vapidPublicKey || !("serviceWorker" in navigator) || !("PushManager" in window)) {
    throw new Error(
      "Este navegador n\u00e3o oferece suporte \u00e0s notifica\u00e7\u00f5es instant\u00e2neas.",
    );
  }
  const registration = await navigator.serviceWorker.ready;
  const existing = await registration.pushManager.getSubscription();
  const subscription =
    existing ??
    (await registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: vapidKey(vapidPublicKey),
    }));
  const keys = subscription.toJSON().keys;
  if (!subscription.endpoint || !keys?.p256dh || !keys.auth) return;
  const { error } = await supabase.rpc("register_push_subscription", {
    p_endpoint: subscription.endpoint,
    p_p256dh: keys.p256dh,
    p_auth: keys.auth,
  });
  if (error) throw error;
}

export function BrokerPushNotifications({
  userId,
}: {
  userId?: string;
  watchLeadAssignments?: boolean;
}) {
  const [permission, setPermission] = useState<NotificationPermission | "checking" | "unsupported">(
    "checking",
  );
  const [registrationState, setRegistrationState] = useState<
    "idle" | "registering" | "registered" | "failed" | "insecure"
  >("idle");
  const [requesting, setRequesting] = useState(false);

  useEffect(() => {
    if (typeof Notification === "undefined") {
      setPermission("unsupported");
      return;
    }
    setPermission(Notification.permission);
    if (!window.isSecureContext) setRegistrationState("insecure");
  }, []);

  useEffect(() => {
    if (!userId || permission !== "granted" || !window.isSecureContext) return;
    let active = true;
    setRegistrationState("registering");
    void ensurePushSubscription()
      .then(() => {
        if (active) setRegistrationState("registered");
      })
      .catch(async (error) => {
        if (active) setRegistrationState("failed");
        await reportCrmClientError(error, {
          area: "notifications",
          operation: "Registrar dispositivo para notifica\u00e7\u00f5es instant\u00e2neas",
        });
      });
    return () => {
      active = false;
    };
  }, [permission, userId]);

  const enable = async () => {
    if (typeof Notification === "undefined") return;
    setRequesting(true);
    setRegistrationState("registering");
    try {
      const next =
        Notification.permission === "granted" ? "granted" : await Notification.requestPermission();
      setPermission(next);
      if (next === "granted" && userId) {
        await ensurePushSubscription();
        setRegistrationState("registered");
      } else {
        setRegistrationState("idle");
      }
    } catch (error) {
      setRegistrationState(window.isSecureContext ? "failed" : "insecure");
      await reportCrmClientError(error, {
        area: "notifications",
        operation: "Habilitar notifica\u00e7\u00f5es instant\u00e2neas",
      });
    } finally {
      setRequesting(false);
    }
  };

  if (!userId || permission === "checking" || permission === "unsupported") return null;
  if (registrationState === "insecure") {
    return (
      <span
        title="Notifica\u00e7\u00f5es instant\u00e2neas exigem o endere\u00e7o seguro do CRM"
        className="grid h-10 w-10 place-items-center rounded-xl border border-amber-300/20 bg-amber-300/5 text-amber-200"
      >
        <BellOff size={17} />
      </span>
    );
  }
  if (permission === "granted" && registrationState === "registered") {
    return (
      <span
        title="Notificações de novos leads ativadas"
        className="grid h-10 w-10 place-items-center rounded-xl border border-emerald-400/20 bg-emerald-400/5 text-emerald-300"
      >
        <BellRing size={17} />
      </span>
    );
  }

  const isRegistering = requesting || registrationState === "registering";

  return (
    <button
      type="button"
      onClick={() => void enable()}
      disabled={isRegistering || permission === "denied"}
      title={
        permission === "denied"
          ? "As notificações estão bloqueadas no navegador"
          : registrationState === "failed"
            ? "Falha ao registrar este dispositivo; clique para tentar novamente"
            : "Ativar notificações de novos leads"
      }
      aria-label="Ativar notificações de novos leads"
      className="grid h-10 w-10 place-items-center rounded-xl border border-border bg-card/80 text-muted-foreground transition hover:border-copper/40 hover:text-copper disabled:cursor-not-allowed disabled:opacity-50"
    >
      {isRegistering ? (
        <Loader2 size={17} className="animate-spin" />
      ) : permission === "denied" ? (
        <BellOff size={17} />
      ) : (
        <Bell size={17} />
      )}
    </button>
  );
}

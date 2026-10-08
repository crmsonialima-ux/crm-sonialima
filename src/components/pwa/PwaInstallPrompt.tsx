import { Download, Share2, Smartphone, X } from "lucide-react";
import { useCallback, useEffect, useState } from "react";

const DISMISS_STORAGE_KEY = "sonialima:pwa-install-dismissed-at";
const DISMISS_DURATION_MS = 7 * 24 * 60 * 60 * 1000;

interface BeforeInstallPromptEvent extends Event {
  prompt: () => Promise<void>;
  userChoice: Promise<{ outcome: "accepted" | "dismissed"; platform: string }>;
}

interface NavigatorWithStandalone extends Navigator {
  standalone?: boolean;
}

function isIosDevice() {
  const navigatorWithStandalone = navigator as NavigatorWithStandalone;
  return (
    /iphone|ipad|ipod/i.test(navigator.userAgent) ||
    (navigatorWithStandalone.platform === "MacIntel" && navigator.maxTouchPoints > 1)
  );
}

function isRunningStandalone() {
  return (
    window.matchMedia("(display-mode: standalone)").matches ||
    window.matchMedia("(display-mode: fullscreen)").matches ||
    (navigator as NavigatorWithStandalone).standalone === true
  );
}

function wasRecentlyDismissed() {
  try {
    const dismissedAt = Number(localStorage.getItem(DISMISS_STORAGE_KEY));
    return Number.isFinite(dismissedAt) && Date.now() - dismissedAt < DISMISS_DURATION_MS;
  } catch {
    return false;
  }
}

export function PwaInstallPrompt() {
  const [deferredPrompt, setDeferredPrompt] = useState<BeforeInstallPromptEvent | null>(null);
  const [isIos, setIsIos] = useState(false);
  const [standalone, setStandalone] = useState(false);
  const [secureContext, setSecureContext] = useState(false);
  const [dismissed, setDismissed] = useState(true);
  const [showIosInstructions, setShowIosInstructions] = useState(false);
  const [installing, setInstalling] = useState(false);

  const finishInstallation = useCallback(() => {
    setDeferredPrompt(null);
    setShowIosInstructions(false);
    setStandalone(true);
    try {
      localStorage.removeItem(DISMISS_STORAGE_KEY);
    } catch {
      // A instalação continua concluída mesmo quando o armazenamento local está indisponível.
    }
  }, []);

  useEffect(() => {
    const displayMode = window.matchMedia("(display-mode: standalone)");
    const updateDisplayMode = () => setStandalone(isRunningStandalone());
    const onBeforeInstallPrompt = (event: Event) => {
      event.preventDefault();
      setDeferredPrompt(event as BeforeInstallPromptEvent);
    };

    setIsIos(isIosDevice());
    setSecureContext(window.isSecureContext);
    setDismissed(wasRecentlyDismissed());
    updateDisplayMode();

    window.addEventListener("beforeinstallprompt", onBeforeInstallPrompt);
    window.addEventListener("appinstalled", finishInstallation);
    displayMode.addEventListener?.("change", updateDisplayMode);

    return () => {
      window.removeEventListener("beforeinstallprompt", onBeforeInstallPrompt);
      window.removeEventListener("appinstalled", finishInstallation);
      displayMode.removeEventListener?.("change", updateDisplayMode);
    };
  }, [finishInstallation]);

  const dismiss = () => {
    try {
      localStorage.setItem(DISMISS_STORAGE_KEY, String(Date.now()));
    } catch {
      // O aviso ainda pode ser fechado durante esta sessão.
    }
    setShowIosInstructions(false);
    setDismissed(true);
  };

  const install = async () => {
    if (!deferredPrompt) {
      setShowIosInstructions(true);
      return;
    }

    setInstalling(true);
    try {
      await deferredPrompt.prompt();
      const choice = await deferredPrompt.userChoice;
      setDeferredPrompt(null);
      if (choice.outcome === "accepted") finishInstallation();
    } finally {
      setInstalling(false);
    }
  };

  if (!secureContext || standalone || dismissed || (!deferredPrompt && !isIos)) return null;

  return (
    <aside
      aria-label="Instalar Sônia Lima CRM"
      className="fixed inset-x-3 bottom-[max(0.75rem,env(safe-area-inset-bottom))] z-[90] mx-auto max-w-md rounded-2xl border border-border bg-popover/95 p-4 text-popover-foreground shadow-2xl backdrop-blur-xl"
      data-pwa-install-prompt
    >
      <button
        type="button"
        onClick={dismiss}
        aria-label="Fechar aviso de instalação"
        className="absolute right-3 top-3 grid h-8 w-8 place-items-center rounded-full text-muted-foreground transition hover:bg-muted hover:text-foreground"
      >
        <X size={17} aria-hidden="true" />
      </button>

      <div className="flex gap-3 pr-8">
        <div className="grid h-11 w-11 shrink-0 place-items-center rounded-xl bg-primary/10 text-primary">
          <Smartphone size={21} aria-hidden="true" />
        </div>
        <div>
          <h2 className="text-sm font-semibold text-foreground">Use o CRM como aplicativo</h2>
          <p className="mt-1 text-xs leading-relaxed text-muted-foreground">
            Instale um atalho seguro para abrir em tela cheia e acessar mais rápido.
          </p>
        </div>
      </div>

      {showIosInstructions ? (
        <div
          role="dialog"
          aria-label="Instruções para instalar no iPhone ou iPad"
          className="mt-4 rounded-xl border border-border bg-muted/60 p-3"
        >
          <div className="flex items-center gap-2 text-sm font-medium text-foreground">
            <Share2 size={17} className="text-primary" aria-hidden="true" />
            No iPhone ou iPad
          </div>
          <ol className="mt-2 list-decimal space-y-1 pl-5 text-xs leading-relaxed text-muted-foreground">
            <li>Toque no botão Compartilhar do navegador.</li>
            <li>Escolha “Adicionar à Tela de Início”.</li>
            <li>Confirme em “Adicionar”.</li>
          </ol>
          <p className="mt-2 text-[11px] leading-relaxed text-muted-foreground">
            Se a opção não aparecer, abra este endereço no Safari.
          </p>
        </div>
      ) : (
        <button
          type="button"
          onClick={() => void install()}
          disabled={installing}
          className="mt-4 flex min-h-11 w-full items-center justify-center gap-2 rounded-xl bg-primary px-4 py-2.5 text-sm font-semibold text-primary-foreground transition hover:brightness-110 disabled:cursor-wait disabled:opacity-70"
        >
          <Download size={17} aria-hidden="true" />
          {installing ? "Abrindo instalação..." : "Instalar aplicativo"}
        </button>
      )}
    </aside>
  );
}

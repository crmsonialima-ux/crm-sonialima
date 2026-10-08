import { RefreshCw } from "lucide-react";
import { useEffect, useState } from "react";

export function MobileRefreshButton() {
  const [formDialogOpen, setFormDialogOpen] = useState(false);

  useEffect(() => {
    const updateVisibility = () => {
      setFormDialogOpen(Boolean(document.querySelector('[data-hide-mobile-refresh="true"]')));
    };
    updateVisibility();
    const observer = new MutationObserver(updateVisibility);
    observer.observe(document.body, { childList: true, subtree: true });
    return () => observer.disconnect();
  }, []);

  if (formDialogOpen) return null;

  return (
    <button
      type="button"
      onClick={() => window.location.reload()}
      aria-label="Atualizar página"
      title="Atualizar página"
      className="fixed bottom-[max(5rem,calc(env(safe-area-inset-bottom)+5rem))] right-4 z-[80] inline-flex min-h-11 items-center gap-2 rounded-full border border-copper/30 bg-background/95 px-4 py-2.5 text-sm font-semibold text-foreground shadow-2xl backdrop-blur-xl transition active:scale-95 md:hidden"
    >
      <RefreshCw size={17} aria-hidden="true" />
      Atualizar
    </button>
  );
}

import { Bell, BellOff, Loader2 } from "lucide-react";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { supabase } from "@/lib/supabase";

export function PropertyDocumentNotificationToggle({
  propertyId,
  enabled,
  onChanged,
}: {
  propertyId: string;
  enabled: boolean;
  onChanged: (enabled: boolean) => void;
}) {
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");

  async function toggle() {
    setSaving(true);
    setError("");
    const nextEnabled = !enabled;
    const { error: saveError } = await supabase.rpc("set_property_document_notification_override", {
      p_property_id: propertyId,
      p_enabled: nextEnabled,
    });
    setSaving(false);
    if (saveError) {
      setError(saveError.message);
      return;
    }
    onChanged(nextEnabled);
  }

  return (
    <div className="inline-flex flex-col items-start gap-1">
      <Button
        type="button"
        size="default"
        variant={enabled ? "outline" : "default"}
        className={
          enabled
            ? "min-w-44 border-emerald-500/40 text-emerald-300"
            : "min-w-44 bg-red-600 text-white hover:bg-red-500"
        }
        disabled={saving}
        onClick={() => void toggle()}
      >
        {saving ? (
          <Loader2 size={16} className="animate-spin" />
        ) : enabled ? (
          <Bell size={16} />
        ) : (
          <BellOff size={16} />
        )}
        {enabled ? "Desativar avisos dos 9 anexos" : "Ativar avisos dos 9 anexos"}
      </Button>
      <span
        className={enabled ? "text-[10px] text-emerald-300" : "text-[10px] text-muted-foreground"}
      >
        {enabled ? "Ativo: notifica 3 vezes ao dia" : "Desativado para este imóvel"}
      </span>
      {error && <span className="max-w-44 text-[10px] text-red-300">{error}</span>}
    </div>
  );
}

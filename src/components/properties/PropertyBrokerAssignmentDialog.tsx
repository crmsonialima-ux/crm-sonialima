import { Loader2, Users } from "lucide-react";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import type { Property } from "@/lib/properties";
import { displayBrokerName } from "@/lib/broker-names";
import { supabase } from "@/lib/supabase";

export function PropertyBrokerAssignmentDialog({
  property,
  brokers,
  onUpdated,
}: {
  property: Property;
  brokers: string[];
  onUpdated: () => void;
}) {
  const [open, setOpen] = useState(false);
  const [selected, setSelected] = useState<string[]>([]);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");

  const openDialog = () => {
    setSelected(
      (property.broker ?? "")
        .split(",")
        .map((broker) => broker.trim())
        .filter(Boolean),
    );
    setError("");
    setOpen(true);
  };

  const save = async () => {
    if (!selected.length) {
      setError("Selecione ao menos um corretor responsável.");
      return;
    }
    setSaving(true);
    setError("");
    const { error: saveError } = await supabase.rpc("sync_property_broker_access", {
      p_property_id: property.id,
      p_broker_names: selected,
    });
    setSaving(false);
    if (saveError) {
      setError(saveError.message);
      return;
    }
    setOpen(false);
    onUpdated();
  };

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <Button variant="ghost" size="icon" aria-label="Gerenciar corretores" onClick={openDialog}>
        <Users size={15} />
      </Button>
      <DialogContent className="glass-strong border-white/10 text-foreground sm:max-w-md">
        <DialogHeader>
          <DialogTitle>Corretores responsáveis</DialogTitle>
          <DialogDescription>{property.title}</DialogDescription>
        </DialogHeader>
        <div className="max-h-72 space-y-1 overflow-y-auto rounded-lg border border-white/10 bg-white/[0.03] p-2">
          {brokers.map((broker) => (
            <label
              key={broker}
              className="flex cursor-pointer items-center gap-2 rounded px-2 py-2 text-sm hover:bg-white/[0.05]"
            >
              <input
                type="checkbox"
                checked={selected.includes(broker)}
                onChange={() =>
                  setSelected((current) =>
                    current.includes(broker)
                      ? current.filter((item) => item !== broker)
                      : [...current, broker],
                  )
                }
                className="accent-copper"
              />
              {displayBrokerName(broker)}
            </label>
          ))}
        </div>
        {error && <p className="text-sm text-red-300">{error}</p>}
        <div className="flex justify-end gap-2">
          <Button variant="ghost" onClick={() => setOpen(false)}>
            Cancelar
          </Button>
          <Button
            className="bg-copper text-white hover:bg-copper/90"
            onClick={save}
            disabled={saving}
          >
            {saving && <Loader2 size={16} className="animate-spin" />}
            Salvar corretores
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  );
}

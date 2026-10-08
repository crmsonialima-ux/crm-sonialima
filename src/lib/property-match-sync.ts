import { useEffect, useMemo } from "react";
import type { DashboardData } from "@/lib/api";
import { propertiesFromDashboard } from "@/lib/properties";
import { supabase } from "@/lib/supabase";

export function usePropertyMatchSync(data: DashboardData | undefined, enabled: boolean) {
  const payload = useMemo(
    () =>
      propertiesFromDashboard(data).map((property) => ({
        id: property.id,
        code: property.wimoveisCode || property.dfimoveisCode || property.id,
        title: property.title,
        address: property.address,
        neighborhood: property.neighborhood,
        city: property.city,
        purpose: property.purpose,
        value: property.value,
      })),
    [data],
  );
  const signature = useMemo(() => JSON.stringify(payload), [payload]);

  useEffect(() => {
    if (!enabled || payload.length === 0) return;
    void supabase.rpc("sync_property_catalog", { p_properties: payload }).then(() => undefined);
  }, [enabled, payload, signature]);
}

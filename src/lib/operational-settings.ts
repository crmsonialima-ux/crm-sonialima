import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/lib/supabase";

export type AdministradorOperationalSettings = {
  propertyDocumentNotificationsEnabled: boolean;
  deferNewLeadsToNextDayNine: boolean;
  updatedAt: string | null;
  updatedBy: string | null;
};

type OperationalSettingsRow = {
  property_document_notifications_enabled?: unknown;
  defer_new_leads_to_next_day_nine?: unknown;
  propertyDocumentNotificationsEnabled?: unknown;
  deferNewLeadsToNextDayNine?: unknown;
  updated_at?: unknown;
  updated_by?: unknown;
  updatedAt?: unknown;
  updatedBy?: unknown;
};

export const allysonOperationalSettingsQueryKey = ["allyson-operational-settings"] as const;

function settingsRow(value: unknown): OperationalSettingsRow {
  const candidate = Array.isArray(value) ? value[0] : value;
  if (!candidate || typeof candidate !== "object") {
    throw new Error("O CRM não retornou os controles operacionais do Administrador.");
  }
  return candidate as OperationalSettingsRow;
}

function requiredBoolean(value: unknown, label: string) {
  if (typeof value !== "boolean") {
    throw new Error(`O CRM retornou um valor inválido para ${label}.`);
  }
  return value;
}

function optionalString(value: unknown) {
  return typeof value === "string" && value.trim() ? value : null;
}

function normalizeSettings(value: unknown): AdministradorOperationalSettings {
  const row = settingsRow(value);
  return {
    propertyDocumentNotificationsEnabled: requiredBoolean(
      row.property_document_notifications_enabled ?? row.propertyDocumentNotificationsEnabled,
      "as notificações de documentos",
    ),
    deferNewLeadsToNextDayNine: requiredBoolean(
      row.defer_new_leads_to_next_day_nine ?? row.deferNewLeadsToNextDayNine,
      "o envio de leads às 9h do dia seguinte",
    ),
    updatedAt: optionalString(row.updated_at ?? row.updatedAt),
    updatedBy: optionalString(row.updated_by ?? row.updatedBy),
  };
}

export async function getAdministradorOperationalSettings() {
  const { data, error } = await supabase.rpc("get_allyson_operational_settings");
  if (error) throw new Error(error.message);
  return normalizeSettings(data);
}

export async function setPropertyDocumentNotificationsEnabled(enabled: boolean) {
  const { error } = await supabase.rpc("set_property_document_notifications_enabled", {
    p_enabled: enabled,
  });
  if (error) throw new Error(error.message);
}

export async function setDeferNewLeadsToNextDayNine(enabled: boolean) {
  const { error } = await supabase.rpc("set_defer_new_leads_to_next_day_nine", {
    p_enabled: enabled,
  });
  if (error) throw new Error(error.message);
}

export function useAdministradorOperationalSettings(enabled = true) {
  const queryClient = useQueryClient();
  const query = useQuery({
    queryKey: allysonOperationalSettingsQueryKey,
    queryFn: getAdministradorOperationalSettings,
    enabled,
  });
  const refresh = () =>
    queryClient.invalidateQueries({ queryKey: allysonOperationalSettingsQueryKey });
  const propertyDocumentNotificationsMutation = useMutation({
    mutationFn: setPropertyDocumentNotificationsEnabled,
    onSuccess: refresh,
  });
  const deferredLeadsMutation = useMutation({
    mutationFn: setDeferNewLeadsToNextDayNine,
    onSuccess: refresh,
  });

  return {
    query,
    propertyDocumentNotificationsMutation,
    deferredLeadsMutation,
  };
}

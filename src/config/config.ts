export const API_URL = import.meta.env.VITE_GAS_API_URL || "";

export const APP_CONFIG = {
  name: "Sônia Lima",
  shortName: "Sônia Lima",
  refreshIntervalMs: 60_000,
  locale: "pt-BR",
  currency: "BRL",
} as const;

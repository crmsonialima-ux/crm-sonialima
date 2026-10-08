import { API_URL } from "@/config/config";

export type ApiResponse<T> = { success: boolean; message: string; data: T };
export class CrudApiError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CrudApiError";
  }
}

// Algumas versoes publicadas do Apps Script devolveram textos UTF-8 como Latin-1.
// Corrige apenas mensagens com a assinatura desse problema, sem tocar nos dados normais.
function normalizeApiMessage(value: string) {
  if (!/[ÃÂ]/.test(value)) return value;
  try {
    const bytes = Uint8Array.from(value, (character) => character.charCodeAt(0));
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return value;
  }
}
/** Writes deliberately bypass query caching. Cached reads remain owned by useDashboardData. */
export async function mutateApi<T>(action: string, params: Record<string, unknown>): Promise<T> {
  if (!API_URL) throw new CrudApiError("API não configurada.");
  if (API_URL.includes("script.googleusercontent.com/macros/echo")) {
    throw new CrudApiError(
      "Configure VITE_GAS_API_URL com a URL /exec do Web App para habilitar operações de escrita.",
    );
  }
  // URLSearchParams is application/x-www-form-urlencoded, a CORS-safelisted
  // request type. No custom headers means no OPTIONS preflight for Apps Script.
  const body = new URLSearchParams({ action, params: JSON.stringify(params) });
  const response = await fetch(API_URL, { method: "POST", redirect: "follow", body });
  if (!response.ok) throw new CrudApiError(`API respondeu ${response.status}.`);
  let payload: ApiResponse<T>;
  try {
    payload = (await response.json()) as ApiResponse<T>;
  } catch {
    throw new CrudApiError("A API retornou uma resposta inválida.");
  }
  if (!payload.success)
    throw new CrudApiError(normalizeApiMessage(payload.message || "Não foi possível concluir a operação."));
  return payload.data;
}

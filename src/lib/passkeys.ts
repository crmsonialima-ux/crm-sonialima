const LEGACY_PASSKEY_LOCK_KEY = "sonialima-crm-passkey";
const LEGACY_UNLOCKED_KEY = "sonialima-crm-unlocked";
const PASSKEY_LOCK_PREFIX = "sonialima:passkey-lock:";
const PASSKEY_UNLOCKED_PREFIX = "sonialima:passkey-unlocked:";
const PASSKEY_AUTO_ATTEMPT_PREFIX = "sonialima:passkey-auto-attempted:";

export const PASSKEY_STATE_EVENT = "sonialima:passkey-state-change";
export const PASSKEY_CEREMONY_EVENT = "sonialima:passkey-ceremony-change";

export type PasskeySupport = {
  secureContext: boolean;
  webAuthn: boolean;
  platformAuthenticator: boolean;
  canUsePasskeys: boolean;
  canUsePlatformPasskey: boolean;
  reason: string;
};

let activeCeremonies = 0;

export function isInstalledCrmApp() {
  if (typeof window === "undefined") return false;
  return (
    window.matchMedia?.("(display-mode: standalone)").matches === true ||
    Boolean((navigator as Navigator & { standalone?: boolean }).standalone)
  );
}

function passkeyLockKey(userId: string) {
  return `${PASSKEY_LOCK_PREFIX}${userId}`;
}

function passkeyUnlockedKey(userId: string) {
  return `${PASSKEY_UNLOCKED_PREFIX}${userId}`;
}

function passkeyAutoAttemptKey(userId: string) {
  return `${PASSKEY_AUTO_ATTEMPT_PREFIX}${userId}`;
}

function emitStateChange(userId: string) {
  if (typeof window === "undefined") return;
  window.dispatchEvent(new CustomEvent(PASSKEY_STATE_EVENT, { detail: { userId } }));
}

function emitCeremonyChange() {
  if (typeof window === "undefined") return;
  window.dispatchEvent(
    new CustomEvent(PASSKEY_CEREMONY_EVENT, {
      detail: { active: activeCeremonies > 0 },
    }),
  );
}

export function isPasskeyLockEnabled(userId: string) {
  if (typeof window === "undefined" || !userId) return false;
  const key = passkeyLockKey(userId);
  const currentValue = localStorage.getItem(key);
  if (currentValue !== null) return currentValue === "true";

  // Migra a configuração antiga apenas uma vez para o usuário autenticado atual.
  if (localStorage.getItem(LEGACY_PASSKEY_LOCK_KEY) === "true") {
    localStorage.setItem(key, "true");
    localStorage.removeItem(LEGACY_PASSKEY_LOCK_KEY);
    emitStateChange(userId);
    return true;
  }
  return false;
}

export function setPasskeyLockEnabled(userId: string, enabled: boolean) {
  if (typeof window === "undefined" || !userId) return;
  localStorage.setItem(passkeyLockKey(userId), String(enabled));
  localStorage.removeItem(LEGACY_PASSKEY_LOCK_KEY);
  if (!enabled) clearPasskeySessionUnlock(userId);
  emitStateChange(userId);
}

export function isPasskeySessionUnlocked(userId: string) {
  if (typeof window === "undefined" || !userId) return false;
  const key = passkeyUnlockedKey(userId);
  const currentValue = sessionStorage.getItem(key);
  if (currentValue !== null) return currentValue === "true";

  if (sessionStorage.getItem(LEGACY_UNLOCKED_KEY) === "true") {
    sessionStorage.setItem(key, "true");
    sessionStorage.removeItem(LEGACY_UNLOCKED_KEY);
    return true;
  }
  return false;
}

export function setPasskeySessionUnlocked(userId: string) {
  if (typeof window === "undefined" || !userId) return;
  sessionStorage.setItem(passkeyUnlockedKey(userId), "true");
  sessionStorage.removeItem(LEGACY_UNLOCKED_KEY);
  emitStateChange(userId);
}

export function clearPasskeySessionUnlock(userId: string) {
  if (typeof window === "undefined" || !userId) return;
  sessionStorage.removeItem(passkeyUnlockedKey(userId));
  sessionStorage.removeItem(LEGACY_UNLOCKED_KEY);
  emitStateChange(userId);
}

export function wasPasskeyAutoEnrollmentAttempted(userId: string) {
  if (typeof window === "undefined" || !userId) return true;
  return localStorage.getItem(passkeyAutoAttemptKey(userId)) === "true";
}

export function markPasskeyAutoEnrollmentAttempted(userId: string) {
  if (typeof window === "undefined" || !userId) return;
  localStorage.setItem(passkeyAutoAttemptKey(userId), "true");
}

export function isPasskeyCeremonyActive() {
  return activeCeremonies > 0;
}

export async function withPasskeyCeremony<T>(operation: () => Promise<T>): Promise<T> {
  activeCeremonies += 1;
  emitCeremonyChange();
  try {
    return await operation();
  } finally {
    activeCeremonies = Math.max(0, activeCeremonies - 1);
    emitCeremonyChange();
  }
}

export async function getPasskeySupport(): Promise<PasskeySupport> {
  if (typeof window === "undefined") {
    return {
      secureContext: false,
      webAuthn: false,
      platformAuthenticator: false,
      canUsePasskeys: false,
      canUsePlatformPasskey: false,
      reason: "Passkeys só podem ser verificadas no navegador.",
    };
  }

  const secureContext = window.isSecureContext;
  const webAuthn = Boolean(
    "PublicKeyCredential" in window &&
    navigator.credentials &&
    typeof navigator.credentials.create === "function" &&
    typeof navigator.credentials.get === "function",
  );

  let platformAuthenticator = false;
  if (secureContext && webAuthn) {
    const platformCheck = PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable;
    if (typeof platformCheck === "function") {
      try {
        platformAuthenticator = await platformCheck.call(PublicKeyCredential);
      } catch {
        platformAuthenticator = false;
      }
    }
  }

  const canUsePasskeys = secureContext && webAuthn;
  const canUsePlatformPasskey = canUsePasskeys && platformAuthenticator;
  let reason = "Passkey disponível neste dispositivo.";
  if (!secureContext) {
    reason = "Face ID, digital e passkeys exigem o CRM publicado em HTTPS.";
  } else if (!webAuthn) {
    reason = "Este navegador não oferece suporte a passkeys.";
  } else if (!platformAuthenticator) {
    reason = "Não foi encontrado Face ID, digital ou bloqueio seguro neste dispositivo.";
  }

  return {
    secureContext,
    webAuthn,
    platformAuthenticator,
    canUsePasskeys,
    canUsePlatformPasskey,
    reason,
  };
}

export function formatPasskeyError(error: unknown, fallback: string) {
  const candidate = error as { code?: string; name?: string; message?: string } | null;
  const code = candidate?.code?.toLowerCase() ?? "";
  const name = candidate?.name?.toLowerCase() ?? "";
  const message = candidate?.message?.toLowerCase() ?? "";

  if (
    name.includes("notallowed") ||
    message.includes("not allowed") ||
    message.includes("cancel") ||
    message.includes("denied")
  ) {
    return "A confirmação foi cancelada ou não foi autorizada no dispositivo.";
  }
  if (code === "webauthn_credential_exists" || message.includes("already registered")) {
    return "Esta passkey já está cadastrada para a conta.";
  }
  if (code === "too_many_passkeys") {
    return "A conta atingiu o limite de passkeys cadastradas.";
  }
  if (code === "passkey_disabled") {
    return "Passkeys não estão habilitadas no projeto de autenticação.";
  }
  if (code === "webauthn_credential_not_found") {
    return "A passkey escolhida não está mais cadastrada. Use e-mail e senha.";
  }
  return fallback;
}

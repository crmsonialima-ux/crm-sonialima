import {
  BellRing,
  Check,
  Fingerprint,
  Globe2,
  KeyRound,
  Link2,
  Loader2,
  Palette,
  Save,
  ShieldCheck,
  SlidersHorizontal,
  UserRound,
} from "lucide-react";
import { useCallback, useEffect, useState } from "react";
import { useAuth } from "@/components/auth/AuthProvider";
import { Panel } from "@/components/dashboard/Panel";
import { Button } from "@/components/ui/button";
import { useTheme, type Theme } from "@/hooks/use-theme";
import {
  formatPasskeyError,
  getPasskeySupport,
  isPasskeyLockEnabled,
  markPasskeyAutoEnrollmentAttempted,
  PASSKEY_STATE_EVENT,
  setPasskeyLockEnabled,
  setPasskeySessionUnlocked,
  type PasskeySupport,
  withPasskeyCeremony,
} from "@/lib/passkeys";
import { supabase } from "@/lib/supabase";
import { PortalLeadIntegrationControl } from "@/components/settings/PortalLeadIntegrationControl";
import { PropertyDocumentNotificationControl } from "@/components/settings/PropertyDocumentNotificationControl";
import { isAdministradorAdmin, isRestrictedAdmin } from "@/lib/admin-access";

type Tab =
  "personal" | "preferences" | "security" | "notifications" | "appearance" | "integrations";
type Profile = { name: string; email: string; role: string };
type Preferences = {
  compact: boolean;
  startPage: "dashboard" | "leads";
  language: "pt-BR" | "en-US";
  emailAlerts: boolean;
  weeklyDigest: boolean;
  leadAlerts: boolean;
  visitAlerts: boolean;
  proposalAlerts: boolean;
  contractAlerts: boolean;
};
const profileKey = "sonialima:profile";
const preferencesKey = "sonialima:preferences";
const defaultProfile: Profile = {
  name: "Diretoria",
  email: "crmsoniaallyson@gmail.com",
  role: "crmallyson",
};
const defaultPreferences: Preferences = {
  compact: false,
  startPage: "dashboard",
  language: "pt-BR",
  emailAlerts: true,
  weeklyDigest: true,
  leadAlerts: true,
  visitAlerts: true,
  proposalAlerts: true,
  contractAlerts: true,
};
const tabs: Array<{ id: Tab; label: string; icon: typeof UserRound }> = [
  { id: "personal", label: "Dados pessoais", icon: UserRound },
  { id: "preferences", label: "Preferências", icon: SlidersHorizontal },
  { id: "security", label: "Segurança", icon: ShieldCheck },
  { id: "notifications", label: "Notificações", icon: BellRing },
  { id: "appearance", label: "Tema e idioma", icon: Palette },
];
tabs.splice(3, 0, { id: "integrations", label: "Integrações", icon: Link2 });

export function SettingsPage() {
  const { session, profile: authProfile } = useAuth();
  const canManageIntegrations = authProfile?.role === "admin" && !isRestrictedAdmin(authProfile);
  const canManageOperationalSettings = isAdministradorAdmin(authProfile);
  const availableTabs = tabs.filter(
    (item) => item.id !== "integrations" || authProfile?.role === "admin",
  );
  const { theme, setTheme } = useTheme(authProfile?.id, authProfile?.preferredTheme);
  const [tab, setTab] = useState<Tab>("personal");
  const [profile, setProfile] = useState(defaultProfile);
  const [preferences, setPreferences] = useState(defaultPreferences);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [saved, setSaved] = useState(false);
  const [biometricLoading, setBiometricLoading] = useState(false);
  const [biometricEnabled, setBiometricEnabled] = useState(false);
  const [biometricFeedback, setBiometricFeedback] = useState("");
  const [passkeyCount, setPasskeyCount] = useState<number | null>(null);
  const [passkeySupport, setPasskeySupport] = useState<PasskeySupport | null>(null);
  useEffect(() => {
    try {
      const storedProfile = localStorage.getItem(profileKey);
      const storedPreferences = localStorage.getItem(preferencesKey);
      if (storedProfile) setProfile({ ...defaultProfile, ...JSON.parse(storedProfile) });
      if (storedPreferences)
        setPreferences({ ...defaultPreferences, ...JSON.parse(storedPreferences) });
    } catch {
      setError("Não foi possível carregar suas preferências locais.");
    } finally {
      setLoading(false);
    }
  }, []);
  useEffect(() => {
    const userId = session?.user.id;
    if (!userId) return;
    let active = true;

    const refreshPasskeyState = async () => {
      setBiometricEnabled(isPasskeyLockEnabled(userId));
      const support = await getPasskeySupport();
      if (!active) return;
      setPasskeySupport(support);
      if (!support.canUsePasskeys) {
        setPasskeyCount(null);
        return;
      }
      const listed = await supabase.auth.passkey.list();
      if (!active) return;
      setPasskeyCount(listed.error ? null : (listed.data?.length ?? 0));
    };

    const handleStateChange = (event: Event) => {
      const changedUserId = (event as CustomEvent<{ userId?: string }>).detail?.userId;
      if (!changedUserId || changedUserId === userId) void refreshPasskeyState();
    };

    void refreshPasskeyState();
    window.addEventListener(PASSKEY_STATE_EVENT, handleStateChange);
    return () => {
      active = false;
      window.removeEventListener(PASSKEY_STATE_EVENT, handleStateChange);
    };
  }, [session?.user.id]);
  const save = useCallback(() => {
    try {
      localStorage.setItem(profileKey, JSON.stringify(profile));
      localStorage.setItem(preferencesKey, JSON.stringify(preferences));
      setSaved(true);
      window.setTimeout(() => setSaved(false), 2500);
    } catch {
      setError("Não foi possível salvar as configurações neste navegador.");
    }
  }, [preferences, profile]);
  useEffect(() => {
    const shortcut = (event: KeyboardEvent) => {
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "s") {
        event.preventDefault();
        save();
      }
    };
    window.addEventListener("keydown", shortcut);
    return () => window.removeEventListener("keydown", shortcut);
  }, [save]);
  const toggle = (
    key: keyof Pick<
      Preferences,
      | "compact"
      | "emailAlerts"
      | "weeklyDigest"
      | "leadAlerts"
      | "visitAlerts"
      | "proposalAlerts"
      | "contractAlerts"
    >,
  ) => setPreferences((current) => ({ ...current, [key]: !current[key] }));
  const enableBiometrics = async (registerAnother = false) => {
    const currentSession = session;
    if (!currentSession?.user.id) return setError("Sessão não encontrada. Entre novamente.");
    setBiometricLoading(true);
    setError("");
    setBiometricFeedback("");
    try {
      const support = await getPasskeySupport();
      setPasskeySupport(support);
      if (!support.canUsePlatformPasskey) {
        setError(support.reason);
        return;
      }

      const listed = await supabase.auth.passkey.list();
      if (listed.error) {
        setError("Não foi possível consultar as passkeys desta conta. Tente novamente.");
        return;
      }
      const shouldRegister = registerAnother || !listed.data?.length;

      if (shouldRegister) {
        const registration = await withPasskeyCeremony(() => supabase.auth.registerPasskey());
        if (registration.error) {
          setError(
            formatPasskeyError(
              registration.error,
              "Não foi possível cadastrar a passkey neste dispositivo.",
            ),
          );
          return;
        }
        setPasskeyCount((listed.data?.length ?? 0) + 1);
      } else {
        const authentication = await withPasskeyCeremony(async () => {
          const result = await supabase.auth.signInWithPasskey();
          if (result.error || result.data.user?.id === currentSession.user.id) return result;

          const restored = await supabase.auth.setSession({
            access_token: currentSession.access_token,
            refresh_token: currentSession.refresh_token,
          });
          if (restored.error) await supabase.auth.signOut({ scope: "local" });
          return {
            data: { user: null, session: null },
            error: new Error("A passkey escolhida pertence a outra conta."),
          };
        });
        if (authentication.error) {
          setError(
            formatPasskeyError(
              authentication.error,
              authentication.error.message || "Não foi possível confirmar a passkey desta conta.",
            ),
          );
          return;
        }
      }

      markPasskeyAutoEnrollmentAttempted(currentSession.user.id);
      setPasskeySessionUnlocked(currentSession.user.id);
      setPasskeyLockEnabled(currentSession.user.id, true);
      setBiometricEnabled(true);
      setBiometricFeedback(
        shouldRegister
          ? "Passkey cadastrada e trava deste dispositivo ativada."
          : "Passkey confirmada e trava deste dispositivo ativada.",
      );
      setSaved(true);
      window.setTimeout(() => setSaved(false), 2500);
    } catch (passkeyFailure) {
      setError(
        formatPasskeyError(passkeyFailure, "Não foi possível ativar a passkey neste dispositivo."),
      );
    } finally {
      setBiometricLoading(false);
    }
  };

  const disableBiometrics = () => {
    const userId = session?.user.id;
    if (!userId) return;
    setPasskeyLockEnabled(userId, false);
    setBiometricEnabled(false);
    setBiometricFeedback(
      "Trava desativada neste dispositivo. A passkey continua disponível para entrar na conta.",
    );
  };
  if (loading) return <SettingsSkeleton />;
  return (
    <section className="anim-float-in">
      <div className="mb-8 flex flex-wrap items-end justify-between gap-4">
        <div>
          <div className="flex items-center gap-2 text-[11px] uppercase tracking-[0.24em] text-muted-foreground">
            <span className="h-1.5 w-1.5 rounded-full bg-copper shadow-[0_0_10px_var(--copper)]" />
            Conta e experiência
          </div>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Configurações</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Personalize seu ambiente de trabalho e preferências da conta.
          </p>
        </div>
        <Button onClick={save} className="bg-copper text-white hover:bg-copper/90">
          <Save />
          Salvar alterações{" "}
          <kbd className="hidden rounded border border-white/25 px-1 text-[10px] md:inline">
            Ctrl S
          </kbd>
        </Button>
      </div>
      {error && (
        <div
          role="alert"
          className="mb-5 flex items-center justify-between rounded-xl border border-destructive/40 bg-destructive/10 px-4 py-3 text-sm text-foreground"
        >
          <span>{error}</span>
          <button className="text-xs text-copper underline" onClick={() => setError("")}>
            Fechar
          </button>
        </div>
      )}
      <div className="grid gap-5 lg:grid-cols-[240px_1fr]">
        <nav aria-label="Seções de configurações" className="glass h-fit rounded-2xl p-2">
          {availableTabs.map((item) => {
            const Icon = item.icon;
            return (
              <button
                key={item.id}
                onClick={() => setTab(item.id)}
                className={`flex w-full items-center gap-3 rounded-xl px-3 py-2.5 text-left text-sm transition ${tab === item.id ? "bg-copper/10 text-copper" : "text-muted-foreground hover:bg-white/[0.04] hover:text-foreground"}`}
              >
                <Icon size={16} />
                {item.label}
              </button>
            );
          })}
        </nav>
        <Panel
          title={availableTabs.find((item) => item.id === tab)?.label ?? "Configurações"}
          subtitle="As alterações são salvas neste dispositivo e preparadas para sincronização com sua conta."
        >
          <div className="min-h-[330px]">
            {tab === "personal" && (
              <div className="grid gap-4 sm:grid-cols-2">
                <Field label="Nome completo">
                  <input
                    value={profile.name}
                    onChange={(e) => setProfile({ ...profile, name: e.target.value })}
                    className={inputClass}
                  />
                </Field>
                <Field label="E-mail">
                  <input
                    type="email"
                    value={profile.email}
                    onChange={(e) => setProfile({ ...profile, email: e.target.value })}
                    className={inputClass}
                  />
                </Field>
                <Field label="Função">
                  <input
                    value={profile.role}
                    onChange={(e) => setProfile({ ...profile, role: e.target.value })}
                    className={inputClass}
                  />
                </Field>
                <div className="rounded-xl border border-white/10 bg-white/[0.02] p-4 text-sm text-muted-foreground">
                  <span className="font-medium text-foreground">Integração de conta</span>
                  <p className="mt-1 text-xs leading-relaxed">
                    Os dados estão prontos para vinculação ao provedor de autenticação quando ele
                    for conectado.
                  </p>
                </div>
              </div>
            )}
            {tab === "preferences" && (
              <div className="space-y-3">
                <Toggle
                  label="Interface compacta"
                  description="Reduz espaçamentos em listas e tabelas."
                  checked={preferences.compact}
                  onChange={() => toggle("compact")}
                />
                <Field label="Página inicial">
                  <select
                    value={preferences.startPage}
                    onChange={(e) =>
                      setPreferences({
                        ...preferences,
                        startPage: e.target.value as Preferences["startPage"],
                      })
                    }
                    className={inputClass}
                  >
                    <option value="dashboard">Painel executivo</option>
                    <option value="leads">Leads</option>
                  </select>
                </Field>
              </div>
            )}
            {tab === "security" && (
              <div className="space-y-4">
                <div className="rounded-xl border border-copper/20 bg-copper/5 p-4">
                  <div className="flex items-center gap-2 font-medium">
                    <Fingerprint size={17} className="text-copper" />
                    Passkey e bloqueio do aparelho
                  </div>
                  <p className="mt-1 text-xs leading-relaxed text-muted-foreground">
                    Use Face ID, digital ou o bloqueio seguro oferecido pelo aparelho. Quando a
                    trava estiver ativa no app instalado, o CRM pedirá essa confirmação ao reabrir
                    ou após 5 minutos em segundo plano. No navegador, trocar de aba ou minimizar
                    nunca ativa a biometria; uma nova aba exige e-mail e senha.
                  </p>
                  <div className="mt-3 rounded-lg border border-border bg-background/40 px-3 py-2 text-xs text-muted-foreground">
                    <p className="font-medium text-foreground">
                      {biometricEnabled
                        ? "Trava ativa neste dispositivo"
                        : "Trava desativada neste dispositivo"}
                    </p>
                    <p className="mt-1">
                      {passkeySupport?.reason ?? "Verificando compatibilidade do aparelho..."}
                    </p>
                    {passkeyCount !== null && (
                      <p className="mt-1">
                        {passkeyCount === 1
                          ? "1 passkey cadastrada na conta."
                          : `${passkeyCount} passkeys cadastradas na conta.`}
                      </p>
                    )}
                  </div>
                  {biometricFeedback && (
                    <p aria-live="polite" className="mt-3 text-xs text-emerald-500">
                      {biometricFeedback}
                    </p>
                  )}
                  <div className="mt-3 flex flex-wrap gap-2">
                    <Button
                      variant="outline"
                      size="sm"
                      disabled={biometricLoading}
                      onClick={
                        biometricEnabled ? disableBiometrics : () => void enableBiometrics(false)
                      }
                    >
                      {biometricLoading ? <Loader2 className="animate-spin" /> : <Fingerprint />}
                      {biometricLoading
                        ? "Verificando..."
                        : biometricEnabled
                          ? "Desativar trava neste dispositivo"
                          : passkeyCount
                            ? "Confirmar passkey e ativar"
                            : "Cadastrar passkey e ativar"}
                    </Button>
                    {!biometricEnabled && Boolean(passkeyCount) && (
                      <Button
                        variant="outline"
                        size="sm"
                        disabled={biometricLoading}
                        onClick={() => void enableBiometrics(true)}
                      >
                        <Fingerprint />
                        Cadastrar outra passkey
                      </Button>
                    )}
                  </div>
                </div>
                <div className="rounded-xl border border-white/10 bg-white/[0.02] p-4">
                  <div className="flex items-center gap-2 font-medium">
                    <KeyRound size={16} className="text-copper" />
                    Senha de acesso
                  </div>
                  <p className="mt-1 text-xs text-muted-foreground">
                    A alteração de senha utiliza a estrutura de autenticação preparada no menu da
                    conta.
                  </p>
                  <Button
                    variant="outline"
                    size="sm"
                    className="mt-3"
                    onClick={() =>
                      setError(
                        "A alteração de senha será confirmada pelo provedor de autenticação quando conectado.",
                      )
                    }
                  >
                    Solicitar alteração de senha
                  </Button>
                </div>
                <EmptyState
                  title="Nenhuma sessão adicional ativa"
                  description="Quando a autenticação estiver conectada, sessões e dispositivos aparecerão aqui para gerenciamento."
                />
              </div>
            )}
            {tab === "integrations" && (
              <div className="space-y-7">
                <PortalLeadIntegrationControl canManage={canManageIntegrations} />
                <PortalLeadIntegrationControl
                  provider="dfimoveis_vrsync"
                  title="DF Imóveis — Leads VRSYNC"
                  canManage={canManageIntegrations}
                />
                <PortalLeadIntegrationControl
                  provider="whatsapp_business"
                  title="WhatsApp Business — Leads dos portais"
                  canManage={canManageIntegrations}
                />
              </div>
            )}
            {tab === "notifications" && (
              <div className="space-y-3">
                {canManageOperationalSettings && <PropertyDocumentNotificationControl />}
                <Toggle
                  label="Notificações por e-mail"
                  description="Receba alertas operacionais no endereço cadastrado."
                  checked={preferences.emailAlerts}
                  onChange={() => toggle("emailAlerts")}
                />
                <Toggle
                  label="Resumo semanal"
                  description="Receba um consolidado de desempenho comercial."
                  checked={preferences.weeklyDigest}
                  onChange={() => toggle("weeklyDigest")}
                />
                <Toggle
                  label="Novos leads"
                  description="Notificar ao receber oportunidades no CRM."
                  checked={preferences.leadAlerts}
                  onChange={() => toggle("leadAlerts")}
                />
                <Toggle
                  label="Visitas e propostas"
                  description="Alertas sobre visitas agendadas e propostas atualizadas."
                  checked={preferences.visitAlerts && preferences.proposalAlerts}
                  onChange={() => {
                    toggle("visitAlerts");
                    toggle("proposalAlerts");
                  }}
                />
                <Toggle
                  label="Contratos vencendo"
                  description="Preparado para alertas quando a integração de contratos estiver disponível."
                  checked={preferences.contractAlerts}
                  onChange={() => toggle("contractAlerts")}
                />
              </div>
            )}
            {tab === "appearance" && (
              <div className="space-y-5">
                <div>
                  <p className="mb-2 text-xs font-medium text-muted-foreground">Tema</p>
                  <div className="grid grid-cols-2 gap-3">
                    <ThemeCard
                      value="dark"
                      theme={theme}
                      onSelect={setTheme}
                      label="Premium escuro"
                    />
                    <ThemeCard value="light" theme={theme} onSelect={setTheme} label="Claro" />
                  </div>
                </div>
                <Field label="Idioma">
                  <div className="relative">
                    <Globe2
                      size={15}
                      className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-copper"
                    />
                    <select
                      value={preferences.language}
                      onChange={(e) =>
                        setPreferences({
                          ...preferences,
                          language: e.target.value as Preferences["language"],
                        })
                      }
                      className={`${inputClass} pl-9`}
                    >
                      <option value="pt-BR">Português (Brasil)</option>
                      <option value="en-US">English (United States)</option>
                    </select>
                  </div>
                </Field>
              </div>
            )}
          </div>
        </Panel>
      </div>
      <div
        aria-live="polite"
        className={`fixed bottom-5 right-5 rounded-xl border border-copper/30 bg-background px-4 py-3 text-sm shadow-lg transition ${saved ? "translate-y-0 opacity-100" : "pointer-events-none translate-y-3 opacity-0"}`}
      >
        <Check size={16} className="mr-2 inline text-copper" />
        Configurações salvas.
      </div>
    </section>
  );
}
const inputClass =
  "mt-1.5 h-10 w-full rounded-lg border border-white/10 bg-white/[0.03] px-3 text-sm outline-none transition focus:border-copper/50 focus:ring-2 focus:ring-copper/10";
function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="block text-xs font-medium text-muted-foreground">
      {label}
      {children}
    </label>
  );
}
function Toggle({
  label,
  description,
  checked,
  onChange,
}: {
  label: string;
  description: string;
  checked: boolean;
  onChange: () => void;
}) {
  return (
    <label className="flex cursor-pointer items-center justify-between gap-4 rounded-xl border border-white/10 bg-white/[0.02] p-4">
      <span>
        <span className="block text-sm font-medium text-foreground">{label}</span>
        <span className="mt-0.5 block text-xs text-muted-foreground">{description}</span>
      </span>
      <input
        aria-label={label}
        type="checkbox"
        checked={checked}
        onChange={onChange}
        className="h-4 w-4 accent-[var(--copper)]"
      />
    </label>
  );
}
function ThemeCard({
  value,
  theme,
  onSelect,
  label,
}: {
  value: Theme;
  theme: Theme;
  onSelect: (theme: Theme) => void;
  label: string;
}) {
  return (
    <button
      onClick={() => onSelect(value)}
      aria-pressed={theme === value}
      className={`rounded-xl border p-4 text-left text-sm transition ${theme === value ? "border-copper bg-copper/10" : "border-white/10 hover:border-copper/40"}`}
    >
      <span
        className={`mb-3 block h-10 rounded-lg ${value === "dark" ? "bg-[oklch(0.18_0.014_40)]" : "bg-[oklch(0.97_0.008_55)] border border-black/10"}`}
      />
      <span className="font-medium">{label}</span>
      <span className="mt-1 block text-xs text-muted-foreground">
        {theme === value ? "Tema atual" : "Selecionar"}
      </span>
    </button>
  );
}
function EmptyState({ title, description }: { title: string; description: string }) {
  return (
    <div className="rounded-xl border border-dashed border-white/10 px-4 py-6 text-center">
      <ShieldCheck size={20} className="mx-auto text-copper" />
      <p className="mt-2 text-sm font-medium">{title}</p>
      <p className="mt-1 text-xs text-muted-foreground">{description}</p>
    </div>
  );
}
function SettingsSkeleton() {
  return (
    <div className="space-y-5">
      <div className="skeleton h-20 w-full" />
      <div className="grid gap-5 lg:grid-cols-[240px_1fr]">
        <div className="skeleton h-56" />
        <div className="skeleton h-[360px]" />
      </div>
    </div>
  );
}

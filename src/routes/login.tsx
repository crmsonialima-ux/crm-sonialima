import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { Eye, EyeOff, Fingerprint, Loader2, Lock, Mail } from "lucide-react";
import { useState } from "react";
import logo from "@/assets/logo.png";
import hero from "@/assets/hero.png";
import seal from "@/assets/seal.png";
import {
  formatPasskeyError,
  getPasskeySupport,
  isPasskeyLockEnabled,
  markPasskeyAutoEnrollmentAttempted,
  setPasskeyLockEnabled,
  setPasskeySessionUnlocked,
  wasPasskeyAutoEnrollmentAttempted,
  withPasskeyCeremony,
} from "@/lib/passkeys";
import { supabase } from "@/lib/supabase";

export const Route = createFileRoute("/login")({
  head: () => ({
    meta: [
      { title: "Entrar — Sônia Lima CRM" },
      { name: "description", content: "Acesso restrito à plataforma executiva Sônia Lima." },
    ],
  }),
  component: LoginPage,
});

function LoginPage() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [show, setShow] = useState(false);
  const [remember, setRemember] = useState(true);
  const [loading, setLoading] = useState(false);
  const [passkeyLoading, setPasskeyLoading] = useState(false);
  const [error, setError] = useState("");
  const nav = useNavigate();

  const signIn = async (event: React.FormEvent) => {
    event.preventDefault();
    setError("");
    setLoading(true);
    try {
      const { data, error: signInError } = await supabase.auth.signInWithPassword({
        email,
        password,
      });
      if (signInError || !data.user) {
        setError("E-mail ou senha inválidos.");
        return;
      }
      if (!remember) {
        await supabase.auth.signOut({ scope: "local" });
        setError("Para acessar o CRM, marque “Salvar acesso neste dispositivo”.");
        return;
      }

      const userId = data.user.id;
      setPasskeySessionUnlocked(userId);

      const support = await getPasskeySupport();
      if (
        support.canUsePlatformPasskey &&
        !isPasskeyLockEnabled(userId) &&
        !wasPasskeyAutoEnrollmentAttempted(userId)
      ) {
        const existingPasskeys = await supabase.auth.passkey.list();
        if (!existingPasskeys.error) {
          markPasskeyAutoEnrollmentAttempted(userId);
          if (!existingPasskeys.data?.length) {
            const registration = await withPasskeyCeremony(() => supabase.auth.registerPasskey());
            if (!registration.error) {
              setPasskeySessionUnlocked(userId);
              setPasskeyLockEnabled(userId, true);
            }
          }
        }
      }

      void nav({ to: "/" });
    } catch (signInFailure) {
      setError(
        signInFailure instanceof Error
          ? "Não foi possível concluir o acesso. Verifique sua conexão e tente novamente."
          : "Não foi possível concluir o acesso.",
      );
    } finally {
      setLoading(false);
    }
  };

  const signInWithPasskey = async () => {
    setError("");
    setPasskeyLoading(true);
    try {
      const support = await getPasskeySupport();
      if (!support.canUsePasskeys) {
        setError(support.reason);
        return;
      }
      const { data, error: passkeyError } = await withPasskeyCeremony(() =>
        supabase.auth.signInWithPasskey(),
      );
      if (passkeyError || !data.user) {
        setError(
          formatPasskeyError(
            passkeyError,
            "Não foi possível entrar com a passkey. Use e-mail e senha.",
          ),
        );
        return;
      }
      setPasskeySessionUnlocked(data.user.id);
      void nav({ to: "/" });
    } catch (passkeyFailure) {
      setError(
        formatPasskeyError(
          passkeyFailure,
          "Não foi possível entrar com a passkey. Use e-mail e senha.",
        ),
      );
    } finally {
      setPasskeyLoading(false);
    }
  };

  return (
    <div className="grid min-h-dvh min-w-0 grid-cols-[minmax(0,1fr)] overflow-x-hidden lg:grid-cols-[minmax(0,1fr)_minmax(0,1.1fr)]">
      <div className="relative flex min-w-0 items-center justify-center px-4 py-[max(3rem,env(safe-area-inset-top))] sm:px-8">
        <div
          className="pointer-events-none absolute inset-0 opacity-40"
          style={{
            background:
              "radial-gradient(600px 400px at 30% 40%, oklch(0.28 0.18 22 / 0.35), transparent 60%)",
          }}
        />
        <div className="relative min-w-0 w-full max-w-md anim-float-in">
          <div className="mb-10 flex items-center gap-3">
            <img
              src={logo}
              alt="Sônia Lima"
              className="h-10 w-10 drop-shadow-[0_0_20px_oklch(0.74_0.13_55/0.5)]"
            />
            <div>
              <div className="text-sm font-semibold tracking-[0.16em] text-foreground">
                SÔNIA LIMA
              </div>
              <div className="text-[10px] uppercase tracking-[0.24em] text-muted-foreground">
                Imóveis · CRM
              </div>
            </div>
          </div>

          <h1 className="text-3xl font-semibold tracking-tight text-foreground">Acesso ao CRM.</h1>
          <p className="mt-2 text-sm text-muted-foreground">
            Entre para acessar os dados comerciais da operação.
          </p>

          <form onSubmit={signIn} className="mt-8 space-y-4">
            <label className="block">
              <span className="mb-1.5 block text-[11px] uppercase tracking-[0.14em] text-muted-foreground">
                E-mail
              </span>
              <div className="glass flex items-center gap-3 rounded-xl px-4 py-3 focus-within:border-copper/40 focus-within:shadow-[0_0_0_3px_oklch(0.74_0.13_55/0.12)]">
                <Mail size={16} className="text-muted-foreground" />
                <input
                  value={email}
                  onChange={(event) => setEmail(event.target.value)}
                  type="email"
                  required
                  autoComplete="email"
                  className="min-w-0 flex-1 bg-transparent text-sm outline-none placeholder:text-muted-foreground/60"
                  placeholder="seu@email.com"
                />
              </div>
            </label>
            <label className="block">
              <span className="mb-1.5 block text-[11px] uppercase tracking-[0.14em] text-muted-foreground">
                Senha
              </span>
              <div className="glass flex items-center gap-3 rounded-xl px-4 py-3 focus-within:border-copper/40 focus-within:shadow-[0_0_0_3px_oklch(0.74_0.13_55/0.12)]">
                <Lock size={16} className="text-muted-foreground" />
                <input
                  value={password}
                  onChange={(event) => setPassword(event.target.value)}
                  type={show ? "text" : "password"}
                  required
                  autoComplete="current-password"
                  className="min-w-0 flex-1 bg-transparent text-sm outline-none"
                />
                <button
                  type="button"
                  onClick={() => setShow((value) => !value)}
                  className="text-muted-foreground transition hover:text-foreground"
                  aria-label={show ? "Ocultar senha" : "Exibir senha"}
                >
                  {show ? <EyeOff size={16} /> : <Eye size={16} />}
                </button>
              </div>
            </label>

            <label className="flex items-center gap-2 text-xs text-muted-foreground">
              <input
                checked={remember}
                onChange={(event) => setRemember(event.target.checked)}
                type="checkbox"
                className="h-3.5 w-3.5 rounded border-white/10 bg-transparent accent-[oklch(0.74_0.13_55)]"
              />
              Salvar acesso neste dispositivo
            </label>
            {error && (
              <p role="alert" className="text-sm text-red-300">
                {error}
              </p>
            )}

            <button
              type="submit"
              disabled={loading || passkeyLoading}
              className="group relative mt-2 flex w-full items-center justify-center gap-2 overflow-hidden rounded-xl px-5 py-3 text-sm font-semibold text-white shadow-[0_10px_30px_-10px_oklch(0.74_0.13_55/0.6)] transition hover:brightness-110 disabled:opacity-70"
              style={{
                background: "linear-gradient(135deg, oklch(0.60 0.22 25), oklch(0.28 0.18 22))",
              }}
            >
              {loading ? (
                <>
                  <Loader2 size={16} className="animate-spin" />
                  Autenticando...
                </>
              ) : (
                "Entrar no painel"
              )}
            </button>
          </form>

          <div className="my-5 flex items-center gap-3 text-[10px] uppercase tracking-[0.16em] text-muted-foreground">
            <span className="h-px flex-1 bg-border" />
            ou
            <span className="h-px flex-1 bg-border" />
          </div>

          <button
            type="button"
            disabled={loading || passkeyLoading}
            onClick={() => void signInWithPasskey()}
            className="flex w-full min-w-0 items-center justify-center gap-2 rounded-xl border border-copper/30 bg-copper/5 px-3 py-3 text-xs font-semibold text-foreground transition hover:bg-copper/10 disabled:opacity-70 sm:px-5 sm:text-sm"
          >
            {passkeyLoading ? (
              <Loader2 size={17} className="animate-spin" />
            ) : (
              <Fingerprint size={17} className="text-copper" />
            )}
            {passkeyLoading ? (
              "Confirmando..."
            ) : (
              <>
                <span className="sm:hidden">Entrar com biometria ou passkey</span>
                <span className="hidden sm:inline">Entrar com Face ID, digital ou passkey</span>
              </>
            )}
          </button>

          <p className="mt-4 flex items-center justify-center gap-2 text-center text-[11px] text-muted-foreground">
            <Fingerprint size={14} className="text-copper" />A passkey usa a proteção disponível no
            aparelho e exige o CRM em HTTPS.
          </p>

          <p className="mt-8 break-words px-2 text-center text-[11px] text-muted-foreground">
            © {new Date().getFullYear()} Sônia Lima · Desenvolvido por crmallyson
          </p>
        </div>
      </div>

      <div className="relative hidden overflow-hidden lg:block">
        <img src={hero} alt="" className="absolute inset-0 h-full w-full object-cover" />
        <div
          className="absolute inset-0"
          style={{
            background:
              "linear-gradient(120deg, oklch(0.14 0.012 40 / 0.7), oklch(0.14 0.012 40 / 0.2) 60%, transparent)",
          }}
        />
        <div className="absolute bottom-12 left-12 right-12 anim-float-in">
          <img
            src={seal}
            alt=""
            className="mb-8 h-16 w-16 opacity-90 drop-shadow-[0_0_30px_oklch(0.42_0.16_25/0.6)]"
          />
          <h2 className="max-w-lg text-3xl font-light leading-tight tracking-tight text-white">
            <span className="italic text-[oklch(0.82_0.15_60)]">Sofisticação</span> em cada
            operação.
            <br />
            Excelência em cada entrega.
          </h2>
        </div>
      </div>
    </div>
  );
}

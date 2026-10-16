import { KeyRound, LogOut, MonitorCog, Palette, Settings, UserRound } from "lucide-react";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { useTheme } from "@/hooks/use-theme";
import { useAuth } from "@/components/auth/AuthProvider";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";

type View = "profile" | "edit" | "password" | "preferences" | "theme" | "logout" | null;
type Profile = { name: string; email: string; role: string };
const key = "sonialima:profile";
const initial: Profile = {
  name: "crmallyson",
  email: "crmsoniaallyson@gmail.com",
  role: "crmallyson",
};

export function AccountMenu() {
  const { profile: authProfile } = useAuth();
  const [view, setView] = useState<View>(null);
  const [profile, setProfile] = useState<Profile>(initial);
  const [draft, setDraft] = useState<Profile>(initial);
  const [signedOut, setSignedOut] = useState(false);
  const { theme, setTheme } = useTheme(authProfile?.id, authProfile?.preferredTheme);
  useEffect(() => {
    try {
      const saved = localStorage.getItem(key);
      if (saved) {
        const value = JSON.parse(saved) as Profile;
        setProfile(value);
        setDraft(value);
      }
    } catch {
      /* profile remains available */
    }
  }, []);
  const save = () => {
    setProfile(draft);
    localStorage.setItem(key, JSON.stringify(draft));
    setView(null);
  };
  const title =
    view === "profile"
      ? "Meu perfil"
      : view === "edit"
        ? "Editar perfil"
        : view === "password"
          ? "Alterar senha"
          : view === "preferences"
            ? "Preferências"
            : view === "theme"
              ? "Tema"
              : "Encerrar sessão";
  return (
    <>
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <button
            className="glass flex items-center gap-3 rounded-xl py-1.5 pl-1.5 pr-4 transition hover:bg-white/[0.05]"
            aria-label="Abrir menu da conta"
          >
            <div className="grid h-8 w-8 place-items-center rounded-lg bg-gradient-to-br from-copper to-wine text-xs font-semibold text-white">
              {profile.name.slice(0, 2).toUpperCase()}
            </div>
            <div className="hidden text-left md:block">
              <div className="text-xs font-medium text-foreground">{profile.name}</div>
              <div className="text-[10px] text-muted-foreground">{profile.email}</div>
            </div>
          </button>
        </DropdownMenuTrigger>
        <DropdownMenuContent
          align="end"
          className="glass-strong w-56 border-white/10 duration-200 data-[state=open]:slide-in-from-top-1 data-[state=open]:fade-in-0 data-[state=open]:zoom-in-95"
        >
          <DropdownMenuLabel className="text-foreground">Conta Sônia Lima</DropdownMenuLabel>
          <DropdownMenuSeparator />
          <MenuItem icon={UserRound} label="Meu Perfil" onClick={() => setView("profile")} />
          <MenuItem
            icon={Settings}
            label="Editar Perfil"
            onClick={() => {
              setDraft(profile);
              setView("edit");
            }}
          />
          <MenuItem icon={KeyRound} label="Alterar Senha" onClick={() => setView("password")} />
          <MenuItem icon={MonitorCog} label="Preferências" onClick={() => setView("preferences")} />
          <MenuItem icon={Palette} label="Tema" onClick={() => setView("theme")} />
          <DropdownMenuSeparator />
          <MenuItem
            icon={LogOut}
            label="Sair"
            onClick={() => setView("logout")}
            className="text-red-300 focus:text-red-200"
          />
        </DropdownMenuContent>
      </DropdownMenu>
      <Dialog open={view !== null} onOpenChange={(open) => !open && setView(null)}>
        <DialogContent className="glass-strong border-white/10 text-foreground">
          <DialogHeader>
            <DialogTitle>{title}</DialogTitle>
            <DialogDescription>
              {signedOut
                ? "Sessão encerrada neste dispositivo."
                : "As configurações ficam prontas para serem vinculadas ao provedor de autenticação."}
            </DialogDescription>
          </DialogHeader>
          {view === "profile" && (
            <dl className="space-y-3 text-sm">
              <Row label="Nome" value={profile.name} />
              <Row label="E-mail" value={profile.email} />
              <Row label="Função" value={profile.role} />
            </dl>
          )}
          {view === "edit" && (
            <div className="space-y-3">
              <Input
                label="Nome"
                value={draft.name}
                onChange={(name) => setDraft({ ...draft, name })}
              />
              <Input
                label="E-mail"
                value={draft.email}
                onChange={(email) => setDraft({ ...draft, email })}
              />
              <Input
                label="Função"
                value={draft.role}
                onChange={(role) => setDraft({ ...draft, role })}
              />
            </div>
          )}
          {view === "password" && (
            <div className="space-y-3">
              <Input label="Senha atual" type="password" />
              <Input label="Nova senha" type="password" />
              <Input label="Confirmar nova senha" type="password" />
            </div>
          )}
          {view === "preferences" && (
            <div className="space-y-3 text-sm">
              <label className="flex items-center justify-between rounded-lg border border-white/10 p-3">
                Notificações por e-mail
                <input type="checkbox" defaultChecked className="accent-[var(--copper)]" />
              </label>
              <label className="flex items-center justify-between rounded-lg border border-white/10 p-3">
                Resumo semanal
                <input type="checkbox" defaultChecked className="accent-[var(--copper)]" />
              </label>
            </div>
          )}
          {view === "theme" && (
            <div className="grid grid-cols-2 gap-3">
              <button
                onClick={() => setTheme("dark")}
                aria-pressed={theme === "dark"}
                className={`rounded-lg border p-4 text-left text-sm transition ${theme === "dark" ? "border-copper bg-copper/10" : "border-white/10 hover:border-copper/40"}`}
              >
                Premium escuro
                <br />
                <span className="text-xs text-muted-foreground">
                  {theme === "dark" ? "Tema atual" : "Selecionar"}
                </span>
              </button>
              <button
                onClick={() => setTheme("light")}
                aria-pressed={theme === "light"}
                className={`rounded-lg border p-4 text-left text-sm transition ${theme === "light" ? "border-copper bg-copper/10" : "border-white/10 hover:border-copper/40"}`}
              >
                Claro
                <br />
                <span className="text-xs text-muted-foreground">
                  {theme === "light" ? "Tema atual" : "Selecionar"}
                </span>
              </button>
            </div>
          )}
          {view === "logout" && !signedOut && (
            <p className="text-sm text-muted-foreground">
              Você precisará autenticar-se novamente quando a integração de acesso estiver ativa.
            </p>
          )}
          <DialogFooter>
            <Button variant="ghost" onClick={() => setView(null)}>
              Cancelar
            </Button>
            {view === "edit" && (
              <Button className="bg-copper text-white" onClick={save}>
                Salvar perfil
              </Button>
            )}
            {view === "password" && (
              <Button className="bg-copper text-white" onClick={() => setView(null)}>
                Atualizar senha
              </Button>
            )}
            {view === "preferences" && (
              <Button className="bg-copper text-white" onClick={() => setView(null)}>
                Salvar preferências
              </Button>
            )}
            {view === "logout" && (
              <Button variant="destructive" onClick={() => setSignedOut(true)}>
                Sair desta sessão
              </Button>
            )}
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
function MenuItem({
  icon: Icon,
  label,
  onClick,
  className = "",
}: {
  icon: typeof UserRound;
  label: string;
  onClick: () => void;
  className?: string;
}) {
  return (
    <DropdownMenuItem onClick={onClick} className={`cursor-pointer gap-2 ${className}`}>
      <Icon size={15} />
      {label}
    </DropdownMenuItem>
  );
}
function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between gap-6 border-b border-white/5 pb-3">
      <dt className="text-muted-foreground">{label}</dt>
      <dd>{value}</dd>
    </div>
  );
}
function Input({
  label,
  value,
  onChange,
  type = "text",
}: {
  label: string;
  value?: string;
  onChange?: (value: string) => void;
  type?: string;
}) {
  return (
    <label className="block text-xs text-muted-foreground">
      {label}
      <input
        type={type}
        value={value}
        onChange={(e) => onChange?.(e.target.value)}
        className="mt-1.5 w-full rounded-lg border border-white/10 bg-white/[0.03] px-3 py-2 text-sm text-foreground outline-none focus:border-copper/50"
      />
    </label>
  );
}

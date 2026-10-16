import { Link, useLocation } from "@tanstack/react-router";
import {
  LayoutDashboard,
  Users,
  UserCog,
  Building2,
  Megaphone,
  Settings,
  CalendarDays,
  ChevronsLeft,
  ChevronsRight,
  Menu,
  ShieldCheck,
  Landmark,
  BadgeDollarSign,
  X,
} from "lucide-react";
import type { LucideIcon } from "lucide-react";
import { useState } from "react";
import logo from "@/assets/logo.png";
import { useAuth } from "@/components/auth/AuthProvider";
import { isAdministradorAdmin } from "@/lib/admin-access";

type NavItem = {
  to:
    | "/"
    | "/leads"
    | "/agenda"
    | "/corretores"
    | "/imoveis"
    | "/marketing"
    | "/configuracoes"
    | "/validacao"
    | "/financiamento"
    | "/vendas";
  label: string;
  icon: LucideIcon;
  adminOnly?: boolean;
  allysonOnly?: boolean;
  validatorOnly?: boolean;
};

const nav: NavItem[] = [
  { to: "/", label: "Painel", icon: LayoutDashboard },
  { to: "/leads", label: "Leads", icon: Users },
  { to: "/agenda", label: "Agenda", icon: CalendarDays },
  { to: "/financiamento", label: "Financiamento", icon: Landmark, allysonOnly: true },
  { to: "/vendas", label: "Relatório de vendas", icon: BadgeDollarSign, allysonOnly: true },
  { to: "/corretores", label: "Corretores", icon: UserCog, adminOnly: true },
  { to: "/imoveis", label: "Imóveis", icon: Building2 },
  { to: "/marketing", label: "Divulga\u00e7\u00e3o", icon: Megaphone, adminOnly: true },
  { to: "/configuracoes", label: "Configurações", icon: Settings, allysonOnly: true },
  { to: "/validacao", label: "Validação", icon: ShieldCheck, validatorOnly: true },
];

function Brand({ compact = false }: { compact?: boolean }) {
  return (
    <div className="flex items-center gap-3 px-5 py-5">
      <img
        src={logo}
        alt="Sônia Lima"
        className="h-9 w-9 shrink-0 drop-shadow-[0_0_18px_oklch(0.74_0.13_55/0.55)]"
      />
      {!compact && (
        <div className="min-w-0">
          <div className="text-[13px] font-semibold tracking-[0.14em] text-foreground">
            SÔNIA LIMA
          </div>
          <div className="text-[10px] uppercase tracking-[0.22em] text-muted-foreground">
            Imóveis · CRM
          </div>
        </div>
      )}
    </div>
  );
}

function Navigation({
  compact = false,
  onNavigate,
}: {
  compact?: boolean;
  onNavigate?: () => void;
}) {
  const loc = useLocation();
  const { profile } = useAuth();
  const isAllyson = isAdministradorAdmin(profile);
  const items = nav.filter(
    (item) =>
      (isAllyson || ["/", "/leads", "/agenda", "/imoveis"].includes(item.to)) &&
      (!item.adminOnly || profile?.role === "admin") &&
      (!item.allysonOnly || isAdministradorAdmin(profile)) &&
      (!item.validatorOnly || profile?.isValidator),
  );
  return (
    <nav className="mt-2 min-h-0 flex-1 space-y-1 overflow-y-auto overscroll-contain px-3 pb-3">
      {items.map(({ to, label, icon: Icon }) => {
        const active = loc.pathname === to;
        return (
          <Link
            key={to}
            to={to}
            onClick={onNavigate}
            className={`group relative flex items-center gap-3 rounded-xl px-3 py-2.5 text-sm transition-all ${active ? "bg-white/[0.05] text-foreground shadow-[inset_0_1px_0_0_oklch(1_0_0/0.06)]" : "text-muted-foreground hover:bg-white/[0.03] hover:text-foreground"}`}
          >
            {active && (
              <span className="absolute left-0 top-1/2 h-6 w-[3px] -translate-y-1/2 rounded-r-full bg-gradient-to-b from-copper to-wine shadow-[0_0_12px_var(--copper)]" />
            )}
            <Icon
              size={18}
              className={active ? "text-copper shrink-0" : "shrink-0"}
              strokeWidth={1.75}
            />
            {!compact && <span className="truncate font-medium">{label}</span>}
          </Link>
        );
      })}
    </nav>
  );
}

export function Sidebar() {
  const [collapsed, setCollapsed] = useState(false);
  const [mobileOpen, setMobileOpen] = useState(false);

  return (
    <>
      <button
        aria-label="Abrir menu"
        onClick={() => setMobileOpen(true)}
        className="safe-menu-trigger glass-strong fixed left-3 z-50 grid h-10 w-10 place-items-center rounded-xl text-foreground lg:hidden"
      >
        <Menu size={20} />
      </button>

      <aside
        className={`glass-strong fixed left-0 top-0 z-30 hidden h-dvh flex-col transition-[width] duration-300 lg:flex ${collapsed ? "w-[76px]" : "w-[264px]"}`}
        style={{ borderRadius: 0, borderTop: 0, borderBottom: 0, borderLeft: 0 }}
      >
        <Brand compact={collapsed} />
        <div className="mx-4 h-px bg-gradient-to-r from-transparent via-white/10 to-transparent" />
        <Navigation compact={collapsed} />
        <button
          onClick={() => setCollapsed((value) => !value)}
          className="mx-3 mb-4 flex items-center justify-center gap-2 rounded-xl border border-white/5 bg-white/[0.02] py-2 text-xs text-muted-foreground transition hover:bg-white/[0.05] hover:text-foreground"
        >
          {collapsed ? (
            <ChevronsRight size={16} />
          ) : (
            <>
              <ChevronsLeft size={16} />
              <span>Recolher</span>
            </>
          )}
        </button>
      </aside>

      {mobileOpen && (
        <div className="fixed inset-0 z-50 overflow-hidden lg:hidden">
          <button
            aria-label="Fechar menu"
            onClick={() => setMobileOpen(false)}
            className="absolute inset-0 z-0 bg-black/65 backdrop-blur-sm"
          />
          <aside className="safe-mobile-drawer glass-strong relative z-10 flex w-[min(86vw,320px)] flex-col overflow-hidden border-y-0 border-l-0">
            <div className="flex items-center justify-between">
              <Brand />
              <button
                aria-label="Fechar menu"
                onClick={() => setMobileOpen(false)}
                className="mr-4 grid h-10 w-10 place-items-center rounded-xl text-muted-foreground hover:bg-white/[0.05] hover:text-foreground"
              >
                <X size={20} />
              </button>
            </div>
            <div className="mx-4 h-px bg-gradient-to-r from-transparent via-white/10 to-transparent" />
            <Navigation onNavigate={() => setMobileOpen(false)} />
          </aside>
        </div>
      )}
    </>
  );
}

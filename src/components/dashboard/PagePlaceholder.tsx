import { Sidebar } from "@/components/dashboard/Sidebar";
import { Topbar } from "@/components/dashboard/Topbar";
import { Panel } from "@/components/dashboard/Panel";
import type { LucideIcon } from "lucide-react";

export function PagePlaceholder({
  title,
  subtitle,
  icon: Icon,
}: {
  title: string;
  subtitle: string;
  icon: LucideIcon;
}) {
  return (
    <div className="crm-shell min-h-dvh">
      <Sidebar />
      <main className="crm-main ml-0 min-w-0 px-4 pb-10 pt-16 sm:px-6 lg:ml-[264px] lg:px-8 lg:pb-16 lg:pt-0">
        <Topbar />
        <section className="mb-8 anim-float-in">
          <div className="flex items-center gap-2 text-[11px] uppercase tracking-[0.24em] text-muted-foreground">
            <span className="inline-block h-1.5 w-1.5 rounded-full bg-copper shadow-[0_0_10px_var(--copper)]" />
            Módulo · Em preparação
          </div>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight text-foreground">{title}</h1>
          <p className="mt-1 text-sm text-muted-foreground">{subtitle}</p>
        </section>

        <Panel title="Em breve" subtitle="Este módulo será conectado ao backend Sônia Lima.">
          <div className="flex flex-col items-center justify-center gap-4 py-16 text-center">
            <div className="grid h-16 w-16 place-items-center rounded-2xl border border-white/5 bg-white/[0.03] text-copper">
              <Icon size={28} strokeWidth={1.6} />
            </div>
            <div className="max-w-md text-sm text-muted-foreground">
              A visão detalhada de <span className="text-foreground">{title.toLowerCase()}</span>{" "}
              estará disponível assim que a integração com a API for concluída. Enquanto isso,
              acompanhe os indicadores consolidados no painel executivo.
            </div>
          </div>
        </Panel>
      </main>
    </div>
  );
}

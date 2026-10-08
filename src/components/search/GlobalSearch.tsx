import { Building2, Search, UserRound, Users } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "@tanstack/react-router";
import {
  Command,
  CommandDialog,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command";
import { useDashboardData } from "@/lib/api";

type Result = {
  id: string;
  title: string;
  detail: string;
  to: "/leads" | "/corretores" | "/imoveis";
};
type Group = { label: string; icon: typeof Users; items: Result[] };

export function GlobalSearch() {
  const navigate = useNavigate();
  const { data, isLoading } = useDashboardData();
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [debouncedQuery, setDebouncedQuery] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    const timer = window.setTimeout(() => setDebouncedQuery(query.trim().toLowerCase()), 220);
    return () => window.clearTimeout(timer);
  }, [query]);

  useEffect(() => {
    const shortcut = (event: KeyboardEvent) => {
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        setOpen(true);
      }
    };
    window.addEventListener("keydown", shortcut);
    return () => window.removeEventListener("keydown", shortcut);
  }, []);

  useEffect(() => {
    if (open) window.setTimeout(() => inputRef.current?.focus(), 0);
  }, [open]);

  const groups = useMemo<Group[]>(() => {
    const includes = (...values: Array<string | undefined>) =>
      values.some((value) => value?.toLowerCase().includes(debouncedQuery));
    if (!debouncedQuery) return [];
    return [
      {
        label: "Leads",
        icon: Users,
        items: (data?.leads ?? [])
          .filter((lead) => includes(lead.nome, lead.imovel, lead.canal, lead.corretor, lead.id))
          .map((lead, index) => ({
            id: lead.id ?? `lead-${index}`,
            title: lead.nome,
            detail: `${lead.estagio} · ${lead.imovel ?? "Sem imóvel definido"}`,
            to: "/leads" as const,
          })),
      },
      {
        label: "Corretores",
        icon: UserRound,
        items: (data?.ranking ?? [])
          .filter((broker) => includes(broker.nome))
          .map((broker) => ({
            id: broker.id ?? broker.nome,
            title: broker.nome,
            detail: `${broker.vendas} venda${broker.vendas === 1 ? "" : "s"}`,
            to: "/corretores" as const,
          })),
      },
      {
        label: "Imóveis",
        icon: Building2,
        items: (data?.portfolio ?? [])
          .filter((property) => includes(property.name))
          .map((property, index) => ({
            id: `property-${index}`,
            title: property.name,
            detail: `${property.v.toLocaleString("pt-BR")} unidade${property.v === 1 ? "" : "s"} no portfólio`,
            to: "/imoveis" as const,
          })),
      },
    ]
      .map((group) => ({ ...group, items: group.items.slice(0, 6) }))
      .filter((group) => group.items.length > 0);
  }, [data, debouncedQuery]);

  const select = (result: Result) => {
    setOpen(false);
    setQuery("");
    void navigate({ to: result.to });
  };

  return (
    <>
      <button
        onClick={() => setOpen(true)}
        className="glass flex w-full items-center gap-3 rounded-xl py-2.5 pl-4 pr-3 text-left text-sm text-muted-foreground transition hover:border-copper/40 hover:text-foreground"
        aria-label="Abrir pesquisa global"
      >
        <Search size={16} />
        <span className="flex-1 truncate">Buscar leads, corretores e imóveis...</span>
        <kbd className="hidden rounded-md border border-border bg-card px-1.5 py-0.5 text-[10px] font-medium sm:inline">
          Ctrl K
        </kbd>
      </button>
      <CommandDialog open={open} onOpenChange={setOpen}>
        <Command shouldFilter={false} className="glass-strong bg-background">
          <CommandInput
            ref={inputRef}
            value={query}
            onValueChange={setQuery}
            placeholder="Pesquise em todo o CRM..."
          />
          <CommandList className="max-h-[min(60vh,520px)]">
            {isLoading && (
              <div className="space-y-3 p-4">
                {Array.from({ length: 4 }).map((_, index) => (
                  <div key={index} className="skeleton h-10 w-full" />
                ))}
              </div>
            )}
            {!isLoading && !debouncedQuery && (
              <div className="px-5 py-10 text-center text-sm text-muted-foreground">
                Digite para pesquisar em leads, corretores e imóveis.
              </div>
            )}
            {!isLoading && debouncedQuery && (
              <CommandEmpty>Nenhum resultado encontrado.</CommandEmpty>
            )}
            {groups.map((group) => (
              <CommandGroup key={group.label} heading={group.label}>
                <div className="hidden" aria-hidden>
                  <group.icon />
                </div>
                {group.items.map((result) => (
                  <CommandItem
                    key={result.id}
                    value={`${group.label}-${result.id}`}
                    onSelect={() => select(result)}
                  >
                    <group.icon className="mt-0.5 text-copper" />
                    <div>
                      <div className="font-medium">{result.title}</div>
                      <div className="text-xs text-muted-foreground">{result.detail}</div>
                    </div>
                  </CommandItem>
                ))}
              </CommandGroup>
            ))}
          </CommandList>
        </Command>
      </CommandDialog>
    </>
  );
}

import { CalendarDays, ExternalLink, Loader2, Plus } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import type { AccessProfile, CreateLeadInput } from "@/lib/lead-access";
import { useDashboardData } from "@/lib/api";
import { LEAD_TYPES } from "@/lib/lead-distribution";
import { displayBrokerName } from "@/lib/broker-names";
import { isVitorProfile } from "@/lib/admin-access";
import { supabase } from "@/lib/supabase";
import { displayText } from "@/lib/display-text";

const stages = [
  "Aguardando atendimento",
  "Em atendimento",
  "Corretor",
  "Aguardando imóvel similar",
  "Visita agendada",
  "Visita realizada",
  "Proposta",
  "Comprou",
  "Não teve interesse",
  "Telefone não existe",
  "Financiamento",
];
const channels = [
  "DF Imóveis",
  "W Imóveis",
  "Instagram",
  "Facebook",
  "Facebook Marketplace",
  "Google",
  "OLX",
  "Site",
  "WhatsApp",
  "Telefone",
  "Indicação",
  "Faixa/Placa",
  "Evento",
  "Parceiro",
  "Outro",
];

const NO_PROPERTY_INTEREST = "NÃO TEM IMÓVEL DE INTERESSE AINDA";

type FormState = Omit<
  CreateLeadInput,
  "ownerId" | "valor" | "telefone" | "email" | "imovel" | "canal" | "valorDesejado"
> & {
  ownerId: string;
  telefone: string;
  telefone2: string;
  telefone3: string;
  email: string;
  imovel: string;
  canal: string;
  valorDesejado: string;
  visitDate: string;
  visitTime: string;
  visitExecutorIds: string[];
  distributionMode: "self" | "queue";
};

const initialForm = (ownerId: string, isAdmin: boolean): FormState => ({
  nome: "",
  telefone: "",
  telefone2: "",
  telefone3: "",
  email: "",
  imovel: "",
  estagio: isAdmin ? "Aguardando atendimento" : "Em atendimento",
  tipoLead: "Venda",
  canal: "",
  observacoes: "",
  ownerId,
  valorDesejado: "",
  localizacaoDesejada: "",
  visitDate: "",
  visitTime: "",
  visitExecutorIds: [],
  distributionMode: "self",
});

function formatPhone(value: string) {
  const digits = value.replace(/\D/g, "").slice(0, 11);
  if (digits.length <= 2) return digits ? `(${digits}` : "";
  const subscriber = digits.slice(2);
  const prefixLength = digits.length === 11 ? 5 : 4;
  if (subscriber.length <= prefixLength) return `(${digits.slice(0, 2)}) ${subscriber}`;
  return `(${digits.slice(0, 2)}) ${subscriber.slice(0, prefixLength)}-${subscriber.slice(prefixLength)}`;
}

function phoneIdentity(value: string) {
  const digits = value.replace(/\D/g, "");
  return digits.startsWith("55") && (digits.length === 12 || digits.length === 13)
    ? digits.slice(2)
    : digits;
}

function formatBrDate(value: string) {
  const digits = value.replace(/\D/g, "").slice(0, 8);
  if (digits.length <= 2) return digits;
  if (digits.length <= 4) return `${digits.slice(0, 2)}/${digits.slice(2)}`;
  return `${digits.slice(0, 2)}/${digits.slice(2, 4)}/${digits.slice(4)}`;
}

function brDateToIso(value: string) {
  const match = value.match(/^(\d{2})\/(\d{2})\/(\d{4})$/);
  if (!match) return undefined;
  const [, day, month, year] = match;
  const candidate = new Date(`${year}-${month}-${day}T12:00:00`);
  if (
    candidate.getFullYear() !== Number(year) ||
    candidate.getMonth() + 1 !== Number(month) ||
    candidate.getDate() !== Number(day)
  ) {
    return undefined;
  }
  return `${year}-${month}-${day}`;
}

function isoDateToBr(value: string) {
  const match = value.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  return match ? `${match[3]}/${match[2]}/${match[1]}` : "";
}

function toDateTimeValue(date: string, time: string) {
  const isoDate = brDateToIso(date);
  return isoDate && /^\d{2}:\d{2}$/.test(time) ? `${isoDate}T${time}` : "";
}

function openCalendar(input: HTMLInputElement | null) {
  if (!input) return;
  try {
    const picker = input as HTMLInputElement & { showPicker?: () => void };
    if (picker.showPicker) picker.showPicker();
    else input.click();
  } catch {
    input.click();
  }
}

export function LeadCreateDialog({
  owner,
  isAdmin,
  brokers = [],
  onCreate,
  creating,
}: {
  owner: AccessProfile;
  isAdmin: boolean;
  brokers?: AccessProfile[];
  onCreate: (input: CreateLeadInput) => Promise<unknown>;
  creating: boolean;
}) {
  const draftKey = `sonialima-crm:lead-create-draft:${owner.id}`;
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState<FormState>(() => initialForm(isAdmin ? "" : owner.id, isAdmin));
  const [error, setError] = useState("");
  const [phoneError, setPhoneError] = useState("");
  const [checkingPhones, setCheckingPhones] = useState(false);
  const [draftRestored, setDraftRestored] = useState(false);
  const [selectedPropertyId, setSelectedPropertyId] = useState("");
  const [showPropertyOptions, setShowPropertyOptions] = useState(false);
  const [publicLinks, setPublicLinks] = useState<Record<string, string>>({});
  const calendarInput = useRef<HTMLInputElement>(null);
  const propertyPicker = useRef<HTMLDivElement>(null);
  const { data: dashboard, isLoading: loadingProperties } = useDashboardData();
  const properties = (dashboard?.imoveis ?? []).filter((property) => property.titulo.trim());
  const isVitor = isVitorProfile(owner);
  const selectedProperty = properties.find((property) => property.id === selectedPropertyId);
  const selectedPropertyPublicUrl = selectedProperty?.id
    ? publicLinks[selectedProperty.id]
    : undefined;
  const normalizedPropertySearch = form.imovel.trim().toLocaleLowerCase("pt-BR");
  const filteredProperties = properties
    .filter((property) =>
      [
        property.titulo,
        property.endereco,
        property.bairro,
        property.cidade,
        property.codigoDfImoveis,
        property.codigoWImoveis,
      ].some((value) => value?.toLocaleLowerCase("pt-BR").includes(normalizedPropertySearch)),
    )
    .slice(0, 12);

  useEffect(() => {
    if (typeof window === "undefined") return;
    try {
      const draft = sessionStorage.getItem(draftKey);
      if (draft) {
        const saved = JSON.parse(draft) as {
          open?: boolean;
          form?: FormState;
          selectedPropertyId?: string;
        };
        if (saved.open && saved.form) {
          setForm({
            ...saved.form,
            estagio: isAdmin ? saved.form.estagio : "Em atendimento",
          });
          setSelectedPropertyId(saved.selectedPropertyId ?? "");
          setOpen(true);
        }
      }
    } catch {
      sessionStorage.removeItem(draftKey);
    } finally {
      setDraftRestored(true);
    }
  }, [draftKey, isAdmin]);

  useEffect(() => {
    if (draftRestored && !open) {
      setForm(initialForm(isAdmin ? "" : owner.id, isAdmin));
      setSelectedPropertyId("");
      setShowPropertyOptions(false);
    }
  }, [open, owner.id, isAdmin, draftRestored]);

  useEffect(() => {
    if (!draftRestored || typeof window === "undefined") return;
    if (!open) {
      sessionStorage.removeItem(draftKey);
      return;
    }
    sessionStorage.setItem(draftKey, JSON.stringify({ open, form, selectedPropertyId }));
  }, [open, form, selectedPropertyId, draftRestored, draftKey]);

  useEffect(() => {
    if (!open) return;
    let active = true;
    void supabase
      .from("crm_property_public_links")
      .select("property_id, url")
      .then(({ data }) => {
        if (!active) return;
        setPublicLinks(
          Object.fromEntries((data ?? []).map((link) => [String(link.property_id), link.url])),
        );
      });
    return () => {
      active = false;
    };
  }, [open]);

  useEffect(() => {
    if (!showPropertyOptions) return;
    const closeOnOutsideClick = (event: MouseEvent) => {
      if (!propertyPicker.current?.contains(event.target as Node)) setShowPropertyOptions(false);
    };
    document.addEventListener("mousedown", closeOnOutsideClick);
    return () => document.removeEventListener("mousedown", closeOnOutsideClick);
  }, [showPropertyOptions]);

  useEffect(() => {
    if (!open) return;
    const phones = [form.telefone, form.telefone2, form.telefone3].filter(Boolean);
    const identities = phones.map(phoneIdentity).filter((phone) => [10, 11].includes(phone.length));
    if (new Set(identities).size !== identities.length) {
      setPhoneError("O mesmo telefone foi informado mais de uma vez.");
      return;
    }
    if (!identities.length) {
      setPhoneError("");
      return;
    }
    let active = true;
    const timer = window.setTimeout(() => {
      setCheckingPhones(true);
      void supabase
        .rpc("find_duplicate_lead_phones", { p_phones: phones, p_exclude_lead_id: null })
        .then(({ data, error: lookupError }) => {
          if (!active) return;
          setCheckingPhones(false);
          if (lookupError) return;
          setPhoneError(
            (data as string[] | null)?.length
              ? "Este telefone já está cadastrado em outro lead."
              : "",
          );
        });
    }, 350);
    return () => {
      active = false;
      window.clearTimeout(timer);
    };
  }, [form.telefone, form.telefone2, form.telefone3, open]);

  const update = <K extends keyof FormState>(key: K, value: FormState[K]) => {
    setForm((current) => ({ ...current, [key]: value }));
  };

  const submit = async (event: React.FormEvent) => {
    event.preventDefault();
    setError("");
    if (phoneError || checkingPhones) {
      setError(phoneError || "Aguarde a conferência dos telefones.");
      return;
    }
    if (
      form.imovel !== NO_PROPERTY_INTEREST &&
      (!selectedProperty || selectedProperty.titulo.trim() !== form.imovel.trim())
    ) {
      setError("Selecione um imóvel existente na lista.");
      return;
    }
    const visitScheduledAt = toDateTimeValue(form.visitDate, form.visitTime);
    if (form.estagio === "Visita agendada" && !visitScheduledAt) {
      setError("Informe corretamente o dia e a hora da visita.");
      return;
    }
    if (
      form.estagio === "Visita agendada" &&
      form.tipoLead === "Aluguel" &&
      !form.visitExecutorIds.length
    ) {
      setError("Selecione o corretor que fará a visita de aluguel.");
      return;
    }
    try {
      await onCreate({
        ...form,
        estagio: isAdmin ? form.estagio : "Em atendimento",
        nome: form.nome.trim(),
        telefone: form.telefone.trim(),
        telefonesAdicionais: [form.telefone2, form.telefone3]
          .map((phone) => phone.trim())
          .filter(Boolean),
        email: form.email.trim(),
        imovel: form.imovel.trim(),
        canal: form.canal.trim(),
        ownerId: isAdmin ? form.ownerId : owner.id,
        valor: 0,
        valorDesejado: Number(form.valorDesejado.replace(/\D/g, "")),
        localizacaoDesejada: form.localizacaoDesejada.trim(),
        visitScheduledAt:
          isAdmin && form.estagio === "Visita agendada" ? visitScheduledAt : undefined,
        visitExecutorIds:
          isAdmin && form.estagio === "Visita agendada" && form.tipoLead === "Aluguel"
            ? form.visitExecutorIds
            : undefined,
        distributeToQueue: isVitor && form.distributionMode === "queue",
      });
      setOpen(false);
    } catch (reason) {
      setError(
        reason instanceof Error
          ? displayText(reason.message)
          : "N\u00e3o foi poss\u00edvel cadastrar o lead.",
      );
    }
  };

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <Button className="bg-copper text-white hover:bg-copper/90" onClick={() => setOpen(true)}>
        <Plus size={16} /> Novo lead
      </Button>
      <DialogContent
        data-hide-mobile-refresh="true"
        className="glass-strong max-h-[calc(100dvh-2rem)] overflow-y-auto border-white/10 text-foreground sm:max-w-2xl"
      >
        <DialogHeader>
          <DialogTitle>Novo lead</DialogTitle>
          <DialogDescription>
            {isAdmin
              ? "Cadastre a oportunidade. A fila distribuirá o lead automaticamente."
              : isVitor
                ? "Escolha se o lead fica com você ou entra na esteira dos corretores selecionados no imóvel."
                : "Este lead ficará sob sua responsabilidade."}
          </DialogDescription>
        </DialogHeader>
        <form onSubmit={submit} className="grid gap-4 sm:grid-cols-2">
          <Field label="Nome" required>
            <input
              value={form.nome}
              onChange={(event) => update("nome", event.target.value)}
              required
              className={inputClass}
            />
          </Field>
          <Field label="Telefone" required>
            <input
              value={form.telefone}
              onChange={(event) => update("telefone", formatPhone(event.target.value))}
              className={inputClass}
              inputMode="tel"
              autoComplete="tel"
              placeholder="(61) 3333-4444 ou (61) 99180-8363"
              pattern="\(\d{2}\) (?:\d{4}|\d{5})-\d{4}"
              title="Informe um telefone fixo com 10 dígitos ou celular com 11 dígitos"
              required
            />
          </Field>
          <Field label="Telefone 2 (opcional)">
            <input
              value={form.telefone2}
              onChange={(event) => update("telefone2", formatPhone(event.target.value))}
              className={inputClass}
              inputMode="tel"
              autoComplete="tel"
              placeholder="(61) 3333-4444 ou (61) 99180-8363"
              pattern="\(\d{2}\) (?:\d{4}|\d{5})-\d{4}"
            />
          </Field>
          <Field label="Telefone 3 (opcional)">
            <input
              value={form.telefone3}
              onChange={(event) => update("telefone3", formatPhone(event.target.value))}
              className={inputClass}
              inputMode="tel"
              autoComplete="tel"
              placeholder="(61) 3333-4444 ou (61) 99180-8363"
              pattern="\(\d{2}\) (?:\d{4}|\d{5})-\d{4}"
            />
          </Field>
          {(phoneError || checkingPhones) && (
            <p
              role="status"
              className={`sm:col-span-2 text-sm ${phoneError ? "text-red-300" : "text-muted-foreground"}`}
            >
              {phoneError || "Conferindo telefones..."}
            </p>
          )}
          <Field label="E-mail (opcional)">
            <input
              value={form.email}
              onChange={(event) => update("email", event.target.value)}
              className={inputClass}
              type="email"
              autoComplete="email"
              pattern="[^\s@]+@[^\s@]+\.[^\s@]+"
              title="Informe um e-mail válido, por exemplo nome@empresa.com"
            />
          </Field>
          <div ref={propertyPicker} className="relative block text-xs text-muted-foreground">
            Imóvel de interesse <span className="text-copper">*</span>
            <input
              value={form.imovel}
              onChange={(event) => {
                update("imovel", event.target.value);
                setSelectedPropertyId("");
                setShowPropertyOptions(true);
              }}
              onFocus={() => setShowPropertyOptions(true)}
              className={`${inputClass} mt-1.5`}
              placeholder={
                loadingProperties ? "Carregando imóveis..." : "Digite o endereço para buscar"
              }
              disabled={loadingProperties || properties.length === 0}
              autoComplete="off"
              required
            />
            {showPropertyOptions && !loadingProperties && properties.length > 0 && (
              <div className="absolute z-50 mt-1 max-h-72 w-full overflow-y-auto rounded-xl border border-white/10 bg-popover p-1.5 text-popover-foreground shadow-2xl">
                <button
                  type="button"
                  className="w-full rounded-lg border-b border-white/10 px-2 py-2 text-left text-sm font-semibold text-copper hover:bg-white/[0.06]"
                  onClick={() => {
                    update("imovel", NO_PROPERTY_INTEREST);
                    setSelectedPropertyId("");
                    setShowPropertyOptions(false);
                  }}
                >
                  {NO_PROPERTY_INTEREST}
                </button>
                {filteredProperties.map((property) => {
                  const propertyId = property.id ?? "";
                  const publicUrl = propertyId ? publicLinks[propertyId] : undefined;
                  return (
                    <div
                      key={propertyId || `${property.titulo}:${property.endereco ?? ""}`}
                      className="flex items-center gap-2 rounded-lg px-2 py-2 hover:bg-white/[0.06]"
                    >
                      <button
                        type="button"
                        className="min-w-0 flex-1 text-left"
                        onClick={() => {
                          update("imovel", property.titulo.trim());
                          setSelectedPropertyId(propertyId);
                          setShowPropertyOptions(false);
                        }}
                      >
                        <span className="block truncate text-sm font-medium text-foreground">
                          {property.endereco || property.titulo}
                        </span>
                        <span className="mt-0.5 block truncate text-[11px] text-muted-foreground">
                          {[property.bairro, property.cidade].filter(Boolean).join(" · ") ||
                            "Bairro não informado"}
                        </span>
                        <span className="mt-0.5 block text-[11px] font-medium text-emerald-300">
                          {property.valor
                            ? property.valor.toLocaleString("pt-BR", {
                                style: "currency",
                                currency: "BRL",
                                maximumFractionDigits: 0,
                              })
                            : "Valor não informado"}
                        </span>
                      </button>
                      {publicUrl ? (
                        <a
                          href={publicUrl}
                          target="_blank"
                          rel="noopener noreferrer"
                          className="inline-flex shrink-0 items-center gap-1 rounded-md border border-copper/30 px-2 py-1.5 text-[11px] font-medium text-copper hover:bg-copper/10"
                          onMouseDown={(event) => event.stopPropagation()}
                        >
                          <ExternalLink size={13} /> Abrir
                        </a>
                      ) : (
                        <span className="shrink-0 px-2 text-[10px] text-muted-foreground">
                          Sem link
                        </span>
                      )}
                    </div>
                  );
                })}
              </div>
            )}
            {showPropertyOptions &&
              !loadingProperties &&
              properties.length > 0 &&
              filteredProperties.length === 0 && (
                <div className="absolute z-50 mt-1 w-full rounded-xl border border-white/10 bg-popover px-3 py-3 text-xs text-muted-foreground shadow-2xl">
                  Nenhum imóvel encontrado.
                </div>
              )}
            {selectedProperty && (
              <div className="mt-2 flex items-center justify-between gap-3 rounded-lg border border-white/10 bg-white/[0.03] px-3 py-2">
                <span className="min-w-0">
                  <span className="block truncate text-xs text-foreground">
                    {selectedProperty.endereco || selectedProperty.titulo}
                  </span>
                  <span className="block truncate text-[11px] text-muted-foreground">
                    {selectedProperty.bairro || "Bairro não informado"}
                  </span>
                </span>
                {selectedPropertyPublicUrl && (
                  <a
                    href={selectedPropertyPublicUrl}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="inline-flex shrink-0 items-center gap-1 text-[11px] font-medium text-copper hover:underline"
                  >
                    <ExternalLink size={13} /> Abrir imóvel
                  </a>
                )}
              </div>
            )}
            {!loadingProperties && properties.length === 0 && (
              <span className="mt-1 block text-[11px] text-red-300">
                Nenhum imóvel disponível para seleção.
              </span>
            )}
          </div>
          <Field label="Estágio" required>
            <select
              value={form.estagio}
              onChange={(event) => update("estagio", event.target.value)}
              className={inputClass}
              required
            >
              {isAdmin && <option value="Aguardando atendimento">Aguardando atendimento</option>}
              <option value="Em atendimento">Em atendimento</option>
              <option value="Corretor">Corretor</option>
              <option value="Financiamento">Financiamento</option>
            </select>
          </Field>
          <Field label="Origem" required>
            <select
              value={form.canal}
              onChange={(event) => update("canal", event.target.value)}
              className={inputClass}
              required
            >
              <option value="" disabled>
                Selecione a origem
              </option>
              {channels.map((channel) => (
                <option key={channel}>{channel}</option>
              ))}
            </select>
          </Field>
          {form.estagio === "Visita agendada" && (
            <div className="grid gap-3 sm:col-span-2 sm:grid-cols-[minmax(0,1fr)_auto_minmax(140px,0.55fr)] sm:items-end">
              <Field label="Data da visita" required>
                <input
                  value={form.visitDate}
                  onChange={(event) => update("visitDate", formatBrDate(event.target.value))}
                  inputMode="numeric"
                  placeholder="dd/mm/aaaa"
                  maxLength={10}
                  className={inputClass}
                  required
                />
              </Field>
              <button
                type="button"
                aria-label="Abrir calendário"
                title="Abrir calendário"
                onClick={() => openCalendar(calendarInput.current)}
                className="grid h-10 w-10 place-items-center rounded-lg border border-white/10 bg-white/[0.03] text-copper transition hover:border-copper/50"
              >
                <CalendarDays size={17} />
              </button>
              <input
                ref={calendarInput}
                type="date"
                tabIndex={-1}
                aria-hidden="true"
                value={brDateToIso(form.visitDate) ?? ""}
                onChange={(event) => update("visitDate", isoDateToBr(event.target.value))}
                className="sr-only"
              />
              <Field label="Hora da visita" required>
                <input
                  type="time"
                  value={form.visitTime}
                  onChange={(event) => update("visitTime", event.target.value)}
                  className={inputClass}
                  required
                />
              </Field>
            </div>
          )}
          {form.estagio === "Visita agendada" && form.tipoLead === "Aluguel" ? (
            <Field label="Corretores que farão a visita" required>
              <div className="grid gap-2 rounded-lg border border-white/10 bg-white/[0.03] p-2 sm:grid-cols-2">
                {brokers.map((broker) => {
                  const checked = form.visitExecutorIds.includes(broker.id);
                  return (
                    <label
                      key={broker.id}
                      className={`flex cursor-pointer items-center gap-2 rounded-md border px-3 py-2 text-sm transition ${checked ? "border-copper/60 bg-copper/15 text-foreground" : "border-white/5 text-muted-foreground hover:border-white/15"}`}
                    >
                      <input
                        type="checkbox"
                        checked={checked}
                        onChange={() =>
                          update(
                            "visitExecutorIds",
                            checked
                              ? form.visitExecutorIds.filter((id) => id !== broker.id)
                              : [...form.visitExecutorIds, broker.id],
                          )
                        }
                        className="accent-copper"
                      />
                      {displayBrokerName(broker.fullName)}
                    </label>
                  );
                })}
              </div>
              <p className="mt-1.5 text-xs text-muted-foreground">
                O lead permanece com o corretor responsável; todos os selecionados ocuparão a agenda
                no mesmo horário.
              </p>
            </Field>
          ) : null}
          <Field label="Finalidade" required>
            <div className="grid grid-cols-2 gap-2">
              {LEAD_TYPES.map((type) => (
                <button
                  key={type}
                  type="button"
                  onClick={() => update("tipoLead", type)}
                  className={`rounded-lg border px-3 py-2.5 text-sm font-medium transition ${
                    form.tipoLead === type
                      ? "border-copper bg-copper/15 text-copper"
                      : "border-white/10 bg-white/[0.03] text-muted-foreground hover:border-copper/40"
                  }`}
                >
                  {type}
                </button>
              ))}
            </div>
          </Field>
          {isAdmin && (
            <Field label="Corretor responsável">
              <select
                value={form.ownerId}
                onChange={(event) => {
                  update("ownerId", event.target.value);
                  if (event.target.value) update("estagio", "Em atendimento");
                }}
                className={inputClass}
              >
                <option value="">Distribuir automaticamente pela fila</option>
                {brokers.map((broker) => (
                  <option key={broker.id} value={broker.id}>
                    {displayBrokerName(broker.fullName)}
                  </option>
                ))}
              </select>
              <p className="mt-1.5 text-xs text-muted-foreground">
                Ao escolher um corretor, o lead será atribuído diretamente a ele e não entrará na
                fila automática.
              </p>
            </Field>
          )}
          {isVitor && (
            <Field label="Destino do lead">
              <select
                value={form.distributionMode}
                onChange={(event) =>
                  update("distributionMode", event.target.value as "self" | "queue")
                }
                className={inputClass}
              >
                <option value="self">Ficar somente comigo</option>
                <option value="queue">Rodar na fila dos corretores selecionados</option>
              </select>
              <p className="mt-1.5 text-xs text-muted-foreground">
                A fila respeita os corretores autorizados no imóvel e para após duas rodadas.
              </p>
            </Field>
          )}
          <Field label="Média de valor do imóvel desejado" required>
            <input
              value={form.valorDesejado}
              onChange={(event) =>
                update(
                  "valorDesejado",
                  event.target.value.replace(/\D/g, "").replace(/\B(?=(\d{3})+(?!\d))/g, "."),
                )
              }
              className={inputClass}
              inputMode="numeric"
              placeholder="Ex.: 500.000"
              required
            />
          </Field>
          <Field label="Localização desejada" required>
            <input
              value={form.localizacaoDesejada}
              onChange={(event) => update("localizacaoDesejada", event.target.value)}
              className={inputClass}
              placeholder="Ex.: Águas Claras, Brasília"
              required
            />
          </Field>
          <Field label="Observações" className="sm:col-span-2">
            <textarea
              value={form.observacoes}
              onChange={(event) => update("observacoes", event.target.value)}
              className={`${inputClass} min-h-24 resize-y`}
            />
          </Field>
          {error && (
            <p role="alert" className="sm:col-span-2 text-sm text-red-300">
              {error}
            </p>
          )}
          <div className="flex justify-end gap-2 sm:col-span-2">
            <Button type="button" variant="ghost" onClick={() => setOpen(false)}>
              Cancelar
            </Button>
            <Button
              type="submit"
              className="bg-copper text-white hover:bg-copper/90"
              disabled={creating || checkingPhones || Boolean(phoneError)}
            >
              {creating && <Loader2 size={16} className="animate-spin" />}
              Salvar lead
            </Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  );
}

const inputClass =
  "w-full rounded-lg border border-white/10 bg-white/[0.03] px-3 py-2.5 text-sm text-foreground outline-none transition focus:border-copper/50";

function Field({
  label,
  required,
  className,
  children,
}: {
  label: string;
  required?: boolean;
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <label className={`block text-xs text-muted-foreground ${className ?? ""}`}>
      {label}
      {required && <span className="text-copper"> *</span>}
      <span className="mt-1.5 block">{children}</span>
    </label>
  );
}

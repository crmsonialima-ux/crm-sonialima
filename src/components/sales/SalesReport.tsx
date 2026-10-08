import { useQuery, useQueryClient } from "@tanstack/react-query";
import { CalendarDays, Landmark, Loader2, Plus, Save, Search, Trash2, X } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import { Link } from "@tanstack/react-router";
import { useAuth } from "@/components/auth/AuthProvider";
import { Button } from "@/components/ui/button";
import { isAdministradorAdmin, isRestrictedAdmin, isVitorProfile } from "@/lib/admin-access";
import { useBrokerProfiles } from "@/lib/lead-access";
import { supabase } from "@/lib/supabase";
import { DAILY_REVENUE_QUERY_KEY } from "@/lib/daily-revenue";
import { RentalReport } from "@/components/sales/RentalReport";

type PropertyOption = {
  external_id: string;
  title: string | null;
  address: string | null;
  neighborhood: string | null;
  city: string | null;
  code: string | null;
  wimoveis_code: string | null;
  dfimoveis_code: string | null;
  value: number | string | null;
};
type CapturerAssignment = { property_id: string; broker_id: string; broker_name: string };

type Sale = {
  id: string;
  property_id: string | null;
  property_title: string | null;
  legacy_incomplete: boolean;
  seller_id: string;
  capturer_id: string | null;
  capturer_name: string;
  buyer_name: string;
  buyer_email: string | null;
  buyer_phone: string | null;
  buyer_birth_date: string | null;
  property_address: string;
  sold_on: string;
  contract_signed_on: string | null;
  deed_on: string | null;
  expected_delivery_at: string | null;
  delivered_at: string | null;
  has_financing: boolean;
  financial_submitted_at: string | null;
};
type Financial = { sale_id: string; purchase_price: number; commission_amount: number };
type Form = {
  property_id: string;
  seller_id: string;
  capturer_id: string;
  capturer_name: string;
  buyer_name: string;
  buyer_email: string;
  buyer_phone: string;
  buyer_birth_date: string;
  property_address: string;
  sold_on: string;
  contract_signed_on: string;
  deed_on: string;
  expected_delivery_at: string;
  delivered_at: string;
  has_financing: boolean;
  purchase_price: string;
  commission_amount: string;
};

const emptyForm: Form = {
  property_id: "",
  seller_id: "",
  capturer_id: "",
  capturer_name: "",
  buyer_name: "",
  buyer_email: "",
  buyer_phone: "",
  buyer_birth_date: "",
  property_address: "",
  sold_on: "",
  contract_signed_on: "",
  deed_on: "",
  expected_delivery_at: "",
  delivered_at: "",
  has_financing: false,
  purchase_price: "",
  commission_amount: "",
};
const money = (value?: number | string) =>
  value === undefined
    ? "—"
    : Number(value).toLocaleString("pt-BR", { style: "currency", currency: "BRL" });
const day = (value?: string | null) =>
  value ? new Date(`${value}T12:00:00`).toLocaleDateString("pt-BR") : "—";
const dateTime = (value?: string | null) =>
  value ? new Date(value).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" }) : "—";
const localInput = (value?: string | null) => {
  if (!value) return "";
  const date = new Date(value);
  return new Date(date.getTime() - date.getTimezoneOffset() * 60_000).toISOString().slice(0, 16);
};
const monthBounds = (month: string) => {
  const [year, part] = month.split("-").map(Number);
  return [
    `${month}-01`,
    `${part === 12 ? year + 1 : year}-${String(part === 12 ? 1 : part + 1).padStart(2, "0")}-01`,
  ];
};

function formatPhone(value: string) {
  const digits = value.replace(/\D/g, "").slice(0, 11);
  if (digits.length <= 2) return digits ? `(${digits}` : "";
  const subscriber = digits.slice(2);
  const prefixLength = digits.length === 11 ? 5 : 4;
  if (subscriber.length <= prefixLength) return `(${digits.slice(0, 2)}) ${subscriber}`;
  return `(${digits.slice(0, 2)}) ${subscriber.slice(0, prefixLength)}-${subscriber.slice(prefixLength)}`;
}
function formatMoneyInput(value: string) {
  const clean = value.replace(/[^\d,]/g, "");
  const [whole, fraction] = clean.split(",");
  const grouped = (whole.replace(/^0+(?=\d)/, "") || "").replace(/\B(?=(\d{3})+(?!\d))/g, ".");
  return clean.includes(",") ? `${grouped},${(fraction ?? "").slice(0, 2)}` : grouped;
}
function parseMoney(value: string) {
  return Number(value.replace(/\./g, "").replace(",", "."));
}
function storedMoney(value?: number | string) {
  return value == null
    ? ""
    : Number(value).toLocaleString("pt-BR", {
        minimumFractionDigits: 2,
        maximumFractionDigits: 2,
      });
}
function propertyLabel(property: PropertyOption) {
  return property.address?.trim() || property.title?.trim() || property.external_id;
}
function normalizedSearch(value: string | null | undefined) {
  return String(value ?? "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLocaleLowerCase("pt-BR")
    .trim();
}

export function SalesReport() {
  const { profile } = useAuth();
  const queryClient = useQueryClient();
  const canEdit = isVitorProfile(profile) || isAdministradorAdmin(profile);
  const canSeeMoney = isAdministradorAdmin(profile) || isRestrictedAdmin(profile);
  const brokers = useBrokerProfiles(Boolean(profile));
  const properties = useQuery({
    queryKey: ["sales-report-properties"],
    enabled: Boolean(profile),
    queryFn: async () => {
      const { data, error: queryError } = await supabase
        .from("crm_property_catalog")
        .select(
          "external_id,title,address,neighborhood,city,code,wimoveis_code,dfimoveis_code,value",
        )
        .order("created_at", { ascending: false });
      if (queryError) throw queryError;
      return (data ?? []) as PropertyOption[];
    },
    staleTime: 30_000,
  });
  const assignments = useQuery({
    queryKey: ["sales-report-capturers"],
    enabled: Boolean(profile),
    queryFn: async () => {
      const { data, error: queryError } = await supabase.rpc("get_property_capturer_assignments");
      if (queryError) throw queryError;
      return (data ?? []) as CapturerAssignment[];
    },
  });
  const [month, setMonth] = useState(() => new Date().toISOString().slice(0, 7));
  const [sellerFilter, setSellerFilter] = useState("all");
  const [search, setSearch] = useState("");
  const [editingId, setEditingId] = useState<string | null>(null);
  const [form, setForm] = useState<Form>(emptyForm);
  const [showForm, setShowForm] = useState(false);
  const [saving, setSaving] = useState(false);
  const [deletingId, setDeletingId] = useState<string | null>(null);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [propertySearch, setPropertySearch] = useState("");
  const [showPropertyOptions, setShowPropertyOptions] = useState(false);
  const propertyPicker = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!showPropertyOptions) return;
    const close = (event: MouseEvent) => {
      if (!propertyPicker.current?.contains(event.target as Node)) setShowPropertyOptions(false);
    };
    document.addEventListener("mousedown", close);
    return () => document.removeEventListener("mousedown", close);
  }, [showPropertyOptions]);
  const bounds = monthBounds(month);
  const sales = useQuery({
    queryKey: ["crm-sales", month],
    enabled: Boolean(profile),
    refetchInterval: 15_000,
    queryFn: async () => {
      const { data, error: queryError } = await supabase
        .from("crm_sales")
        .select("*")
        .gte("sold_on", bounds[0])
        .lt("sold_on", bounds[1])
        .order("sold_on", { ascending: false });
      if (queryError) throw queryError;
      return (data ?? []) as Sale[];
    },
  });
  const financials = useQuery({
    queryKey: ["crm-sale-financials", month, (sales.data ?? []).map((sale) => sale.id).join(",")],
    enabled: Boolean(profile && canSeeMoney && sales.isSuccess),
    queryFn: async () => {
      const ids = (sales.data ?? []).map((sale) => sale.id);
      if (!ids.length) return [] as Financial[];
      const { data, error: queryError } = await supabase
        .from("crm_sale_financials")
        .select("sale_id,purchase_price,commission_amount")
        .in("sale_id", ids);
      if (queryError) throw queryError;
      return (data ?? []) as Financial[];
    },
  });
  const financialById = new Map((financials.data ?? []).map((item) => [item.sale_id, item]));
  const names = useMemo(
    () => new Map((brokers.data ?? []).map((item) => [item.id, item.fullName])),
    [brokers.data],
  );
  const filteredProperties = useMemo(() => {
    const searchTerm = normalizedSearch(propertySearch);
    return (properties.data ?? [])
      .filter(
        (property) =>
          !searchTerm ||
          [
            property.title,
            property.address,
            property.neighborhood,
            property.city,
            property.code,
            property.wimoveis_code,
            property.dfimoveis_code,
          ].some((value) => normalizedSearch(value).includes(searchTerm)),
      )
      .slice(0, 12);
  }, [properties.data, propertySearch]);
  const visible = useMemo(
    () =>
      (sales.data ?? []).filter(
        (sale) =>
          (sellerFilter === "all" || sale.seller_id === sellerFilter) &&
          `${sale.buyer_name} ${sale.property_address} ${names.get(sale.seller_id) ?? ""}`
            .toLocaleLowerCase("pt-BR")
            .includes(search.toLocaleLowerCase("pt-BR")),
      ),
    [sales.data, sellerFilter, search, names],
  );
  const ranking = useMemo(() => {
    const counts = new Map<string, number>();
    for (const sale of sales.data ?? [])
      counts.set(sale.seller_id, (counts.get(sale.seller_id) ?? 0) + 1);
    return [...counts]
      .map(([id, count]) => ({ id, count, name: names.get(id) ?? "Corretor" }))
      .sort((a, b) => b.count - a.count || a.name.localeCompare(b.name, "pt-BR"));
  }, [sales.data, names]);
  const total = visible.reduce(
    (sum, sale) => sum + Number(financialById.get(sale.id)?.purchase_price ?? 0),
    0,
  );
  const totalCommission = visible.reduce(
    (sum, sale) => sum + Number(financialById.get(sale.id)?.commission_amount ?? 0),
    0,
  );

  function openForm(sale?: Sale) {
    setError("");
    setNotice("");
    setEditingId(sale?.id ?? null);
    const financial = sale ? financialById.get(sale.id) : undefined;
    const selectedProperty = (properties.data ?? []).find(
      (item) => item.external_id === sale?.property_id,
    );
    setPropertySearch(
      selectedProperty ? propertyLabel(selectedProperty) : (sale?.property_address ?? ""),
    );
    setShowPropertyOptions(false);
    setForm(
      sale
        ? {
            property_id: sale.property_id ?? "",
            seller_id: sale.seller_id,
            capturer_id: sale.capturer_id ?? "",
            capturer_name: sale.capturer_name,
            buyer_name: sale.buyer_name,
            buyer_email: sale.buyer_email ?? "",
            buyer_phone: formatPhone(sale.buyer_phone ?? ""),
            buyer_birth_date: sale.buyer_birth_date ?? "",
            property_address: sale.property_address,
            sold_on: sale.sold_on,
            contract_signed_on: sale.contract_signed_on ?? "",
            deed_on: sale.deed_on ?? "",
            expected_delivery_at: localInput(sale.expected_delivery_at),
            delivered_at: localInput(sale.delivered_at),
            has_financing: sale.has_financing,
            purchase_price: storedMoney(financial?.purchase_price),
            commission_amount: storedMoney(financial?.commission_amount),
          }
        : { ...emptyForm, sold_on: new Date().toISOString().slice(0, 10) },
    );
    setShowForm(true);
  }
  function set<K extends keyof Form>(key: K, value: Form[K]) {
    setForm((current) => ({ ...current, [key]: value }));
  }
  function selectProperty(property: PropertyOption) {
    const matching = (assignments.data ?? []).filter(
      (item) => item.property_id === property.external_id,
    );
    const capturer = matching.length === 1 ? matching[0] : null;
    const financialIsLocked = Boolean(
      editingId && sales.data?.find((item) => item.id === editingId)?.financial_submitted_at,
    );
    setForm((current) => ({
      ...current,
      property_id: property.external_id,
      property_address: propertyLabel(property),
      capturer_id: capturer?.broker_id && names.has(capturer.broker_id) ? capturer.broker_id : "",
      capturer_name: capturer?.broker_name ?? "",
      purchase_price:
        !financialIsLocked && !current.purchase_price && property.value
          ? storedMoney(property.value)
          : current.purchase_price,
    }));
    setPropertySearch(propertyLabel(property));
    setShowPropertyOptions(false);
  }
  async function save() {
    if (!canEdit || saving) return;
    setError("");
    setNotice("");
    if (
      !form.seller_id ||
      !form.buyer_name.trim() ||
      !form.property_id ||
      !form.sold_on ||
      !form.expected_delivery_at ||
      !form.capturer_name.trim()
    ) {
      setError(
        "Selecione corretor, imóvel cadastrado e captador; preencha comprador e as datas da venda e entrega prevista.",
      );
      return;
    }
    if (
      (form.purchase_price && !form.commission_amount) ||
      (!form.purchase_price && form.commission_amount)
    ) {
      setError("Preencha o valor da venda e da comissão juntos.");
      return;
    }
    const previouslySubmitted = Boolean(
      editingId && sales.data?.find((item) => item.id === editingId)?.financial_submitted_at,
    );
    if (!editingId && (!form.purchase_price || !form.commission_amount)) {
      setError("Informe o valor da compra e venda e a comissão.");
      return;
    }
    const phoneDigits = form.buyer_phone.replace(/\D/g, "");
    if (phoneDigits && ![10, 11].includes(phoneDigits.length)) {
      setError("Informe o telefone com DDD, no formato (62) 99555-7266.");
      return;
    }
    if (
      (form.purchase_price &&
        (!Number.isFinite(parseMoney(form.purchase_price)) ||
          parseMoney(form.purchase_price) <= 0)) ||
      (form.commission_amount &&
        (!Number.isFinite(parseMoney(form.commission_amount)) ||
          parseMoney(form.commission_amount) <= 0))
    ) {
      setError("Informe valores monetários maiores que zero.");
      return;
    }
    setSaving(true);
    try {
      const values: Record<string, unknown> = {
        seller_id: form.seller_id,
        capturer_id: form.capturer_id || null,
        capturer_name: form.capturer_name,
        buyer_name: form.buyer_name,
        buyer_email: form.buyer_email,
        buyer_phone: form.buyer_phone,
        buyer_birth_date: form.buyer_birth_date,
        property_address: form.property_address,
        sold_on: form.sold_on,
        contract_signed_on: form.contract_signed_on,
        deed_on: form.deed_on,
        expected_delivery_at: new Date(form.expected_delivery_at).toISOString(),
        delivered_at: form.delivered_at ? new Date(form.delivered_at).toISOString() : null,
        has_financing: form.has_financing,
      };
      if (canSeeMoney || !previouslySubmitted) {
        if (form.purchase_price && form.commission_amount) {
          values.purchase_price = parseMoney(form.purchase_price);
          values.commission_amount = parseMoney(form.commission_amount);
        }
      }
      const { error: saveError } = await supabase.rpc("save_crm_sale_with_property", {
        p_sale_id: editingId,
        p_property_id: form.property_id,
        p_values: values,
      });
      if (saveError) throw saveError;
      setShowForm(false);
      setForm(emptyForm);
      setNotice("Venda salva. Os compromissos serão criados automaticamente na agenda.");
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ["crm-sales"] }),
        queryClient.invalidateQueries({ queryKey: ["crm-sale-financials"] }),
        queryClient.invalidateQueries({ queryKey: ["agenda"] }),
        queryClient.invalidateQueries({ queryKey: DAILY_REVENUE_QUERY_KEY }),
        queryClient.invalidateQueries({ queryKey: ["capture-ranking-rows"] }),
      ]);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Não foi possível salvar a venda.");
    } finally {
      setSaving(false);
    }
  }

  async function removeSale(sale: Sale) {
    if (!isAdministradorAdmin(profile) || deletingId) return;
    if (
      !window.confirm(
        `Excluir o lançamento de ${sale.buyer_name}? Os valores, documentos e compromissos ligados a esta venda também serão removidos.`,
      )
    ) {
      return;
    }

    setError("");
    setNotice("");
    setDeletingId(sale.id);
    try {
      const { data, error: deleteError } = await supabase.rpc("delete_crm_sale", {
        p_sale_id: sale.id,
      });
      if (deleteError) throw deleteError;
      setNotice(`Lançamento de ${data || sale.buyer_name} excluído.`);
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ["crm-sales"] }),
        queryClient.invalidateQueries({ queryKey: ["crm-sale-financials"] }),
        queryClient.invalidateQueries({ queryKey: ["agenda"] }),
        queryClient.invalidateQueries({ queryKey: DAILY_REVENUE_QUERY_KEY }),
        queryClient.invalidateQueries({ queryKey: ["capture-ranking-rows"] }),
      ]);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Não foi possível excluir a venda.");
    } finally {
      setDeletingId(null);
    }
  }

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <p className="text-[11px] uppercase tracking-[.24em] text-muted-foreground">
            Relatório mensal
          </p>
          <h1 className="mt-2 text-3xl font-semibold">Vendas</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Corretores, compradores, entrega do imóvel e pós-venda em uma só esteira.
          </p>
        </div>
        {canEdit && (
          <Button onClick={() => openForm()}>
            <Plus size={16} className="mr-2" /> Registrar venda
          </Button>
        )}
      </div>
      {notice && (
        <p className="rounded-lg border border-emerald-400/30 bg-emerald-500/10 p-3 text-sm text-emerald-200">
          {notice}
        </p>
      )}
      {error && (
        <p
          role="alert"
          className="rounded-lg border border-red-400/30 bg-red-500/10 p-3 text-sm text-red-200"
        >
          {error}
        </p>
      )}
      <div className={`grid gap-3 ${canSeeMoney ? "sm:grid-cols-4" : "sm:grid-cols-2"}`}>
        <div className="rounded-xl border border-white/10 bg-white/[.03] p-4">
          <span className="text-xs text-muted-foreground">Vendas no período</span>
          <p className="mt-1 text-2xl font-semibold">{visible.length}</p>
        </div>
        <div className="rounded-xl border border-white/10 bg-white/[.03] p-4">
          <span className="text-xs text-muted-foreground">Entregas pendentes</span>
          <p className="mt-1 text-2xl font-semibold">
            {visible.filter((sale) => !sale.delivered_at).length}
          </p>
        </div>
        {canSeeMoney && (
          <>
            <div className="rounded-xl border border-white/10 bg-white/[.03] p-4">
              <span className="text-xs text-muted-foreground">Volume vendido</span>
              <p className="mt-1 text-2xl font-semibold">{money(total)}</p>
            </div>
            <div className="rounded-xl border border-white/10 bg-white/[.03] p-4">
              <span className="text-xs text-muted-foreground">Comissão total</span>
              <p className="mt-1 text-2xl font-semibold">{money(totalCommission)}</p>
            </div>
          </>
        )}
      </div>
      <div className="grid gap-3 rounded-xl border border-white/10 bg-white/[.03] p-4 md:grid-cols-[170px_1fr_1fr]">
        <input
          aria-label="Mês do relatório"
          type="month"
          value={month}
          onChange={(event) => setMonth(event.target.value)}
          className="rounded-lg border border-white/10 bg-background p-2 text-sm"
        />
        <select
          aria-label="Filtrar corretor"
          value={sellerFilter}
          onChange={(event) => setSellerFilter(event.target.value)}
          className="rounded-lg border border-white/10 bg-background p-2 text-sm"
        >
          <option value="all">Todos os corretores</option>
          {(brokers.data ?? []).map((broker) => (
            <option key={broker.id} value={broker.id}>
              {broker.fullName}
            </option>
          ))}
        </select>
        <label className="flex items-center gap-2 rounded-lg border border-white/10 bg-background px-3">
          <Search size={16} className="text-muted-foreground" />
          <input
            aria-label="Buscar vendas"
            value={search}
            onChange={(event) => setSearch(event.target.value)}
            placeholder="Buscar comprador ou imóvel"
            className="w-full bg-transparent py-2 text-sm outline-none"
          />
        </label>
      </div>
      {ranking.length > 0 && (
        <section className="rounded-xl border border-white/10 bg-white/[.03] p-4 sm:p-5">
          <div className="flex items-end justify-between gap-3">
            <div>
              <p className="text-xs uppercase tracking-widest text-copper">Pontuação mensal</p>
              <h2 className="mt-1 text-lg font-semibold">Vendas por corretor</h2>
            </div>
            <span className="text-xs text-muted-foreground">1 venda = 1 ponto</span>
          </div>
          <div className="mt-4 grid gap-2 sm:grid-cols-2">
            {ranking.map((broker, index) => (
              <button
                key={broker.id}
                onClick={() => setSellerFilter(broker.id === sellerFilter ? "all" : broker.id)}
                className={`rounded-lg border p-3 text-left transition ${sellerFilter === broker.id ? "border-copper/50 bg-copper/10" : "border-white/10 hover:bg-white/5"}`}
              >
                <div className="flex items-center justify-between gap-3 text-sm">
                  <span>
                    <span className="mr-2 text-copper">#{index + 1}</span>
                    {broker.name}
                  </span>
                  <b>
                    {broker.count} {broker.count === 1 ? "ponto" : "pontos"}
                  </b>
                </div>
                <div className="mt-2 h-1.5 overflow-hidden rounded-full bg-white/10">
                  <div
                    className="h-full rounded-full bg-copper"
                    style={{ width: `${Math.round((broker.count / ranking[0].count) * 100)}%` }}
                  />
                </div>
              </button>
            ))}
          </div>
        </section>
      )}
      {sales.isLoading ? (
        <p className="text-sm text-muted-foreground">Carregando vendas...</p>
      ) : sales.error ? (
        <p role="alert" className="text-sm text-red-300">
          {sales.error.message}
        </p>
      ) : visible.length === 0 ? (
        <p className="rounded-xl border border-white/10 bg-white/[.02] p-6 text-sm text-muted-foreground">
          Nenhuma venda encontrada neste mês.
        </p>
      ) : (
        <div className="space-y-3">
          {visible.map((sale) => {
            const financial = financialById.get(sale.id);
            return (
              <article
                key={sale.id}
                className="rounded-xl border border-white/10 bg-white/[.03] p-4 sm:p-5"
              >
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div>
                    <p className="text-lg font-semibold">
                      {sale.buyer_name || "Comprador pendente"}
                    </p>
                    <p className="text-sm text-muted-foreground">{sale.property_address}</p>
                    {sale.legacy_incomplete && (
                      <p className="mt-1 text-xs text-amber-300">
                        Migrada do preenchimento diário · complete comprador e entrega prevista
                      </p>
                    )}
                  </div>
                  <span className="rounded-full border border-copper/30 bg-copper/10 px-3 py-1 text-xs text-copper">
                    {names.get(sale.seller_id) ?? "Corretor"}
                  </span>
                </div>
                <div className="mt-4 grid gap-3 text-sm sm:grid-cols-2 lg:grid-cols-4">
                  <div>
                    <span className="text-xs text-muted-foreground">Venda</span>
                    <p>{day(sale.sold_on)}</p>
                  </div>
                  <div>
                    <span className="text-xs text-muted-foreground">Contrato</span>
                    <p>{day(sale.contract_signed_on)}</p>
                  </div>
                  <div>
                    <span className="text-xs text-muted-foreground">Escritura</span>
                    <p>{day(sale.deed_on)}</p>
                  </div>
                  <div>
                    <span className="text-xs text-muted-foreground">Captador</span>
                    <p>{sale.capturer_name}</p>
                  </div>
                  <div>
                    <span className="text-xs text-muted-foreground">Entrega prevista</span>
                    <p>{dateTime(sale.expected_delivery_at)}</p>
                  </div>
                  <div>
                    <span className="text-xs text-muted-foreground">Entrega realizada</span>
                    <p>{dateTime(sale.delivered_at)}</p>
                  </div>
                  <div>
                    <span className="text-xs text-muted-foreground">Financiamento</span>
                    <p>{sale.has_financing ? "Sim" : "Não"}</p>
                  </div>
                  <div>
                    <span className="text-xs text-muted-foreground">Aniversário</span>
                    <p>{day(sale.buyer_birth_date)}</p>
                  </div>
                  {canSeeMoney && (
                    <>
                      <div>
                        <span className="text-xs text-muted-foreground">Compra e venda</span>
                        <p>{money(financial?.purchase_price)}</p>
                      </div>
                      <div>
                        <span className="text-xs text-muted-foreground">Comissão</span>
                        <p>{money(financial?.commission_amount)}</p>
                      </div>
                    </>
                  )}
                </div>
                {sale.financial_submitted_at && !canSeeMoney && (
                  <p className="mt-3 text-xs text-muted-foreground">
                    Valores enviados. Visualização reservada a Administrador e AcessoCRM.
                  </p>
                )}
                <div className="mt-4 flex flex-wrap gap-2">
                  {canEdit && (
                    <Button size="sm" variant="outline" onClick={() => openForm(sale)}>
                      Editar relatório
                    </Button>
                  )}
                  {isAdministradorAdmin(profile) && (
                    <Button
                      size="sm"
                      variant="ghost"
                      className="text-red-300 hover:bg-red-500/10 hover:text-red-200"
                      disabled={deletingId === sale.id}
                      onClick={() => void removeSale(sale)}
                    >
                      {deletingId === sale.id ? (
                        <Loader2 size={15} className="mr-1 animate-spin" />
                      ) : (
                        <Trash2 size={15} className="mr-1" />
                      )}
                      Excluir lançamento
                    </Button>
                  )}
                  {sale.has_financing && (
                    <Button size="sm" variant="ghost" asChild>
                      <Link to="/financiamento">
                        <Landmark size={15} className="mr-1" /> Ver financiamento
                      </Link>
                    </Button>
                  )}
                  <Button size="sm" variant="ghost" asChild>
                    <Link to="/agenda">
                      <CalendarDays size={15} className="mr-1" /> Agenda
                    </Link>
                  </Button>
                </div>
              </article>
            );
          })}
        </div>
      )}
      <RentalReport month={month} brokers={brokers.data ?? []} canManage={canSeeMoney} />
      {showForm && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/75 p-2 sm:p-4"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) setShowForm(false);
          }}
        >
          <div className="max-h-[95dvh] w-full max-w-3xl overflow-y-auto rounded-2xl border border-white/15 bg-background p-4 shadow-2xl sm:p-6">
            <div className="flex items-start justify-between">
              <div>
                <p className="text-xs uppercase tracking-widest text-copper">Relatório de vendas</p>
                <h2 className="mt-1 text-xl font-semibold">
                  {editingId ? "Editar venda" : "Nova venda"}
                </h2>
              </div>
              <button aria-label="Fechar" onClick={() => setShowForm(false)}>
                <X size={20} />
              </button>
            </div>
            {error && (
              <p role="alert" className="mt-4 rounded-lg bg-red-500/10 p-3 text-sm text-red-200">
                {error}
              </p>
            )}
            <div className="mt-5 grid gap-4 sm:grid-cols-2">
              <label className="text-sm">
                Corretor que vendeu *
                <select
                  value={form.seller_id}
                  onChange={(event) => set("seller_id", event.target.value)}
                  className="mt-1 w-full rounded-lg border border-white/10 bg-background p-2"
                >
                  <option value="">Selecione</option>
                  {(brokers.data ?? []).map((broker) => (
                    <option key={broker.id} value={broker.id}>
                      {broker.fullName}
                    </option>
                  ))}
                </select>
              </label>
              <label className="text-sm">
                Captador do imóvel *
                <select
                  value={form.capturer_id}
                  onChange={(event) => {
                    const id = event.target.value;
                    setForm((current) => ({
                      ...current,
                      capturer_id: id,
                      capturer_name: names.get(id) ?? current.capturer_name,
                    }));
                  }}
                  className="mt-1 w-full rounded-lg border border-white/10 bg-background p-2"
                >
                  <option value="">Informar nome abaixo</option>
                  {(brokers.data ?? []).map((broker) => (
                    <option key={broker.id} value={broker.id}>
                      {broker.fullName}
                    </option>
                  ))}
                </select>
                <input
                  value={form.capturer_name}
                  onChange={(event) => set("capturer_name", event.target.value)}
                  placeholder="Nome do captador"
                  className="mt-2 w-full rounded-lg border border-white/10 bg-background p-2"
                />
              </label>
              <Field
                label="Nome do comprador *"
                value={form.buyer_name}
                onChange={(value) => set("buyer_name", value)}
              />
              <div ref={propertyPicker} className="relative text-sm sm:col-span-2">
                Imóvel de interesse *
                <input
                  value={propertySearch}
                  onChange={(event) => {
                    setPropertySearch(event.target.value);
                    setForm((current) => ({ ...current, property_id: "", property_address: "" }));
                    setShowPropertyOptions(true);
                  }}
                  onFocus={() => setShowPropertyOptions(true)}
                  placeholder={
                    properties.isLoading
                      ? "Carregando imóveis..."
                      : "Digite endereço, código ou nome do imóvel"
                  }
                  autoComplete="off"
                  className="mt-1 w-full rounded-lg border border-white/10 bg-background p-2"
                />
                {showPropertyOptions && (
                  <div className="absolute z-50 mt-1 max-h-72 w-full overflow-y-auto rounded-xl border border-white/10 bg-popover p-1.5 text-popover-foreground shadow-2xl">
                    {filteredProperties.length === 0 ? (
                      <p className="p-3 text-xs text-muted-foreground">
                        Nenhum imóvel cadastrado encontrado.
                      </p>
                    ) : (
                      filteredProperties.map((property) => (
                        <button
                          key={property.external_id}
                          type="button"
                          onClick={() => selectProperty(property)}
                          className="block w-full rounded-lg px-3 py-2 text-left hover:bg-white/[.06]"
                        >
                          <span className="block text-sm font-medium text-foreground">
                            {propertyLabel(property)}
                          </span>
                          <span className="block text-xs text-muted-foreground">
                            {[property.neighborhood, property.city, property.code]
                              .filter(Boolean)
                              .join(" · ") || property.title}
                          </span>
                          <span className="block text-xs text-emerald-300">
                            {property.value ? money(property.value) : "Valor não informado"}
                          </span>
                        </button>
                      ))
                    )}
                  </div>
                )}
                {form.property_id && (
                  <p className="mt-1 text-xs text-emerald-300">Imóvel cadastrado selecionado</p>
                )}
              </div>
              <Field
                label="E-mail do comprador"
                type="email"
                value={form.buyer_email}
                onChange={(value) => set("buyer_email", value)}
              />
              <Field
                label="Telefone do comprador"
                type="tel"
                value={form.buyer_phone}
                onChange={(value) => set("buyer_phone", formatPhone(value))}
              />
              <Field
                label="Data de nascimento do comprador"
                type="date"
                value={form.buyer_birth_date}
                onChange={(value) => set("buyer_birth_date", value)}
              />
              <Field
                label="Data da venda *"
                type="date"
                value={form.sold_on}
                onChange={(value) => set("sold_on", value)}
              />
              <Field
                label="Assinatura do contrato"
                type="date"
                value={form.contract_signed_on}
                onChange={(value) => set("contract_signed_on", value)}
              />
              <Field
                label="Data da escritura"
                type="date"
                value={form.deed_on}
                onChange={(value) => set("deed_on", value)}
              />
              <Field
                label="Entrega prevista para *"
                type="datetime-local"
                value={form.expected_delivery_at}
                onChange={(value) => set("expected_delivery_at", value)}
              />
              <Field
                label="Data e hora da entrega realizada"
                type="datetime-local"
                value={form.delivered_at}
                onChange={(value) => set("delivered_at", value)}
              />
              <label className="text-sm">
                Tem financiamento?
                <select
                  value={form.has_financing ? "yes" : "no"}
                  onChange={(event) => set("has_financing", event.target.value === "yes")}
                  className="mt-1 w-full rounded-lg border border-white/10 bg-background p-2"
                >
                  <option value="no">Não</option>
                  <option value="yes">Sim</option>
                </select>
              </label>
              {(!editingId ||
                canSeeMoney ||
                !sales.data?.find((item) => item.id === editingId)?.financial_submitted_at) && (
                <>
                  <MoneyField
                    label="Valor da compra e venda *"
                    value={form.purchase_price}
                    onChange={(value) => set("purchase_price", value)}
                  />
                  <MoneyField
                    label="Valor da comissão *"
                    value={form.commission_amount}
                    onChange={(value) => set("commission_amount", value)}
                  />
                </>
              )}
            </div>
            {!canSeeMoney &&
              editingId &&
              sales.data?.find((item) => item.id === editingId)?.financial_submitted_at && (
                <p className="mt-4 text-sm text-muted-foreground">
                  Os valores financeiros já foram enviados e não podem ser vistos ou alterados por
                  este perfil.
                </p>
              )}
            <div className="mt-6 flex justify-end gap-2">
              <Button variant="ghost" onClick={() => setShowForm(false)}>
                Cancelar
              </Button>
              <Button disabled={saving} onClick={() => void save()}>
                {saving ? (
                  <Loader2 size={16} className="mr-2 animate-spin" />
                ) : (
                  <Save size={16} className="mr-2" />
                )}{" "}
                Salvar venda
              </Button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

function Field({
  label,
  value,
  onChange,
  type = "text",
}: {
  label: string;
  value: string;
  onChange: (value: string) => void;
  type?: string;
}) {
  return (
    <label className="text-sm">
      {label}
      <input
        type={type}
        value={value}
        onChange={(event) => onChange(event.target.value)}
        min={type === "number" ? "0" : undefined}
        step={type === "number" ? "0.01" : undefined}
        className="mt-1 w-full rounded-lg border border-white/10 bg-background p-2"
      />
    </label>
  );
}

function MoneyField({
  label,
  value,
  onChange,
}: {
  label: string;
  value: string;
  onChange: (value: string) => void;
}) {
  return (
    <label className="text-sm">
      {label}
      <input
        value={value}
        inputMode="decimal"
        autoComplete="off"
        placeholder="0,00"
        onChange={(event) => onChange(formatMoneyInput(event.target.value))}
        onBlur={() => {
          if (value && Number.isFinite(parseMoney(value))) onChange(storedMoney(parseMoney(value)));
        }}
        className="mt-1 w-full rounded-lg border border-white/10 bg-background p-2"
      />
    </label>
  );
}

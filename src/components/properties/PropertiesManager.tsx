import { ExternalLink, Loader2, Search, Trash2 } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Panel } from "@/components/dashboard/Panel";
import { deleteProperty, propertiesFromDashboard, type Property } from "@/lib/properties";
import type { DashboardData } from "@/lib/api";
import { useAuth } from "@/components/auth/AuthProvider";
import { PropertyCreateDialog } from "@/components/properties/PropertyCreateDialog";
import { PropertyBrokerAssignmentDialog } from "@/components/properties/PropertyBrokerAssignmentDialog";
import { PropertyCapturerSelect } from "@/components/properties/PropertyCapturerSelect";
import { PropertyValueReviewDialog } from "@/components/properties/PropertyValueReviewDialog";
import { useBrokerProfiles, type AccessProfile } from "@/lib/lead-access";
import { supabase } from "@/lib/supabase";
import { displayBrokerName } from "@/lib/broker-names";
import { canEditPropertyPortalCodes, isAdministradorAdmin, isRestrictedAdmin } from "@/lib/admin-access";

type PropertyTab = "Todos" | "Ativos" | "Vendidos" | "Alugados";

function matchesTab(property: Property, tab: PropertyTab) {
  if (tab === "Todos") return true;
  const status = property.status?.trim().toLocaleLowerCase("pt-BR");
  if (tab === "Ativos") return status === "ativo";
  if (tab === "Vendidos") return status === "vendido";
  return status === "alugado";
}

function normalizedPropertyReference(value?: string) {
  return (value ?? "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .trim()
    .replace(/\s+/g, " ")
    .toLocaleLowerCase("pt-BR");
}

function propertyRequiresDocuments(property: Property) {
  const purpose = property.purpose
    ?.normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .trim()
    .toLocaleLowerCase("pt-BR");
  return purpose !== "locacao" && purpose !== "aluguel";
}

function propertyExclusivityLabel(property: Property) {
  switch (property.sonialimaExclusivityControl) {
    case "COM EXCLUSIVIDADE":
      return "Com exclusividade";
    case "SEM EXCLUSIVIDADE":
      return "Sem exclusividade";
    case "SEM AUTORIZACAO DE VENDA":
      return "Sem autorização";
    default:
      // Mantém os imóveis legados legíveis enquanto Administrador ainda não tiver
      // preenchido o controle interno de exclusividade.
      return property.modalidade || "Não informado";
  }
}

export function PropertiesManager({
  data,
  loading,
  error,
  retry,
}: {
  data?: DashboardData;
  loading: boolean;
  error?: Error | null;
  retry: () => void;
}) {
  const { profile, session } = useAuth();
  const restrictedAdmin = isRestrictedAdmin(profile);
  const allysonAdmin = isAdministradorAdmin(profile);
  const canEditPortalCodes = canEditPropertyPortalCodes(profile);
  const canDeleteProperties = allysonAdmin;
  const canManageBrokerAssignments = allysonAdmin;
  const brokerProfiles = useBrokerProfiles(Boolean(profile));
  // crmallyson também participa da operação comercial. Por isso deve estar
  // disponível ao definir tanto o corretor responsável quanto o captador.
  const propertyParticipants = useMemo<AccessProfile[]>(() => {
    const participants = new Map(
      (brokerProfiles.data ?? []).map((broker) => [broker.id, broker]),
    );
    if (allysonAdmin && profile) {
      participants.set(profile.id, {
        id: profile.id,
        fullName: "crmallyson",
        email: profile.email,
        role: "broker",
      });
    }
    return [...participants.values()].sort((left, right) =>
      displayBrokerName(left.fullName).localeCompare(displayBrokerName(right.fullName), "pt-BR"),
    );
  }, [allysonAdmin, brokerProfiles.data, profile]);
  const brokerNames = propertyParticipants.map((broker) => broker.fullName);
  const [propertyCapturers, setPropertyCapturers] = useState<Record<string, string[]>>({});
  const [documentNotifications, setDocumentNotifications] = useState<Record<string, boolean>>({});
  const [publicLinks, setPublicLinks] = useState<Record<string, string>>({});
  const [reviewability, setReviewability] = useState<Record<string, boolean>>({});
  const [reviewingProperty, setReviewingProperty] = useState<Property>();
  const [notificationContext, setNotificationContext] = useState({
    title: "",
    body: "",
    requestId: "",
  });
  const [linksVersion, setLinksVersion] = useState(0);
  const [query, setQuery] = useState("");
  const [tab, setTab] = useState<PropertyTab>("Ativos");
  const [page, setPage] = useState(1);
  const tableScrollRef = useRef<HTMLDivElement>(null);
  const fixedScrollRef = useRef<HTMLDivElement>(null);
  const dragRef = useRef({ active: false, startX: 0, startScrollLeft: 0 });
  const viewRestoredRef = useRef("");
  const [tableScrollWidth, setTableScrollWidth] = useState(0);
  const [tableClientWidth, setTableClientWidth] = useState(0);
  const [deletingProperty, setDeletingProperty] = useState<Property>();
  const [deleting, setDeleting] = useState(false);
  const [deleteError, setDeleteError] = useState("");

  useEffect(() => {
    if (!profile) return;
    let active = true;
    void supabase.rpc("get_property_capturer_assignments").then(({ data: assignments }) => {
      if (!active) return;
      setPropertyCapturers(
        ((assignments ?? []) as { property_id: string; broker_id: string }[]).reduce<
          Record<string, string[]>
        >((grouped, item) => {
          grouped[item.property_id] = [...(grouped[item.property_id] ?? []), item.broker_id];
          return grouped;
        }, {}),
      );
    });
    return () => {
      active = false;
    };
  }, [profile]);
  useEffect(() => {
    if (!profile) return;
    let active = true;
    void supabase.rpc("get_property_document_notification_states").then(({ data: states }) => {
      if (!active) return;
      setDocumentNotifications(
        ((states ?? []) as { property_id: string; effective_enabled: boolean }[]).reduce<
          Record<string, boolean>
        >((result, item) => {
          result[item.property_id] = item.effective_enabled;
          return result;
        }, {}),
      );
    });
    return () => {
      active = false;
    };
  }, [profile]);
  const capturerNames = (propertyId: string) =>
    (propertyCapturers[propertyId] ?? [])
      .map((capturerId) => {
        if (capturerId === "__sonialima__") return "Sônia Lima";
        const capturer = brokerProfiles.data?.find((broker) => broker.id === capturerId);
        return capturer ? displayBrokerName(capturer.fullName) || capturer.email : "";
      })
      .filter(Boolean)
      .join(", ") || "—";
  const canEditPropertyCaptureSheet = (property: Property) =>
    allysonAdmin ||
    (!restrictedAdmin && property.status?.trim().toLocaleLowerCase("pt-BR") === "ativo");
  const allProperties = useMemo(() => {
    const leadsByProperty = new Map<string, number>();
    for (const lead of data?.leads ?? []) {
      const propertyReference = normalizedPropertyReference(lead.imovel);
      if (!propertyReference) continue;
      leadsByProperty.set(propertyReference, (leadsByProperty.get(propertyReference) ?? 0) + 1);
    }

    return propertiesFromDashboard(data).map((property) => ({
      ...property,
      publicUrl: publicLinks[property.id],
      reviewable: reviewability[property.id] ?? false,
      leadCount: leadsByProperty.get(normalizedPropertyReference(property.title)) ?? 0,
    }));
  }, [data, publicLinks, reviewability]);
  const properties = useMemo(
    () =>
      allProperties.filter(
        (property) =>
          matchesTab(property, tab) &&
          [
            property.wimoveisCode,
            property.dfimoveisCode,
            property.title,
            canManageBrokerAssignments ? property.broker : undefined,
            property.city,
            property.neighborhood,
          ].some((value) => value?.toLowerCase().includes(query.toLowerCase())),
      ),
    [allProperties, canManageBrokerAssignments, query, tab],
  );
  const pageSize = 8;
  const pages = Math.max(1, Math.ceil(properties.length / pageSize));
  const rows = properties.slice((page - 1) * pageSize, page * pageSize);

  useEffect(() => {
    if (!loading && page > pages) setPage(pages);
  }, [loading, page, pages]);

  const viewMemoryKey = `sonialima-crm:properties-view:${session?.user.id || "anonymous"}`;
  useEffect(() => {
    if (typeof window === "undefined" || viewRestoredRef.current === viewMemoryKey) return;
    viewRestoredRef.current = viewMemoryKey;
    try {
      const saved = JSON.parse(sessionStorage.getItem(viewMemoryKey) || "null") as {
        page?: number;
        query?: string;
        tab?: PropertyTab;
        scrollLeft?: number;
      } | null;
      if (!saved) return;
      if (typeof saved.query === "string") setQuery(saved.query);
      if (
        saved.tab &&
        ["Todos", "Ativos", "Vendidos", "Alugados"].includes(saved.tab)
      ) {
        setTab(saved.tab);
      }
      if (Number.isInteger(saved.page) && Number(saved.page) > 0) setPage(Number(saved.page));
      requestAnimationFrame(() => {
        if (tableScrollRef.current && Number.isFinite(saved.scrollLeft)) {
          tableScrollRef.current.scrollLeft = Number(saved.scrollLeft);
        }
      });
    } catch {
      sessionStorage.removeItem(viewMemoryKey);
    }
  }, [restrictedAdmin, viewMemoryKey]);

  useEffect(() => {
    if (typeof window === "undefined" || viewRestoredRef.current !== viewMemoryKey) return;
    const scrollLeft = tableScrollRef.current?.scrollLeft ?? 0;
    sessionStorage.setItem(viewMemoryKey, JSON.stringify({ page, query, tab, scrollLeft }));
  }, [page, query, tab, viewMemoryKey]);

  useEffect(() => {
    const table = tableScrollRef.current;
    if (!table) return;
    const measure = () => {
      setTableScrollWidth(table.scrollWidth);
      setTableClientWidth(table.clientWidth);
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(table);
    if (table.firstElementChild) observer.observe(table.firstElementChild);
    return () => observer.disconnect();
  }, [rows.length]);

  const syncHorizontalScroll = (source: "table" | "fixed") => {
    const table = tableScrollRef.current;
    const fixed = fixedScrollRef.current;
    if (!table || !fixed) return;
    if (source === "table") fixed.scrollLeft = table.scrollLeft;
    else table.scrollLeft = fixed.scrollLeft;
    sessionStorage.setItem(
      viewMemoryKey,
      JSON.stringify({ page, query, tab, scrollLeft: table.scrollLeft }),
    );
  };

  const beginTableDrag = (event: React.PointerEvent<HTMLDivElement>) => {
    if ((event.target as HTMLElement).closest("button,a,input,select,textarea,[role='dialog']"))
      return;
    const table = tableScrollRef.current;
    if (!table) return;
    dragRef.current = { active: true, startX: event.clientX, startScrollLeft: table.scrollLeft };
    event.currentTarget.setPointerCapture(event.pointerId);
  };

  const moveTableDrag = (event: React.PointerEvent<HTMLDivElement>) => {
    if (!dragRef.current.active || !tableScrollRef.current) return;
    tableScrollRef.current.scrollLeft =
      dragRef.current.startScrollLeft - (event.clientX - dragRef.current.startX);
    syncHorizontalScroll("table");
  };

  const endTableDrag = () => {
    dragRef.current.active = false;
  };

  useEffect(() => {
    let active = true;
    void Promise.all([
      supabase.from("crm_property_public_links").select("property_id, url"),
      supabase.from("crm_property_reviewability").select("property_id, reviewable"),
    ]).then(([linksResult, reviewabilityResult]) => {
      if (!active) return;
      if (linksResult.data)
        setPublicLinks(
          Object.fromEntries(linksResult.data.map((item) => [item.property_id, item.url])),
        );
      if (reviewabilityResult.data)
        setReviewability(
          Object.fromEntries(
            reviewabilityResult.data.map((item) => [item.property_id, item.reviewable]),
          ),
        );
    });
    return () => {
      active = false;
    };
  }, [linksVersion, restrictedAdmin]);

  useEffect(() => {
    if (!allProperties.length || typeof window === "undefined") return;
    const params = new URLSearchParams(window.location.search);
    const propertyId =
      params.get("focusPropertyId") ?? sessionStorage.getItem("sonialima-crm:open-property-review");
    if (!propertyId) return;
    const property = allProperties.find((item) => item.id === propertyId);
    if (!property) return;
    setReviewingProperty(property);
    sessionStorage.setItem("sonialima-crm:open-property-review", property.id);
    setNotificationContext({
      title: params.get("notificationTitle") ?? "",
      body: params.get("notificationBody") ?? "",
      requestId: params.get("reviewRequestId") ?? "",
    });
    if (restrictedAdmin && property.reviewable) setTab("Revisáveis");
  }, [allProperties, restrictedAdmin]);

  const refreshProperties = () => {
    setLinksVersion((current) => current + 1);
    retry();
  };

  const updateReviewability = async (property: Property) => {
    if (!allysonAdmin) return;
    const next = !property.reviewable;
    const { error: reviewabilityError } = await supabase.rpc("set_property_reviewability", {
      p_property_id: property.id,
      p_reviewable: next,
    });
    if (!reviewabilityError) setReviewability((current) => ({ ...current, [property.id]: next }));
  };

  const openPropertyReview = (property: Property) => {
    setNotificationContext({ title: "", body: "", requestId: "" });
    setReviewingProperty(property);
    sessionStorage.setItem("sonialima-crm:open-property-review", property.id);
  };

  const closePropertyReview = () => {
    setReviewingProperty(undefined);
    setNotificationContext({ title: "", body: "", requestId: "" });
    if (typeof window === "undefined") return;
    sessionStorage.removeItem("sonialima-crm:open-property-review");
    const url = new URL(window.location.href);
    for (const key of [
      "focusPropertyId",
      "reviewRequestId",
      "notificationId",
      "notificationKind",
      "notificationTitle",
      "notificationBody",
    ])
      url.searchParams.delete(key);
    window.history.replaceState({}, "", `${url.pathname}${url.search}${url.hash}`);
  };

  const removeProperty = async () => {
    if (!deletingProperty || !canDeleteProperties) return;
    setDeleting(true);
    setDeleteError("");
    try {
      await deleteProperty(deletingProperty.id);
      setDeletingProperty(undefined);
      refreshProperties();
    } catch (reason) {
      setDeleteError(
        reason instanceof Error ? reason.message : "Não foi possível excluir o imóvel.",
      );
    } finally {
      setDeleting(false);
    }
  };

  return (
    <>
      <section className="mb-8 flex flex-wrap items-end justify-between gap-4 anim-float-in">
        <div>
          <div className="flex items-center gap-2 text-[11px] uppercase tracking-[0.24em] text-muted-foreground">
            <span className="h-1.5 w-1.5 rounded-full bg-copper shadow-[0_0_10px_var(--copper)]" />
            Portfólio imobiliário
          </div>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Imóveis</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Imóveis referenciados nas oportunidades recebidas pela API.
          </p>
        </div>
        {allysonAdmin && (
          <PropertyCreateDialog
            isAdmin={allysonAdmin}
            brokerName={profile?.fullName}
            brokers={brokerNames}
            capturerProfiles={propertyParticipants}
            existingProperties={allProperties}
            draftOwner={session?.user.id}
            onCreated={refreshProperties}
            canEditExisting
            canSetReviewability
            canEditPortalCodes={canEditPortalCodes}
            canManageBrokerAssignments={canManageBrokerAssignments}
            isSoniaLimaAccount={allysonAdmin}
          />
        )}
      </section>
      <Panel
        title="Portfólio"
        subtitle={`${properties.length} imóvel${properties.length === 1 ? "" : "is"} encontrado${properties.length === 1 ? "" : "s"}`}
      >
        <div className="mb-5 flex flex-wrap gap-2">
          <div className="relative min-w-[240px] flex-1">
            <Search
              size={16}
              className="absolute left-3 top-1/2 -translate-y-1/2 text-muted-foreground"
            />
            <input
              value={query}
              onChange={(e) => {
                setQuery(e.target.value);
                setPage(1);
              }}
              placeholder="Buscar código, título, bairro, cidade ou corretor"
              className="w-full rounded-lg border border-white/10 bg-white/[0.03] py-2.5 pl-10 pr-3 text-sm outline-none focus:border-copper/50"
            />
          </div>
          <div
            role="tablist"
            aria-label="Situação dos imóveis"
            className="flex rounded-lg border border-white/10 bg-white/[0.03] p-1"
          >
            {(
              [
                "Todos",
                "Ativos",
                "Vendidos",
                "Alugados",
              ] as PropertyTab[]
            ).map((item) => (
              <button
                key={item}
                role="tab"
                aria-selected={tab === item}
                onClick={() => {
                  setTab(item);
                  setPage(1);
                }}
                className={`rounded-md px-3 py-1.5 text-xs font-medium transition ${
                  tab === item
                      ? "bg-copper text-white shadow-sm"
                      : "text-muted-foreground hover:text-foreground"
                }`}
              >
                {item}
              </button>
            ))}
          </div>
        </div>
        <div className="space-y-3 lg:hidden">
          {loading ? (
            Array.from({ length: 4 }).map((_, index) => (
              <div key={index} className="rounded-xl border border-white/5 p-4">
                <div className="skeleton h-5 w-2/3" />
                <div className="skeleton mt-3 h-4 w-full" />
                <div className="skeleton mt-2 h-4 w-3/4" />
              </div>
            ))
          ) : error ? (
            <div className="rounded-xl border border-white/5 px-4 py-10 text-center">
              <p className="text-sm text-muted-foreground">Não foi possível carregar os imóveis.</p>
              <Button size="sm" variant="outline" className="mt-3" onClick={retry}>
                Tentar novamente
              </Button>
            </div>
          ) : rows.length === 0 ? (
            <div className="rounded-xl border border-white/5 px-4 py-10 text-center text-sm text-muted-foreground">
              Nenhum imóvel foi retornado pela API para estes filtros.
            </div>
          ) : (
            rows.map((property) => (
              <article
                key={property.id}
                className="rounded-xl border border-white/5 bg-white/[0.02] p-4"
              >
                <div className="flex min-w-0 items-start justify-between gap-3">
                  <div className="min-w-0">
                    <h3 className="break-words font-medium text-foreground">{property.title}</h3>
                    <p className="mt-1 break-all font-mono text-[10px] text-muted-foreground">
                      DF: {property.dfimoveisCode || "—"} · W: {property.wimoveisCode || "—"}
                    </p>
                    {propertyExclusivityLabel(property) !== "Não informado" && (
                      <p className="mt-1 text-[10px] font-medium text-amber-200">
                        {propertyExclusivityLabel(property)}
                      </p>
                    )}
                  </div>
                  <div className="flex shrink-0 flex-col items-end gap-1">
                    <span className="rounded-full bg-copper/10 px-2 py-1 text-[10px] text-copper">
                      {property.status ?? "—"}
                    </span>
                  </div>
                </div>

                <div className="mt-3 flex flex-wrap gap-2">
                  <span
                    className={`rounded-full px-2 py-1 text-[10px] font-medium ${property.hasPhotos ? "bg-emerald-300/10 text-emerald-300" : "bg-white/[0.05] text-muted-foreground"}`}
                  >
                    Fotos: {property.hasPhotos ? "Sim" : "Não"}
                  </span>
                  {property.purpose && (
                    <span className="rounded-full border border-white/10 px-2 py-1 text-[10px] text-muted-foreground">
                      {property.purpose}
                    </span>
                  )}
                  <span className="rounded-full border border-red-400/20 bg-red-400/10 px-2 py-1 text-[10px] text-red-200">
                    {property.leadCount} {property.leadCount === 1 ? "lead" : "leads"}
                  </span>
                </div>

                <dl className="mt-4 grid grid-cols-2 gap-x-3 gap-y-3 text-xs">
                  <MobilePropertyDetail label="Endereço" value={property.address ?? "—"} wide />
                  <MobilePropertyDetail label="Bairro" value={property.neighborhood ?? "—"} />
                  <MobilePropertyDetail label="Cidade" value={property.city ?? "—"} />
                  <MobilePropertyDetail label="Tipo" value={property.type ?? "—"} />
                  <MobilePropertyDetail
                    label="Valor"
                    value={
                      property.value
                        ? property.value.toLocaleString("pt-BR", {
                            style: "currency",
                            currency: "BRL",
                            maximumFractionDigits: 0,
                          })
                        : "—"
                    }
                  />
                  {canManageBrokerAssignments && (
                    <MobilePropertyDetail
                      label="Corretor"
                      value={displayBrokerName(property.broker) || "—"}
                    />
                  )}
                  <div className="col-span-2">
                    <span className="mb-1 block text-[10px] uppercase tracking-wider text-muted-foreground">
                      Captadores
                    </span>
                    {canManageBrokerAssignments ? (
                      <PropertyCapturerSelect
                        propertyId={property.id}
                        value={propertyCapturers[property.id]}
                        brokers={propertyParticipants}
                        onChanged={(brokerIds) =>
                          setPropertyCapturers((current) => ({
                            ...current,
                            [property.id]: brokerIds,
                          }))
                        }
                      />
                    ) : (
                      <span className="text-xs text-foreground">{capturerNames(property.id)}</span>
                    )}
                  </div>
                  <MobilePropertyDetail label="Proprietário" value={property.owner ?? "—"} />
                </dl>

                <div className="mt-4 flex flex-wrap gap-2 border-t border-white/5 pt-3">
                  {property.publicUrl && (
                    <Button asChild size="sm" variant="outline">
                      <a href={property.publicUrl} target="_blank" rel="noopener noreferrer">
                        <ExternalLink size={14} /> Ver imóvel
                      </a>
                    </Button>
                  )}
                  <PropertyCreateDialog
                    isAdmin={allysonAdmin}
                    brokerName={profile?.fullName}
                    brokers={brokerNames}
                    capturerProfiles={propertyParticipants}
                    capturerIds={propertyCapturers[property.id] ?? []}
                    property={property}
                    existingProperties={allProperties}
                    draftOwner={session?.user.id}
                    draftScope="mobile"
                    onCreated={refreshProperties}
                    canEditExisting={canEditPropertyCaptureSheet(property)}
                    canSetReviewability={allysonAdmin}
                    canEditPortalCodes={canEditPortalCodes}
                    canManageBrokerAssignments={canManageBrokerAssignments}
                    isSoniaLimaAccount={allysonAdmin}
                  />
                  {allysonAdmin && (
                    <PropertyBrokerAssignmentDialog
                      property={property}
                      brokers={brokerNames}
                      onUpdated={refreshProperties}
                    />
                  )}
                  {canDeleteProperties && (
                    <Button
                      size="sm"
                      variant="outline"
                      className="border-red-400/40 text-red-300 hover:bg-red-400/10"
                      onClick={() => {
                        setDeleteError("");
                        setDeletingProperty(property);
                      }}
                    >
                      <Trash2 size={14} /> Excluir
                    </Button>
                  )}
                </div>
              </article>
            ))
          )}
        </div>
        <div
          ref={tableScrollRef}
          onScroll={() => syncHorizontalScroll("table")}
          onPointerDown={beginTableDrag}
          onPointerMove={moveTableDrag}
          onPointerUp={endTableDrag}
          onPointerCancel={endTableDrag}
          className="hidden cursor-grab select-none overflow-x-auto rounded-xl border border-white/5 active:cursor-grabbing lg:block [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
        >
          <table className="w-full min-w-[1150px] text-sm">
            <thead>
              <tr className="bg-white/[0.02] text-left text-[10px] uppercase tracking-wider text-muted-foreground">
                {[
                  "Código DF",
                  "Código W",
                  "Foto",
                  "Título",
                  "Exclusividade",
                  "Endereço",
                  "Bairro",
                  "Cidade",
                  "Tipo",
                  "Finalidade",
                  "Valor",
                  "Leads",
                  ...(canManageBrokerAssignments ? ["Corretor"] : []),
                  "Captadores",
                  "Proprietário",
                  "Status",
                  "",
                ].map((item) => (
                  <th key={item} className="px-4 py-3 font-medium">
                    {item}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <Skeleton />
              ) : error ? (
                <tr>
                  <td
                    colSpan={canManageBrokerAssignments ? 16 : 15}
                    className="px-4 py-12 text-center"
                  >
                    <p className="text-sm text-muted-foreground">
                      Não foi possível carregar os imóveis.
                    </p>
                    <Button size="sm" variant="outline" className="mt-3" onClick={retry}>
                      Tentar novamente
                    </Button>
                  </td>
                </tr>
              ) : rows.length === 0 ? (
                <tr>
                  <td
                    colSpan={canManageBrokerAssignments ? 16 : 15}
                    className="px-4 py-12 text-center text-sm text-muted-foreground"
                  >
                    Nenhum imóvel foi retornado pela API para estes filtros.
                  </td>
                </tr>
              ) : (
                rows.map((property) => (
                  <tr key={property.id} className="border-t border-white/5 hover:bg-white/[0.025]">
                    <td className="px-4 py-3 font-mono text-xs text-muted-foreground">
                      {property.dfimoveisCode || "—"}
                    </td>
                    <td className="px-4 py-3 font-mono text-xs text-muted-foreground">
                      {property.wimoveisCode || "—"}
                    </td>
                    <td className="px-4 py-3">
                      <span
                        className={`rounded-full px-2 py-1 text-[10px] font-medium ${property.hasPhotos ? "bg-emerald-300/10 text-emerald-300" : "bg-white/[0.05] text-muted-foreground"}`}
                      >
                        {property.hasPhotos ? "Sim" : "Não"}
                      </span>
                    </td>
                    <td className="px-4 py-3 font-medium">{property.title}</td>
                    <td className="px-4 py-3 text-xs font-medium text-amber-200 whitespace-nowrap">
                      {propertyExclusivityLabel(property)}
                    </td>
                    <td className="px-4 py-3 text-muted-foreground">{property.address ?? "—"}</td>
                    <td className="px-4 py-3 text-muted-foreground">
                      {property.neighborhood ?? "—"}
                    </td>
                    <td className="px-4 py-3 text-muted-foreground">{property.city ?? "—"}</td>
                    <td className="px-4 py-3 text-muted-foreground">{property.type ?? "—"}</td>
                    <td className="px-4 py-3 text-muted-foreground">{property.purpose ?? "—"}</td>
                    <td className="px-4 py-3">
                      {property.value
                        ? property.value.toLocaleString("pt-BR", {
                            style: "currency",
                            currency: "BRL",
                            maximumFractionDigits: 0,
                          })
                        : "—"}
                    </td>
                    <td className="px-4 py-3">
                      <span className="rounded-full border border-red-400/20 bg-red-400/10 px-2 py-1 text-xs text-red-200">
                        {property.leadCount}
                      </span>
                    </td>
                    {canManageBrokerAssignments && (
                      <td className="px-4 py-3 text-muted-foreground">
                        {displayBrokerName(property.broker) || "—"}
                      </td>
                    )}
                    <td className="px-4 py-3">
                      {canManageBrokerAssignments ? (
                        <PropertyCapturerSelect
                          propertyId={property.id}
                          value={propertyCapturers[property.id]}
                        brokers={propertyParticipants}
                          onChanged={(brokerIds) =>
                            setPropertyCapturers((current) => ({
                              ...current,
                              [property.id]: brokerIds,
                            }))
                          }
                        />
                      ) : (
                        <span className="text-xs text-muted-foreground">
                          {capturerNames(property.id)}
                        </span>
                      )}
                    </td>
                    <td className="px-4 py-3 text-muted-foreground">{property.owner ?? "—"}</td>
                    <td className="px-4 py-3">
                      <div className="flex flex-col items-start gap-1">
                        <span className="rounded-full bg-copper/10 px-2 py-1 text-[10px] text-copper">
                          {property.status ?? "—"}
                        </span>
                      </div>
                    </td>
                    <td className="px-4 py-3 text-right">
                      <div className="flex items-center justify-end gap-1">
                        {property.publicUrl && (
                          <Button asChild size="sm" variant="ghost">
                            <a href={property.publicUrl} target="_blank" rel="noopener noreferrer">
                              <ExternalLink size={14} /> Ver imóvel
                            </a>
                          </Button>
                        )}
                        <PropertyCreateDialog
                          isAdmin={allysonAdmin}
                          brokerName={profile?.fullName}
                          brokers={brokerNames}
                          capturerProfiles={propertyParticipants}
                          capturerIds={propertyCapturers[property.id] ?? []}
                          property={property}
                          existingProperties={allProperties}
                          draftOwner={session?.user.id}
                          draftScope="desktop"
                          isSoniaLimaAccount={allysonAdmin}
                          onCreated={refreshProperties}
                          canEditExisting={canEditPropertyCaptureSheet(property)}
                          canSetReviewability={allysonAdmin}
                          canEditPortalCodes={canEditPortalCodes}
                          canManageBrokerAssignments={canManageBrokerAssignments}
                        />
                        {allysonAdmin && (
                          <PropertyBrokerAssignmentDialog
                            property={property}
                            brokers={brokerNames}
                            onUpdated={refreshProperties}
                          />
                        )}
                        {canDeleteProperties && (
                          <Button
                            size="sm"
                            variant="ghost"
                            className="text-red-300 hover:bg-red-400/10 hover:text-red-200"
                            title={`Excluir ${property.title}`}
                            onClick={() => {
                              setDeleteError("");
                              setDeletingProperty(property);
                            }}
                          >
                            <Trash2 size={14} /> Excluir
                          </Button>
                        )}
                      </div>
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
        {tableScrollWidth > tableClientWidth && (
          <div
            ref={fixedScrollRef}
            onScroll={() => syncHorizontalScroll("fixed")}
            aria-label="Rolagem horizontal da tabela de imóveis"
            className="fixed bottom-0 left-[264px] right-0 z-40 hidden h-5 overflow-x-auto border-t border-white/10 bg-background/95 backdrop-blur lg:block"
          >
            <div style={{ width: tableScrollWidth, height: 1 }} />
          </div>
        )}
        <div className="mt-4 flex justify-end gap-2 text-xs">
          <Button size="sm" variant="ghost" disabled={page === 1} onClick={() => setPage(page - 1)}>
            Anterior
          </Button>
          <span className="px-2 py-2 text-muted-foreground">
            Página {page} de {pages}
          </span>
          <Button
            size="sm"
            variant="ghost"
            disabled={page === pages}
            onClick={() => setPage(page + 1)}
          >
            Próxima
          </Button>
        </div>
      </Panel>
      <PropertyValueReviewDialog
        property={reviewingProperty}
        canRespond={Boolean(restrictedAdmin && reviewingProperty?.reviewable)}
        notificationTitle={notificationContext.title}
        notificationBody={notificationContext.body}
        reviewRequestId={notificationContext.requestId || undefined}
        onClose={closePropertyReview}
        onSaved={() => {
          closePropertyReview();
          refreshProperties();
        }}
      />
      <Dialog
        open={Boolean(deletingProperty)}
        onOpenChange={(open) => {
          if (!open && !deleting) {
            setDeletingProperty(undefined);
            setDeleteError("");
          }
        }}
      >
        <DialogContent className="glass-strong border-white/10 text-foreground sm:max-w-md">
          <DialogHeader>
            <DialogTitle>Excluir imóvel</DialogTitle>
            <DialogDescription>
              Esta ação excluirá “{deletingProperty?.title}” e seus dados vinculados. Não pode ser
              desfeita.
            </DialogDescription>
          </DialogHeader>
          {deleteError ? (
            <p role="alert" className="text-sm text-red-300">
              {deleteError}
            </p>
          ) : null}
          <div className="flex justify-end gap-2">
            <Button
              variant="outline"
              disabled={deleting}
              onClick={() => setDeletingProperty(undefined)}
            >
              Cancelar
            </Button>
            <Button
              className="bg-red-600 text-white hover:bg-red-500"
              disabled={deleting}
              onClick={() => void removeProperty()}
            >
              {deleting ? <Loader2 size={14} className="animate-spin" /> : <Trash2 size={14} />}
              Excluir imóvel
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </>
  );
}
function MobilePropertyDetail({
  label,
  value,
  wide = false,
}: {
  label: string;
  value: string;
  wide?: boolean;
}) {
  return (
    <div className={`min-w-0 ${wide ? "col-span-2" : ""}`}>
      <dt className="text-[10px] uppercase tracking-wider text-muted-foreground">{label}</dt>
      <dd className="mt-1 break-words font-medium text-foreground">{value}</dd>
    </div>
  );
}
function Skeleton() {
  return (
    <>
      {Array.from({ length: 7 }).map((_, row) => (
        <tr key={row} className="border-t border-white/5">
          {Array.from({ length: 13 }).map((__, cell) => (
            <td key={cell} className="px-4 py-4">
              <div className="skeleton h-4 w-full" />
            </td>
          ))}
        </tr>
      ))}
    </>
  );
}

import { Loader2, Pencil, Plus } from "lucide-react";
import { useEffect, useMemo, useState, type ReactNode } from "react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  findMatchingPropertyId,
  saveProperty,
  savePropertyAuthorization,
  completePropertyRegistration,
  fetchPropertyAuthorization,
  submitPropertyAuthorizationPhase1,
  createPropertyExternalId,
  setSoniaLimaPropertyExclusivity,
  type Property,
  type PropertyInput,
  type PropertyAuthorizationInput,
} from "@/lib/properties";
import { supabase } from "@/lib/supabase";
import { displayBrokerName } from "@/lib/broker-names";
import type { AccessProfile } from "@/lib/lead-access";
import {
  PropertyAuthorizationForm,
  initialAuthForm,
  type AuthFormState,
} from "./PropertyAuthorizationForm";

const propertyTypes = [
  "Apartamento",
  "Casa",
  "Casa em condomínio",
  "Cobertura",
  "Terreno",
  "Sala comercial",
  "Loja",
  "Galpão",
  "Chácara/Sítio",
  "Outro",
];
const purposes = ["Venda", "Locação", "Venda e locação"];
const statuses = ["Ativo", "Reservado", "Em negociação", "Vendido", "Alugado", "Inativo"];

type FormState = {
  title: string;
  neighborhood: string;
  city: string;
  type: string;
  bedrooms: string;
  purpose: string;
  value: string;
  broker: string;
  owner: string;
  status: string;
  hasPhotos: boolean;
  publicUrl: string;
  reviewable: boolean;
};

type PortalReferences = {
  wimoveis: string;
  dfimoveis: string;
};

const initialForm = (broker: string, property?: Property): FormState => ({
  title: property?.title ?? "",
  neighborhood: property?.neighborhood ?? "",
  city: property?.city ?? "",
  type: property?.type ?? "Apartamento",
  bedrooms: property?.bedrooms?.toString() ?? "",
  purpose: property?.purpose ?? "Venda",
  value: property?.value ? property.value.toLocaleString("pt-BR") : "",
  broker: property?.broker ?? broker,
  owner: property?.owner ?? "",
  status: property?.status ?? "Ativo",
  hasPhotos: property?.hasPhotos ?? false,
  publicUrl: property?.publicUrl ?? "",
  reviewable: property?.reviewable ?? false,
});

const initialPortalReferences = (property?: Property): PortalReferences => ({
  wimoveis: property?.wimoveisCode ?? "",
  dfimoveis: property?.dfimoveisCode ?? "",
});

const DRAFT_KEY = "sonialima-crm:property-create-draft";

export function PropertyCreateDialog({
  isAdmin,
  brokerName,
  brokers,
  capturerProfiles = [],
  capturerIds = [],
  onCreated,
  property,
  existingProperties = [],
  draftOwner,
  draftScope,
  canEditExisting = true,
  canSetReviewability = true,
  canEditPortalCodes = false,
  canManageBrokerAssignments = false,
  isSoniaLimaAccount = false,
}: {
  isAdmin: boolean;
  brokerName?: string;
  brokers: string[];
  capturerProfiles?: AccessProfile[];
  capturerIds?: string[];
  onCreated: () => void;
  property?: Property;
  existingProperties?: Property[];
  draftOwner?: string;
  draftScope?: string;
  canEditExisting?: boolean;
  canSetReviewability?: boolean;
  canEditPortalCodes?: boolean;
  canManageBrokerAssignments?: boolean;
  isSoniaLimaAccount?: boolean;
}) {
  const editing = Boolean(property);
  // Se for edição, readOnly é true caso não seja admin OU caso não possa editar existentes (ex: AcessoCRM).
  const readOnly = editing && !canEditExisting;

  const isPending = property?.registrationPhase === "PENDING";

  // SoniaLima é a conta institucional acessocrm. Usar sempre seu UUID evita
  // opções duplicadas e mantém criação e edição no mesmo caminho de validação.
  const sonialimaCapturerId = useMemo(
    () =>
      capturerProfiles.find(
        (profile) => profile.email.trim().toLowerCase() === "unassigned-institutional@example.invalid",
      )?.id,
    [capturerProfiles],
  );
  const capturerOptions = useMemo(() => {
    const uniqueProfiles = new Map<string, AccessProfile>();
    for (const profile of capturerProfiles) uniqueProfiles.set(profile.id, profile);
    return [...uniqueProfiles.values()].sort((left, right) => {
      const leftIsSoniaLima = left.id === sonialimaCapturerId;
      const rightIsSoniaLima = right.id === sonialimaCapturerId;
      if (leftIsSoniaLima !== rightIsSoniaLima) return leftIsSoniaLima ? -1 : 1;
      return (displayBrokerName(left.fullName) || left.email).localeCompare(
        displayBrokerName(right.fullName) || right.email,
        "pt-BR",
      );
    });
  }, [capturerProfiles, sonialimaCapturerId]);
  const normalizeCapturerId = (capturerId?: string) =>
    capturerId === "__sonialima__" ? (sonialimaCapturerId ?? "") : (capturerId ?? "");

  const firstCapturerId = normalizeCapturerId(capturerIds[0]);
  const secondCapturerId = normalizeCapturerId(capturerIds[1]);
  const draftContext = property?.id ? `edit:${property.id}` : "create";
  const draftKey = [DRAFT_KEY, draftOwner || "anonymous", draftContext, draftScope]
    .filter(Boolean)
    .join(":");

  const [open, setOpen] = useState(false);
  const [activeTab, setActiveTab] = useState<"admin" | "auth">("admin");
  const [loadingAuth, setLoadingAuth] = useState(false);

  const [form, setForm] = useState<FormState>(() =>
    initialForm(isAdmin ? "" : (brokerName ?? ""), property),
  );
  const [authForm, setAuthForm] = useState<AuthFormState>(initialAuthForm);
  const [sonialimaExclusivity, setSoniaLimaExclusivity] = useState<
    "COM EXCLUSIVIDADE" | "SEM EXCLUSIVIDADE" | "SEM AUTORIZACAO DE VENDA" | undefined
  >(property?.sonialimaExclusivityControl);
  const [originalDocumentFiles, setOriginalDocumentFiles] = useState<File[]>([]);
  const [originalDocumentsList, setOriginalDocumentsList] = useState<
    { name: string; url: string }[]
  >([]);
  const [loadingOriginals, setLoadingOriginals] = useState(false);
  const [hasAuthorization, setHasAuthorization] = useState(false);
  const [createdPropertyId, setCreatedPropertyId] = useState<string | null>(null);

  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [draftRestored, setDraftRestored] = useState(false);
  const [restoredFromDraft, setRestoredFromDraft] = useState(false);
  const [selectedBrokers, setSelectedBrokers] = useState<string[]>(() =>
    (property?.broker ?? (isAdmin ? "" : (brokerName ?? "")))
      .split(",")
      .map((broker) => broker.trim())
      .filter(Boolean),
  );
  const [selectedCapturers, setSelectedCapturers] = useState<string[]>(() => [
    firstCapturerId,
    secondCapturerId,
  ]);
  const [portalReferences, setPortalReferences] = useState<PortalReferences>(() =>
    initialPortalReferences(property),
  );

  useEffect(() => {
    if (!sonialimaCapturerId) return;
    setSelectedCapturers((current) =>
      current.map((capturerId) =>
        capturerId === "__sonialima__" ? sonialimaCapturerId : capturerId,
      ),
    );
  }, [sonialimaCapturerId]);

  useEffect(() => {
    if (typeof window === "undefined") {
      setDraftRestored(true);
      return;
    }
    try {
      const draft = sessionStorage.getItem(draftKey);
      if (draft) {
        const saved = JSON.parse(draft) as {
          open?: boolean;
          form?: FormState;
          authForm?: AuthFormState;
          selectedBrokers?: string[];
          selectedCapturers?: string[];
          portalReferences?: PortalReferences;
          createdPropertyId?: string | null;
        };
        if (saved.open && saved.form) {
          setForm({ ...initialForm(isAdmin ? "" : (brokerName ?? ""), property), ...saved.form });
          if (saved.authForm) setAuthForm(saved.authForm);
          if (Array.isArray(saved.selectedBrokers)) setSelectedBrokers(saved.selectedBrokers);
          if (Array.isArray(saved.selectedCapturers)) {
            setSelectedCapturers([
              saved.selectedCapturers[0] ?? "",
              saved.selectedCapturers[1] ?? "",
            ]);
          }
          if (saved.portalReferences) setPortalReferences(saved.portalReferences);
          if (saved.createdPropertyId) setCreatedPropertyId(saved.createdPropertyId);
          setRestoredFromDraft(true);
          setOpen(true);
        }
      }
    } catch {
      sessionStorage.removeItem(draftKey);
    } finally {
      setDraftRestored(true);
    }
  }, [draftKey]);

  useEffect(() => {
    if (draftRestored && !open) {
      setForm(initialForm(isAdmin ? "" : (brokerName ?? ""), property));
      setAuthForm(initialAuthForm());
      setHasAuthorization(false);
      setCreatedPropertyId(null);
      setSelectedBrokers(
        (property?.broker ?? (isAdmin ? "" : (brokerName ?? "")))
          .split(",")
          .map((broker) => broker.trim())
          .filter(Boolean),
      );
      setSelectedCapturers([firstCapturerId, secondCapturerId]);
      setPortalReferences(initialPortalReferences(property));
      setError("");
      setRestoredFromDraft(false);
      // A ficha de captação foi removida: mantenha o formulário administrativo
      // visível ao abrir ou editar um imóvel.
      setActiveTab("admin");
    }
  }, [open, isAdmin, brokerName, property, draftRestored, firstCapturerId, secondCapturerId]);

  useEffect(() => {
    if (!open || !property?.id) return;
    let active = true;

    if (!restoredFromDraft) {
      void supabase
        .from("crm_property_portal_references")
        .select("portal, external_listing_id")
        .eq("property_id", property.id)
        .then(({ data }) => {
          if (!active) return;
          setPortalReferences({
            wimoveis:
              data?.find((item) => item.portal === "wimoveis")?.external_listing_id ??
              property.wimoveisCode ??
              "",
            dfimoveis:
              data?.find((item) => item.portal === "dfimoveis")?.external_listing_id ??
              property.dfimoveisCode ??
              "",
          });
        });
    }

    setLoadingAuth(true);
    fetchPropertyAuthorization(property.id).then((authData) => {
      if (!active) return;
      if (authData) setHasAuthorization(true);
      if (authData && !restoredFromDraft) {
        setAuthForm({
          saldoDevedor:
            authData.saldoDevedor !== null && authData.saldoDevedor !== undefined
              ? authData.saldoDevedor.toLocaleString("pt-BR")
              : "",
          valorPrestacao:
            authData.valorPrestacao !== null && authData.valorPrestacao !== undefined
              ? authData.valorPrestacao.toLocaleString("pt-BR")
              : "",
          agenteFinanceiro: authData.agenteFinanceiro ?? "",
          metragem:
            authData.metragem !== null && authData.metragem !== undefined
              ? authData.metragem.toString()
              : "",
          valorPretendido:
            authData.valorPretendido !== null && authData.valorPretendido !== undefined
              ? authData.valorPretendido.toLocaleString("pt-BR")
              : "",
          valorAvaliacao:
            authData.valorAvaliacao !== null && authData.valorAvaliacao !== undefined
              ? authData.valorAvaliacao.toLocaleString("pt-BR")
              : "",
          iptu:
            authData.iptu !== null && authData.iptu !== undefined
              ? authData.iptu.toLocaleString("pt-BR")
              : "",
          numeroInscricao: authData.numeroInscricao ?? "",
          vagasGaragem:
            authData.vagasGaragem !== null && authData.vagasGaragem !== undefined
              ? authData.vagasGaragem.toString()
              : "",
          administradoraCondominio: authData.administradoraCondominio ?? "",
          telefoneCondominio: authData.telefoneCondominio ?? "",
          valorCondominio:
            authData.valorCondominio !== null && authData.valorCondominio !== undefined
              ? authData.valorCondominio.toLocaleString("pt-BR")
              : "",
          prop1Nome: authData.prop1Nome,
          prop1Profissao: authData.prop1Profissao,
          prop1EstadoCivil: authData.prop1EstadoCivil,
          prop1Cpf: authData.prop1Cpf,
          prop1CnhRg: authData.prop1CnhRg,
          prop1OrgaoExpedidor: authData.prop1OrgaoExpedidor ?? "",
          prop1Uf: authData.prop1Uf ?? "",
          prop1Nacionalidade: authData.prop1Nacionalidade,
          prop1Telefone: authData.prop1Telefone,
          prop1Email: authData.prop1Email,
          prop2Nome: authData.prop2Nome ?? "",
          prop2Profissao: authData.prop2Profissao ?? "",
          prop2EstadoCivil: authData.prop2EstadoCivil ?? "",
          prop2Cpf: authData.prop2Cpf ?? "",
          prop2CnhRg: authData.prop2CnhRg ?? "",
          prop2OrgaoExpedidor: authData.prop2OrgaoExpedidor ?? "",
          prop2Uf: authData.prop2Uf ?? "",
          prop2Nacionalidade: authData.prop2Nacionalidade ?? "",
          prop2Telefone: authData.prop2Telefone ?? "",
          prop2Email: authData.prop2Email ?? "",
          modalidade: authData.modalidade,
          observacoesCliente: authData.observacoesCliente,
          prazoClausula2: authData.prazoClausula2,
          honorariosClausula4Pct: authData.honorariosClausula4Pct?.toString() ?? "",
          regularizacaoStatus: authData.regularizacaoStatus,
          escrituraStatus: authData.escrituraStatus,
          observacoesProprietario: authData.observacoesProprietario ?? "",
          informacoesRelevantes: authData.informacoesRelevantes ?? "",
        });
      }
      setLoadingAuth(false);
    });

    setLoadingOriginals(true);
    supabase.storage
      .from("property-authorizations")
      .list(property.id, { search: "original_" })
      .then(async ({ data: files }) => {
        if (!active) return;
        if (files && files.length > 0) {
          const urls = await Promise.all(
            files.map(async (f) => {
              const { data: urlData } = await supabase.storage
                .from("property-authorizations")
                .createSignedUrl(`${property.id}/${f.name}`, 3600);
              return { name: f.name, url: urlData?.signedUrl ?? "" };
            }),
          );
          setOriginalDocumentsList(urls.filter((u) => u.url));
        } else {
          setOriginalDocumentsList([]);
        }
        setLoadingOriginals(false);
      });

    return () => {
      active = false;
    };
  }, [open, property?.id, property?.wimoveisCode, property?.dfimoveisCode, restoredFromDraft]);

  useEffect(() => {
    if (!draftRestored || typeof window === "undefined") return;
    if (!open) {
      sessionStorage.removeItem(draftKey);
      return;
    }
    sessionStorage.setItem(
      draftKey,
      JSON.stringify({
        open,
        form,
        authForm,
        selectedBrokers,
        selectedCapturers,
        portalReferences,
        createdPropertyId,
      }),
    );
  }, [
    open,
    form,
    authForm,
    selectedBrokers,
    selectedCapturers,
    portalReferences,
    createdPropertyId,
    draftRestored,
    draftKey,
  ]);

  const updateForm = <K extends keyof FormState>(key: K, value: FormState[K]) =>
    setForm((current) => ({ ...current, [key]: value }));

  const updateAuth = <K extends keyof AuthFormState>(key: K, value: AuthFormState[K]) =>
    setAuthForm((current) => ({ ...current, [key]: value }));

  const submit = async (event: React.FormEvent) => {
    event.preventDefault();
    if (readOnly) return;

    setSaving(true);
    setError("");
    try {
      const duplicatePortal = canEditPortalCodes
        ? (
            [
              ["W Imóveis", "wimoveisCode", portalReferences.wimoveis],
              ["DF Imóveis", "dfimoveisCode", portalReferences.dfimoveis],
            ] as const
          ).find(([, propertyKey, code]) => {
            const normalizedPortalCode = code.trim().toLocaleLowerCase("pt-BR");
            return (
              normalizedPortalCode &&
              existingProperties.some(
                (candidate) =>
                  candidate.id !== property?.id &&
                  candidate[propertyKey]?.trim().toLocaleLowerCase("pt-BR") ===
                    normalizedPortalCode,
              )
            );
          })
        : undefined;
      if (duplicatePortal) {
        setError(
          `Já existe um imóvel com o código ${duplicatePortal[2].trim()} na ${duplicatePortal[0]}.`,
        );
        return;
      }
      const bedroomsText = form.bedrooms.trim();
      const bedrooms = bedroomsText === "" ? null : Number(bedroomsText);
      if (
        bedrooms !== null &&
        (!/^\d+$/.test(bedroomsText) || !Number.isInteger(bedrooms) || bedrooms > 2147483647)
      ) {
        setError("Informe um número inteiro de quartos, igual ou maior que zero.");
        return;
      }
      const input: PropertyInput = {
        wimoveisCode: canEditPortalCodes
          ? portalReferences.wimoveis.trim()
          : property?.wimoveisCode,
        dfimoveisCode: canEditPortalCodes
          ? portalReferences.dfimoveis.trim()
          : property?.dfimoveisCode,
        title: form.title.trim(),
        neighborhood: form.neighborhood.trim() || undefined,
        city: form.city.trim() || undefined,
        type: form.type,
        bedrooms,
        purpose: form.purpose,
        value: form.value ? Number(form.value.replace(/\D/g, "")) : undefined,
        broker:
          (canManageBrokerAssignments ? selectedBrokers.join(", ") : form.broker).trim() ||
          undefined,
        owner: form.owner.trim() || undefined,
        status: form.status,
        hasPhotos: form.hasPhotos,
      };

      const authInput: PropertyAuthorizationInput = {
        saldoDevedor: authForm.saldoDevedor
          ? Number(authForm.saldoDevedor.replace(/\D/g, ""))
          : undefined,
        valorPrestacao: authForm.valorPrestacao
          ? Number(authForm.valorPrestacao.replace(/\D/g, ""))
          : undefined,
        agenteFinanceiro: authForm.agenteFinanceiro,
        metragem: authForm.metragem ? Number(authForm.metragem) : undefined,
        valorPretendido: authForm.valorPretendido
          ? Number(authForm.valorPretendido.replace(/\D/g, ""))
          : undefined,
        valorAvaliacao: authForm.valorAvaliacao
          ? Number(authForm.valorAvaliacao.replace(/\D/g, ""))
          : undefined,
        iptu: authForm.iptu
          ? Number(authForm.iptu.replace(/[^\d,-]/g, "").replace(",", "."))
          : undefined,
        numeroInscricao: authForm.numeroInscricao,
        vagasGaragem: authForm.vagasGaragem ? Number(authForm.vagasGaragem) : undefined,
        administradoraCondominio: authForm.administradoraCondominio,
        telefoneCondominio: authForm.telefoneCondominio,
        valorCondominio: authForm.valorCondominio
          ? Number(authForm.valorCondominio.replace(/\D/g, ""))
          : undefined,
        prop1Nome: authForm.prop1Nome,
        prop1Profissao: authForm.prop1Profissao,
        prop1EstadoCivil: authForm.prop1EstadoCivil,
        prop1Cpf: authForm.prop1Cpf,
        prop1CnhRg: authForm.prop1CnhRg,
        prop1OrgaoExpedidor: authForm.prop1OrgaoExpedidor,
        prop1Uf: authForm.prop1Uf,
        prop1Nacionalidade: authForm.prop1Nacionalidade,
        prop1Telefone: authForm.prop1Telefone,
        prop1Email: authForm.prop1Email,
        prop2Nome: authForm.prop2Nome,
        prop2Profissao: authForm.prop2Profissao,
        prop2EstadoCivil: authForm.prop2EstadoCivil,
        prop2Cpf: authForm.prop2Cpf,
        prop2CnhRg: authForm.prop2CnhRg,
        prop2OrgaoExpedidor: authForm.prop2OrgaoExpedidor,
        prop2Uf: authForm.prop2Uf,
        prop2Nacionalidade: authForm.prop2Nacionalidade,
        prop2Telefone: authForm.prop2Telefone,
        prop2Email: authForm.prop2Email,
        modalidade: authForm.modalidade,
        observacoesCliente: authForm.observacoesCliente,
        prazoClausula2: authForm.prazoClausula2,
        honorariosClausula4Pct: authForm.honorariosClausula4Pct
          ? Number(authForm.honorariosClausula4Pct.replace(",", "."))
          : undefined,
        regularizacaoStatus: authForm.regularizacaoStatus,
        escrituraStatus: authForm.escrituraStatus,
        observacoesProprietario: authForm.observacoesProprietario,
        informacoesRelevantes: authForm.informacoesRelevantes,
      };

      if (
        isAdmin &&
        activeTab === "admin" &&
        canManageBrokerAssignments &&
        selectedBrokers.length === 0
      ) {
        setError("Selecione ao menos um corretor responsável.");
        setSaving(false);
        return;
      }
      if (
        activeTab === "auth" &&
        (!selectedCapturers[0] ||
          (selectedCapturers[1] && selectedCapturers[0] === selectedCapturers[1]))
      ) {
        // Remover obrigatoriedade no frontend
        // setSelectedCapturers pode ser vazio na Fase 1
      }
      if (
        isAdmin &&
        activeTab === "admin" &&
        canManageBrokerAssignments &&
        (!selectedCapturers[0] ||
          (selectedCapturers[1] && selectedCapturers[0] === selectedCapturers[1]))
      ) {
        setError("Selecione ao menos um captador. O segundo captador é opcional.");
        setSaving(false);
        return;
      }

      let propertyId = property?.id || createdPropertyId;
      const isNewSubmission = !propertyId;

      if (isNewSubmission) {
        const matchingPropertyId = await findMatchingPropertyId(input);
        if (matchingPropertyId) {
          // Um código de portal já existente representa o mesmo imóvel: atualiza-o.
          propertyId = matchingPropertyId;
          await saveProperty(input, propertyId);
        } else {
          // Sem imóvel correspondente, a operação deve ser INSERT. Passar um
          // código recém-gerado como `id` faria saveProperty tentar UPDATE e
          // retornaria o erro de coerção de objeto único do PostgREST.
          const savedProperty = await saveProperty(input);
          propertyId = savedProperty.id;
        }
        setCreatedPropertyId(propertyId);
      }

      if (!property?.id) {
        // Se for a submissão inicial (agora ou no retry), faz upload dos originais e fecha a fase.
        if (originalDocumentFiles.length > 0) {
          for (const file of originalDocumentFiles) {
            const fileExt = file.name.split(".").pop();
            const originalFileName = `${propertyId}/original_${Date.now()}_${Math.random().toString(36).substring(7)}.${fileExt}`;
            const { error: uploadOrigError } = await supabase.storage
              .from("property-authorizations")
              .upload(originalFileName, file, { upsert: false });
            if (uploadOrigError)
              throw new Error("Erro ao enviar documento original: " + uploadOrigError.message);
          }
        }
        // Finalizar sessão obrigatoriamente (mesmo com 0 arquivos)
      } else {
        // Fluxo para Atualizações e Edição Administrativa (Fase 2+ e imóveis antigos)
        await saveProperty(input, propertyId!);

        // Salva autorização SOMENTE se ela JÁ EXISTE (update). Imóvel legado sem autorização continua legável.
        if (hasAuthorization) {
          await savePropertyAuthorization(propertyId!, authInput);
        }

        // Para Administrador adicionar documentos em fase > PENDING (ou se a sessão ainda está aberta)
        if (originalDocumentFiles.length > 0) {
          for (const file of originalDocumentFiles) {
            const fileExt = file.name.split(".").pop();
            const originalFileName = `${propertyId}/original_${Date.now()}_${Math.random().toString(36).substring(7)}.${fileExt}`;
            const { error: uploadOrigError } = await supabase.storage
              .from("property-authorizations")
              .upload(originalFileName, file, { upsert: false });
            if (uploadOrigError)
              throw new Error("Erro ao enviar documento original: " + uploadOrigError.message);
          }
        }
      }

      if (!propertyId)
        throw new Error("O imóvel foi salvo, mas o registro criado não foi identificado.");

      // Ações administrativas da Fase 2. Corretores na Fase 1 não executam RPCs administrativas.
      if (isAdmin && activeTab === "admin") {
        if (canManageBrokerAssignments && propertyId) {
          const { error: accessError } = await supabase.rpc("sync_property_broker_access", {
            p_property_id: propertyId,
            p_broker_names: selectedBrokers,
          });
          if (accessError) throw new Error(accessError.message);

          const { error: capturerError } = await supabase.rpc("set_property_capturers", {
            p_property_id: propertyId,
            p_selections: selectedCapturers,
          });
          if (capturerError) throw new Error(capturerError.message);
        }

        if (canEditPortalCodes && propertyId) {
          const { error: portalError } = await supabase.rpc("sync_property_portal_references", {
            p_property_id: propertyId,
            p_wimoveis_listing_id: portalReferences.wimoveis,
            p_dfimoveis_listing_id: portalReferences.dfimoveis,
          });
          if (portalError) throw new Error(portalError.message);
        }

        const { error: publicLinkError } = await supabase.rpc("sync_property_public_link", {
          p_property_id: propertyId,
          p_url: form.publicUrl,
        });
        if (publicLinkError) throw new Error(publicLinkError.message);

        if (canSetReviewability) {
          const { error: reviewabilityError } = await supabase.rpc("set_property_reviewability", {
            p_property_id: propertyId,
            p_reviewable: form.reviewable,
          });
          if (reviewabilityError) throw new Error(reviewabilityError.message);
        }

        // O estado COMPLETED só é aplicado depois que todas as etapas administrativas anteriores terminam com sucesso.
        if (isPending) {
          await completePropertyRegistration(propertyId);
        }
      }
      if (isSoniaLimaAccount && propertyId && sonialimaExclusivity) {
        await setSoniaLimaPropertyExclusivity(propertyId, sonialimaExclusivity);
      }
      onCreated();
      if (typeof window !== "undefined") sessionStorage.removeItem(draftKey);
      setOpen(false);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Não foi possível cadastrar o imóvel.");
    } finally {
      setSaving(false);
    }
  };

  if (editing && !canEditExisting && !readOnly) return null;

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      {editing ? (
        <Button
          variant="ghost"
          size="icon"
          aria-label={`Editar ${property?.title}`}
          onClick={() => setOpen(true)}
        >
          <Pencil size={15} />
        </Button>
      ) : (
        <Button className="bg-copper text-white hover:bg-copper/90" onClick={() => setOpen(true)}>
          <Plus size={16} /> Adicionar imóvel
        </Button>
      )}
      <DialogContent
        data-hide-mobile-refresh="true"
        className="glass-strong max-h-[calc(100dvh-2rem)] overflow-y-auto border-white/10 text-foreground sm:max-w-2xl"
      >
        <DialogHeader>
          <DialogTitle>
            {editing
              ? readOnly
                ? "Visualizar imóvel"
                : "Editar imóvel"
              : "Cadastrar Imóvel (Captação)"}
          </DialogTitle>
          <DialogDescription>
            {editing
              ? readOnly
                ? "Visualizar as informações do imóvel e autorização de venda."
                : "Atualize as informações do imóvel no portfólio."
              : "Preencha os dados primários da Captação e Autorização de Venda. Os campos administrativos serão preenchidos posteriormente."}
          </DialogDescription>
        </DialogHeader>


        {loadingAuth ? (
          <div className="flex justify-center p-8">
            <Loader2 className="animate-spin text-copper" />
          </div>
        ) : (
          <form onSubmit={submit} className="grid gap-4">
            <Field label="Número de quartos (opcional)">
              <input
                type="number"
                min={0}
                max={2147483647}
                step={1}
                inputMode="numeric"
                value={form.bedrooms}
                onChange={(event) => updateForm("bedrooms", event.target.value)}
                className={inputClass}
                placeholder="Não informado"
                disabled={readOnly}
              />
            </Field>
            {false && <div>
              <PropertyAuthorizationForm
                form={authForm}
                onChange={updateAuth}
                readOnly={readOnly}
                requireValidations={activeTab === "auth" && (!property?.id || hasAuthorization)}
              />

              <div className="mt-8 pt-6 border-t border-white/10">
                <label className="block text-xs text-muted-foreground mb-1.5">
                  Corretor Captador
                </label>
                <div className="space-y-2">
                  {[0].map((position) => (
                    <select
                      key={position}
                      value={selectedCapturers[position] ?? ""}
                      disabled={readOnly}
                      onChange={(event) => {
                        const selection = event.target.value;
                        setSelectedCapturers((current) => {
                          const updated = [current[0] ?? "", current[1] ?? ""];
                          updated[position] = selection;
                          return updated;
                        });
                      }}
                      className="w-full rounded-lg border border-white/10 bg-white/[0.03] px-3 py-2.5 text-sm text-foreground outline-none transition focus:border-copper/50 disabled:cursor-not-allowed disabled:opacity-70"
                      aria-label="Captador"
                    >
                      <option value="">Selecionar captador</option>
                      {capturerOptions.map((broker) => (
                        <option key={broker.id} value={broker.id}>
                          {displayBrokerName(broker.fullName) || broker.email}
                        </option>
                      ))}
                    </select>
                  ))}
                  <p className="text-[11px] text-muted-foreground">
                    O captador responsável por esta autorização de venda.
                  </p>
                </div>
                <div className="mt-6">
                  <label className="block text-xs font-medium text-copper mb-1.5">
                    Documento Original (Anexo)
                  </label>
                  <input
                    type="file"
                    multiple
                    accept="image/*,application/pdf"
                    disabled={readOnly}
                    onChange={(e) => {
                      const files = e.target.files;
                      if (files) setOriginalDocumentFiles(Array.from(files));
                    }}
                    className="block w-full text-sm text-muted-foreground file:mr-4 file:py-2 file:px-4 file:rounded file:border-0 file:text-sm file:font-medium file:bg-copper/20 file:text-copper hover:file:bg-copper/30 disabled:opacity-50 cursor-pointer"
                  />
                  <p className="mt-1 text-[11px] text-muted-foreground">
                    Anexe a foto ou scanner da Autorização de Venda física assinada pelo cliente.
                  </p>
                  {loadingOriginals && (
                    <div className="mt-3 text-xs text-muted-foreground flex items-center gap-2">
                      <Loader2 size={12} className="animate-spin" /> Carregando documentos...
                    </div>
                  )}
                  {originalDocumentsList.length > 0 && (
                    <div className="mt-4 p-3 rounded-md bg-white/[0.02] border border-white/5 space-y-2">
                      <p className="text-xs font-medium text-copper">
                        Documentos Anexados Anteriormente
                      </p>
                      <ul className="space-y-1">
                        {originalDocumentsList.map((doc) => (
                          <li key={doc.name} className="text-[13px]">
                            <a
                              href={doc.url}
                              target="_blank"
                              rel="noreferrer"
                              className="text-copper hover:underline inline-flex items-center gap-1.5"
                            >
                              📄 {doc.name.split("/").pop()}
                            </a>
                          </li>
                        ))}
                      </ul>
                    </div>
                  )}
                </div>
              </div>

              {!editing && (
                <div className="mt-8 pt-6 border-t border-white/10 grid gap-4 sm:grid-cols-2">
                  <h3 className="text-sm font-medium text-copper sm:col-span-2">
                    Informações Iniciais do Catálogo
                  </h3>
                  <Field
                    label="Endereço ou identificação (Título do Imóvel)"
                    className="sm:col-span-2"
                  >
                    <input
                      value={form.title}
                      onChange={(event) => updateForm("title", event.target.value)}
                      className={inputClass}
                      disabled={readOnly}
                    />
                  </Field>
                  <Field label="Bairro">
                    <input
                      value={form.neighborhood}
                      onChange={(event) => updateForm("neighborhood", event.target.value)}
                      className={inputClass}
                      disabled={readOnly}
                    />
                  </Field>
                  <Field label="Cidade">
                    <input
                      value={form.city}
                      onChange={(event) => updateForm("city", event.target.value)}
                      className={inputClass}
                      disabled={readOnly}
                    />
                  </Field>
                  <Field label="Tipo">
                    <Select
                      value={form.type}
                      onChange={(value) => updateForm("type", value)}
                      options={propertyTypes}
                      disabled={readOnly}
                    />
                  </Field>
                  <Field label="Finalidade">
                    <Select
                      value={form.purpose}
                      onChange={(value) => updateForm("purpose", value)}
                      options={purposes}
                      disabled={readOnly}
                    />
                  </Field>
                </div>
              )}
            </div>}

            <div className={activeTab === "admin" ? "block" : "hidden"}>
              <div className="grid gap-4 sm:grid-cols-2">
                <Field label="Endereço ou identificação" className="sm:col-span-2">
                  <input
                    value={form.title}
                    onChange={(event) => updateForm("title", event.target.value)}
                    className={inputClass}
                    disabled={readOnly}
                  />
                </Field>
                <Field label="Proprietário">
                  <input
                    value={form.owner}
                    onChange={(event) => updateForm("owner", event.target.value)}
                    className={inputClass}
                    disabled={readOnly}
                  />
                </Field>
                <Field label="Bairro">
                  <input
                    value={form.neighborhood}
                    onChange={(event) => updateForm("neighborhood", event.target.value)}
                    className={inputClass}
                    disabled={readOnly}
                  />
                </Field>
                <Field label="Cidade">
                  <input
                    value={form.city}
                    onChange={(event) => updateForm("city", event.target.value)}
                    className={inputClass}
                    disabled={readOnly}
                  />
                </Field>
                <Field label="Tipo">
                  <Select
                    value={form.type}
                    onChange={(value) => updateForm("type", value)}
                    options={propertyTypes}
                    disabled={readOnly}
                  />
                </Field>
                <Field label="Finalidade">
                  <Select
                    value={form.purpose}
                    onChange={(value) => updateForm("purpose", value)}
                    options={purposes}
                    disabled={readOnly}
                  />
                </Field>
                <Field label="Valor de venda">
                  <input
                    value={form.value}
                    onChange={(event) =>
                      updateForm(
                        "value",
                        event.target.value.replace(/\D/g, "").replace(/\B(?=(\d{3})+(?!\d))/g, "."),
                      )
                    }
                    className={inputClass}
                    inputMode="numeric"
                    placeholder="Ex.: 500.000"
                    disabled={readOnly}
                  />
                </Field>
                <Field label="Status">
                  <Select
                    value={form.status}
                    onChange={(value) => updateForm("status", value)}
                    options={statuses}
                    disabled={readOnly}
                  />
                </Field>
                <Field label="Link do imóvel (opcional)" className="sm:col-span-2">
                  <input
                    type="url"
                    value={form.publicUrl}
                    onChange={(event) => updateForm("publicUrl", event.target.value)}
                    className={inputClass}
                    placeholder="https://exemplo.com/imovel"
                    disabled={readOnly}
                  />
                </Field>
                {isSoniaLimaAccount && (
                  <div className="sm:col-span-2">
                    <p className="mb-1.5 text-xs text-copper">
                      Controle de Exclusividade (Uso interno Sônia Lima)
                    </p>
                    <div className="flex gap-2">
                      <button
                        type="button"
                        onClick={() => setSoniaLimaExclusivity(undefined)}
                        className={`flex-1 rounded-lg border px-3 py-2.5 text-sm font-medium transition ${!sonialimaExclusivity ? "bg-white/10 border-white/20 text-white" : "border-white/10 bg-white/[0.03] text-muted-foreground"}`}
                      >
                        Nenhum
                      </button>
                      <button
                        type="button"
                        onClick={() => setSoniaLimaExclusivity("COM EXCLUSIVIDADE")}
                        className={`flex-1 rounded-lg border px-3 py-2.5 text-sm font-medium transition ${sonialimaExclusivity === "COM EXCLUSIVIDADE" ? "bg-emerald-400/20 border-emerald-400/50 text-emerald-300" : "border-white/10 bg-white/[0.03] text-muted-foreground"}`}
                      >
                        Com exclusividade
                      </button>
                      <button
                        type="button"
                        onClick={() => setSoniaLimaExclusivity("SEM EXCLUSIVIDADE")}
                        className={`flex-1 rounded-lg border px-3 py-2.5 text-sm font-medium transition ${sonialimaExclusivity === "SEM EXCLUSIVIDADE" ? "bg-amber-400/20 border-amber-400/50 text-amber-300" : "border-white/10 bg-white/[0.03] text-muted-foreground"}`}
                      >
                        Sem exclusividade
                      </button>
                      <button
                        type="button"
                        onClick={() => setSoniaLimaExclusivity("SEM AUTORIZACAO DE VENDA")}
                        className={`flex-1 rounded-lg border px-3 py-2.5 text-sm font-medium transition ${sonialimaExclusivity === "SEM AUTORIZACAO DE VENDA" ? "bg-red-400/20 border-red-400/50 text-red-300" : "border-white/10 bg-white/[0.03] text-muted-foreground"}`}
                      >
                        Sem autorização
                      </button>
                    </div>
                    {isSoniaLimaAccount &&
                      editing &&
                      property?.id &&
                      sonialimaExclusivity !== property?.sonialimaExclusivityControl && (
                        <div className="mt-2 text-right">
                          <Button
                            type="button"
                            variant="outline"
                            size="sm"
                            onClick={async () => {
                              try {
                                setSaving(true);
                                await setSoniaLimaPropertyExclusivity(
                                  property.id,
                                  sonialimaExclusivity as
                                    | "COM EXCLUSIVIDADE"
                                    | "SEM EXCLUSIVIDADE"
                                    | "SEM AUTORIZACAO DE VENDA",
                                );
                                onCreated();
                              } catch (reason) {
                                setError(
                                  reason instanceof Error
                                    ? reason.message
                                    : "Erro ao salvar exclusividade.",
                                );
                              } finally {
                                setSaving(false);
                              }
                            }}
                            disabled={saving || !sonialimaExclusivity}
                          >
                            Salvar Controle Sônia Lima
                          </Button>
                        </div>
                      )}
                  </div>
                )}
                {canManageBrokerAssignments && (
                  <Field label="Corretor responsável" required>
                    <div className="max-h-36 space-y-1 overflow-y-auto rounded-lg border border-white/10 bg-white/[0.03] p-2">
                      {brokers.length ? (
                        brokers.map((broker) => {
                          const selected = selectedBrokers.includes(broker);
                          return (
                            <label
                              key={broker}
                              className={`flex items-center gap-2 rounded px-2 py-1.5 text-sm ${readOnly ? "cursor-not-allowed opacity-70" : "cursor-pointer hover:bg-white/[0.05]"}`}
                            >
                              <input
                                type="checkbox"
                                checked={selected}
                                disabled={readOnly}
                                onChange={() =>
                                  setSelectedBrokers((current) =>
                                    selected
                                      ? current.filter((name) => name !== broker)
                                      : [...current, broker],
                                  )
                                }
                                className="accent-copper"
                              />
                              {displayBrokerName(broker)}
                            </label>
                          );
                        })
                      ) : (
                        <span className="block px-2 py-1 text-sm text-muted-foreground">
                          Nenhum corretor cadastrado
                        </span>
                      )}
                    </div>
                  </Field>
                )}
                {canManageBrokerAssignments && (
                  <Field label="Captadores dos documentos" required>
                    <div className="space-y-2">
                      {[0, 1].map((position) => (
                        <select
                          key={position}
                          required={position === 0}
                          value={selectedCapturers[position] ?? ""}
                          disabled={readOnly}
                          onChange={(event) => {
                            const selection = event.target.value;
                            setSelectedCapturers((current) => {
                              const updated = [current[0] ?? "", current[1] ?? ""];
                              updated[position] = selection;
                              return updated;
                            });
                          }}
                          className={inputClass}
                          aria-label={`Captador obrigatório ${position + 1}`}
                        >
                          <option value="">
                            {position === 0 ? "Selecionar captador 1" : "Captador 2 (opcional)"}
                          </option>
                          {capturerOptions.map((broker) => (
                            <option key={broker.id} value={broker.id}>
                              {displayBrokerName(broker.fullName) || broker.email}
                            </option>
                          ))}
                        </select>
                      ))}
                      <p className="text-[11px] text-muted-foreground">
                        O primeiro captador é obrigatório e o segundo é opcional. Sônia Lima
                        representa o acesso CRM.
                      </p>
                    </div>
                  </Field>
                )}
                {(isAdmin || editing) && (
                  <div className="sm:col-span-2 grid gap-3 rounded-lg border border-white/10 bg-white/[0.02] p-3 sm:grid-cols-2">
                    <p className="sm:col-span-2 text-xs text-muted-foreground">
                      {canEditPortalCodes
                        ? "Referências dos anúncios nos portais. Somente crmallyson pode alterar esses códigos."
                        : "Referências dos anúncios nos portais. Os códigos só podem ser alterados por crmallyson."}
                    </p>
                    <Field label="Código do anúncio na W Imóveis">
                      <input
                        value={portalReferences.wimoveis}
                        onChange={(event) =>
                          setPortalReferences((current) => ({
                            ...current,
                            wimoveis: event.target.value,
                          }))
                        }
                        className={inputClass}
                        placeholder="Ex.: código enviado no clientListingId"
                        readOnly={!canEditPortalCodes || readOnly}
                        aria-readonly={!canEditPortalCodes || readOnly}
                      />
                    </Field>
                    <Field label="Código do anúncio na DF Imóveis">
                      <input
                        value={portalReferences.dfimoveis}
                        onChange={(event) =>
                          setPortalReferences((current) => ({
                            ...current,
                            dfimoveis: event.target.value,
                          }))
                        }
                        className={inputClass}
                        placeholder="Ex.: referência do portal"
                        readOnly={!canEditPortalCodes || readOnly}
                        aria-readonly={!canEditPortalCodes || readOnly}
                      />
                    </Field>
                  </div>
                )}
                <label className="flex items-center gap-3 self-end rounded-lg border border-white/10 bg-white/[0.03] px-3 py-2.5 text-sm">
                  <input
                    type="checkbox"
                    checked={form.hasPhotos}
                    disabled={readOnly}
                    onChange={(event) => updateForm("hasPhotos", event.target.checked)}
                    className="accent-copper"
                  />
                  Possui fotos
                </label>
              </div>
            </div>

            {error && (
              <p role="alert" className="sm:col-span-2 text-sm text-red-300">
                {error}
              </p>
            )}


            <div className="flex justify-between mt-4 border-t border-white/10 pt-4">
              <div>
                {isPending && isAdmin && activeTab === "admin" && (
                  <p className="text-sm text-copper font-medium">
                    Ao salvar, o status passará de Pendente para Cadastrado.
                  </p>
                )}
              </div>
              <div className="flex gap-2">
                <Button
                  type="button"
                  variant="ghost"
                  onClick={() => setOpen(false)}
                  disabled={saving}
                >
                  {readOnly ? "Fechar" : "Cancelar"}
                </Button>
                {!readOnly && (
                  <Button
                    type="submit"
                    className="bg-copper text-white hover:bg-copper/90"
                    disabled={saving}
                  >
                    {saving && <Loader2 size={16} className="animate-spin" />}{" "}
                    {editing ? "Salvar alterações" : "Salvar e Continuar"}
                  </Button>
                )}
              </div>
            </div>
          </form>
        )}
      </DialogContent>
    </Dialog>
  );
}

function Select({
  value,
  onChange,
  options,
  disabled,
}: {
  value: string;
  onChange: (value: string) => void;
  options: string[];
  disabled?: boolean;
}) {
  return (
    <select
      value={value}
      disabled={disabled}
      onChange={(event) => onChange(event.target.value)}
      className={inputClass}
    >
      {options.map((option) => (
        <option key={option}>{option}</option>
      ))}
    </select>
  );
}

function Field({
  label,
  required,
  className,
  children,
}: {
  label: string;
  required?: boolean;
  className?: string;
  children: ReactNode;
}) {
  return (
    <label className={`block text-xs text-muted-foreground ${className ?? ""}`}>
      {label}
      {required && <span className="text-copper"> *</span>}
      <span className="mt-1.5 block">{children}</span>
    </label>
  );
}

const inputClass =
  "w-full rounded-lg border border-white/10 bg-white/[0.03] px-3 py-2.5 text-sm text-foreground outline-none transition focus:border-copper/50 disabled:cursor-not-allowed disabled:opacity-70";

import type { DashboardData } from "@/lib/api";
import { CrudApiError } from "@/lib/crud-api";
import { supabase } from "@/lib/supabase";

export type Property = {
  id: string;
  wimoveisCode?: string;
  dfimoveisCode?: string;
  title: string;
  address?: string;
  neighborhood?: string;
  city?: string;
  type?: string;
  bedrooms?: number | null;
  purpose?: string;
  value?: number;
  broker?: string;
  owner?: string;
  status?: string;
  hasPhotos?: boolean;
  photos?: string[];
  publicUrl?: string;
  reviewable?: boolean;
  registrationPhase?: "PENDING" | "COMPLETED";
  modalidade?: string;
  sonialimaExclusivityControl?:
    "COM EXCLUSIVIDADE" | "SEM EXCLUSIVIDADE" | "SEM AUTORIZACAO DE VENDA";
  captureRankingEnabled?: boolean;
};
export type PropertyInput = Omit<
  Property,
  | "id"
  | "photos"
  | "publicUrl"
  | "reviewable"
  | "registrationPhase"
  | "modalidade"
  | "sonialimaExclusivityControl"
  | "captureRankingEnabled"
> & {
  sonialimaExclusivityControl?:
    "COM EXCLUSIVIDADE" | "SEM EXCLUSIVIDADE" | "SEM AUTORIZACAO DE VENDA";
};

export type PropertyAuthorization = {
  propertyId: string;
  submittedBy: string;
  authorizationStartedAt?: string;
  saldoDevedor?: number;
  valorPrestacao?: number;
  agenteFinanceiro?: string;
  metragem?: number;
  valorPretendido?: number;
  valorAvaliacao?: number;
  iptu?: number;
  numeroInscricao?: string;
  vagasGaragem?: number;
  administradoraCondominio?: string;
  telefoneCondominio?: string;
  valorCondominio?: number;
  prop1Nome: string;
  prop1Profissao: string;
  prop1EstadoCivil: string;
  prop1Cpf: string;
  prop1CnhRg: string;
  prop1OrgaoExpedidor?: string;
  prop1Uf?: string;
  prop1Nacionalidade: string;
  prop1Telefone: string;
  prop1Email: string;
  prop2Nome?: string;
  prop2Profissao?: string;
  prop2EstadoCivil?: string;
  prop2Cpf?: string;
  prop2CnhRg?: string;
  prop2OrgaoExpedidor?: string;
  prop2Uf?: string;
  prop2Nacionalidade?: string;
  prop2Telefone?: string;
  prop2Email?: string;
  modalidade: "Com exclusividade" | "Termo sem exclusividade" | "Sem termo de autorização";
  observacoesCliente: string;
  prazoClausula2: string;
  honorariosClausula4Pct?: number;
  regularizacaoStatus: "Regularizado" | "Não regularizado";
  escrituraStatus: "Com escritura" | "Sem escritura";
  observacoesProprietario?: string;
  informacoesRelevantes?: string;
};
export type PropertyAuthorizationInput = Omit<
  PropertyAuthorization,
  "propertyId" | "submittedBy" | "authorizationStartedAt"
>;

export type PropertyAuthorizationPdf = {
  id: string;
  propertyId: string;
  generatedBy: string;
  generatedAt: string;
  versionNumber: number;
  storagePath: string;
  status?: string;
};

export function propertiesFromDashboard(data?: DashboardData): Property[] {
  return (data?.imoveis ?? []).map((property, index) => ({
    id: property.id || `property-${index}`,
    wimoveisCode: property.codigoWImoveis,
    dfimoveisCode: property.codigoDfImoveis,
    title: property.titulo,
    address: property.endereco,
    neighborhood: property.bairro,
    city: property.cidade,
    type: property.tipo,
    bedrooms: property.quartos ?? null,
    purpose: property.finalidade,
    value: property.valor,
    broker: property.corretor,
    owner: property.proprietario,
    status: property.status,
    hasPhotos:
      String(property.fotos ?? "")
        .trim()
        .toLocaleLowerCase("pt-BR") === "sim",
    photos: Array.isArray(property.fotos)
      ? property.fotos
      : property.fotos
        ? property.fotos
            .split(",")
            .map((photo) => photo.trim())
            .filter(Boolean)
        : [],
    registrationPhase: property.registrationPhase as "PENDING" | "COMPLETED" | undefined,
    modalidade: property.publicModalidade,
    sonialimaExclusivityControl: property.sonialimaExclusivityControl as
      "COM EXCLUSIVIDADE" | "SEM EXCLUSIVIDADE" | "SEM AUTORIZACAO DE VENDA" | undefined,
    captureRankingEnabled: Boolean(property.captureRankingEnabled),
  }));
}

const clean = (value?: string) => value?.trim() || null;

export function createPropertyExternalId() {
  const bytes = new Uint8Array(16);
  if (globalThis.crypto?.getRandomValues) {
    globalThis.crypto.getRandomValues(bytes);
    const randomPart = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
    return `property:${randomPart}`;
  }
  return `property:${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
}

function rowToProperty(row: Record<string, unknown>): Property {
  return {
    id: String(row.external_id),
    wimoveisCode: String(row.wimoveis_code ?? ""),
    dfimoveisCode: String(row.dfimoveis_code ?? ""),
    title: String(row.title ?? ""),
    address: String(row.address ?? ""),
    neighborhood: String(row.neighborhood ?? ""),
    city: String(row.city ?? ""),
    type: String(row.property_type ?? ""),
    bedrooms: row.bedrooms == null ? null : Number(row.bedrooms),
    purpose: String(row.purpose ?? ""),
    value: Number(row.value ?? 0),
    broker: String(row.brokers ?? ""),
    owner: String(row.owner_name ?? ""),
    status: String(row.status ?? ""),
    hasPhotos: Boolean(row.has_photos),
    registrationPhase: (row.registration_phase as "PENDING" | "COMPLETED") || "COMPLETED",
    modalidade: String(row.public_modalidade ?? ""),
    sonialimaExclusivityControl: row.sonialima_exclusivity_control as
      "COM EXCLUSIVIDADE" | "SEM EXCLUSIVIDADE" | "SEM AUTORIZACAO DE VENDA" | undefined,
    captureRankingEnabled: Boolean(row.capture_ranking_enabled),
  };
}

export async function saveProperty(input: PropertyInput, id?: string): Promise<Property> {
  if (
    input.bedrooms != null &&
    (!Number.isInteger(input.bedrooms) || input.bedrooms < 0 || input.bedrooms > 2147483647)
  ) {
    throw new CrudApiError("Informe um número inteiro de quartos, igual ou maior que zero.");
  }
  const externalId = id ?? createPropertyExternalId();
  const values = {
    title: input.title.trim(),
    address: clean(input.address) ?? input.title.trim(),
    neighborhood: clean(input.neighborhood),
    city: clean(input.city),
    property_type: clean(input.type),
    ...(input.bedrooms !== undefined ? { bedrooms: input.bedrooms } : {}),
    purpose: clean(input.purpose),
    value: input.value ?? 0,
    brokers: clean(input.broker),
    owner_name: clean(input.owner),
    status: clean(input.status) ?? "Ativo",
    has_photos: Boolean(input.hasPhotos),
    wimoveis_code: clean(input.wimoveisCode),
    dfimoveis_code: clean(input.dfimoveisCode),

    updated_at: new Date().toISOString(),
  };

  if (!id) {
    const { data: userData } = await supabase.auth.getUser();
    (values as any).created_by = userData.user?.id;
  }

  const request = id
    ? supabase.from("crm_property_catalog").update(values).eq("external_id", id)
    : supabase
        .from("crm_property_catalog")
        .insert({ external_id: externalId, registration_phase: "COMPLETED", ...values });
  const { data, error } = await request.select("*").single();
  if (error) {
    if (error.code === "23505") throw new CrudApiError("Este código de anúncio já está em uso.");
    throw new CrudApiError(error.message);
  }
  return rowToProperty(data);
}

export async function completePropertyRegistration(id: string): Promise<void> {
  const { error } = await supabase
    .from("crm_property_catalog")
    .update({ registration_phase: "COMPLETED" })
    .eq("external_id", id);
  if (error) throw new CrudApiError(error.message);
}

export async function savePropertyAuthorization(
  propertyId: string,
  input: PropertyAuthorizationInput,
): Promise<void> {
  const { data: userData } = await supabase.auth.getUser();
  if (!userData.user) throw new CrudApiError("Usuário não autenticado");

  // Pegamos a ficha existente se houver. Imóveis legados sem ficha não serão forçados a criar uma vazia.
  const { data: existing } = await supabase
    .from("crm_property_authorizations")
    .select("submitted_by")
    .eq("property_id", propertyId)
    .maybeSingle();

  if (!existing) {
    return; // Para imóvel legado sem autorização, NÃO criamos uma autorização vazia.
  }

  const payload = {
    // update não precisa enviar property_id e submitted_by se não quisermos alterar

    saldo_devedor: input.saldoDevedor,
    valor_prestacao: input.valorPrestacao,
    agente_financeiro: clean(input.agenteFinanceiro),
    metragem: input.metragem,
    valor_pretendido: input.valorPretendido,
    valor_avaliacao: input.valorAvaliacao,
    iptu: input.iptu,
    numero_inscricao: clean(input.numeroInscricao),
    vagas_garagem: input.vagasGaragem,
    administradora_condominio: clean(input.administradoraCondominio),
    telefone_condominio: clean(input.telefoneCondominio),
    valor_condominio: input.valorCondominio,
    prop1_nome: input.prop1Nome.trim(),
    prop1_profissao: input.prop1Profissao.trim(),
    prop1_estado_civil: input.prop1EstadoCivil.trim(),
    prop1_cpf: input.prop1Cpf.trim(),
    prop1_cnh_rg: input.prop1CnhRg.trim(),
    prop1_orgao_expedidor: clean(input.prop1OrgaoExpedidor),
    prop1_uf: clean(input.prop1Uf),
    prop1_nacionalidade: input.prop1Nacionalidade.trim(),
    prop1_telefone: input.prop1Telefone.trim(),
    prop1_email: input.prop1Email.trim(),
    prop2_nome: clean(input.prop2Nome),
    prop2_profissao: clean(input.prop2Profissao),
    prop2_estado_civil: clean(input.prop2EstadoCivil),
    prop2_cpf: clean(input.prop2Cpf),
    prop2_cnh_rg: clean(input.prop2CnhRg),
    prop2_orgao_expedidor: clean(input.prop2OrgaoExpedidor),
    prop2_uf: clean(input.prop2Uf),
    prop2_nacionalidade: clean(input.prop2Nacionalidade),
    prop2_telefone: clean(input.prop2Telefone),
    prop2_email: clean(input.prop2Email),
    modalidade: input.modalidade,
    observacoes_cliente: input.observacoesCliente.trim(),
    prazo_clausula_2: input.prazoClausula2.trim(),
    honorarios_clausula_4_pct: input.honorariosClausula4Pct,
    regularizacao_status: input.regularizacaoStatus,
    escritura_status: input.escrituraStatus,
    observacoes_proprietario: clean(input.observacoesProprietario),
    informacoes_relevantes: clean(input.informacoesRelevantes),
  };

  const { error } = await supabase
    .from("crm_property_authorizations")
    .update(payload)
    .eq("property_id", propertyId);
  if (error) throw new CrudApiError(error.message);
}

export async function setSoniaLimaPropertyExclusivity(
  propertyId: string,
  exclusivity: "COM EXCLUSIVIDADE" | "SEM EXCLUSIVIDADE" | "SEM AUTORIZACAO DE VENDA",
): Promise<void> {
  const { error } = await supabase.rpc("set_sonialima_property_exclusivity", {
    p_property_id: propertyId,
    p_exclusivity: exclusivity,
  });
  if (error) throw new CrudApiError(error.message);
}

export async function submitPropertyAuthorizationPhase1(
  propertyId: string,
  catalogData: any,
  authData: any,
  capturerId?: string,
): Promise<void> {
  const { error } = await supabase.rpc("submit_property_authorization_phase1", {
    p_external_id: propertyId,
    p_catalog_data: catalogData,
    p_auth_data: authData,
    p_capturer_id: capturerId || undefined,
  });
  if (error) {
    if (error.code === "23505") throw new CrudApiError("Este código de anúncio já está em uso.");
    throw new CrudApiError(error.message);
  }
}

export async function fetchPropertyAuthorization(
  propertyId: string,
): Promise<PropertyAuthorization | null> {
  const { data, error } = await supabase
    .from("crm_property_authorizations")
    .select("*")
    .eq("property_id", propertyId)
    .maybeSingle();
  if (error) throw new CrudApiError(error.message);
  if (!data) return null;
  return {
    propertyId: data.property_id,
    submittedBy: data.submitted_by,
    authorizationStartedAt: data.authorization_started_at,
    saldoDevedor: data.saldo_devedor,
    valorPrestacao: data.valor_prestacao,
    agenteFinanceiro: data.agente_financeiro,
    metragem: data.metragem,
    valorPretendido: data.valor_pretendido,
    valorAvaliacao: data.valor_avaliacao,
    iptu: data.iptu,
    numeroInscricao: data.numero_inscricao,
    vagasGaragem: data.vagas_garagem,
    administradoraCondominio: data.administradora_condominio,
    telefoneCondominio: data.telefone_condominio,
    valorCondominio: data.valor_condominio,
    prop1Nome: data.prop1_nome,
    prop1Profissao: data.prop1_profissao,
    prop1EstadoCivil: data.prop1_estado_civil,
    prop1Cpf: data.prop1_cpf,
    prop1CnhRg: data.prop1_cnh_rg,
    prop1OrgaoExpedidor: data.prop1_orgao_expedidor,
    prop1Uf: data.prop1_uf,
    prop1Nacionalidade: data.prop1_nacionalidade,
    prop1Telefone: data.prop1_telefone,
    prop1Email: data.prop1_email,
    prop2Nome: data.prop2_nome,
    prop2Profissao: data.prop2_profissao,
    prop2EstadoCivil: data.prop2_estado_civil,
    prop2Cpf: data.prop2_cpf,
    prop2CnhRg: data.prop2_cnh_rg,
    prop2OrgaoExpedidor: data.prop2_orgao_expedidor,
    prop2Uf: data.prop2_uf,
    prop2Nacionalidade: data.prop2_nacionalidade,
    prop2Telefone: data.prop2_telefone,
    prop2Email: data.prop2_email,
    modalidade: data.modalidade,
    observacoesCliente: data.observacoes_cliente,
    prazoClausula2: data.prazo_clausula_2,
    honorariosClausula4Pct: data.honorarios_clausula_4_pct,
    regularizacaoStatus: data.regularizacao_status,
    escrituraStatus: data.escritura_status,
    observacoesProprietario: data.observacoes_proprietario,
    informacoesRelevantes: data.informacoes_relevantes,
  };
}

export async function fetchPropertyAuthorizationPdfs(
  propertyId: string,
): Promise<PropertyAuthorizationPdf[]> {
  const { data, error } = await supabase
    .from("crm_property_authorization_pdfs")
    .select("*")
    .eq("property_id", propertyId)
    .eq("status", "FINALIZED")
    .order("version_number", { ascending: false });
  if (error) throw new CrudApiError(error.message);
  return (data || []).map((item) => ({
    id: item.id,
    propertyId: item.property_id,
    generatedBy: item.generated_by,
    generatedAt: item.generated_at,
    versionNumber: item.version_number,
    storagePath: item.storage_path,
    status: item.status,
  }));
}

export async function reservePdfVersion(
  propertyId: string,
): Promise<{ id: string; version: number; storage_path: string }> {
  const { data, error } = await supabase.rpc("reserve_property_authorization_pdf", {
    p_property_id: propertyId,
  });
  if (error) throw new CrudApiError(error.message);
  return data;
}

export async function finalizePdfVersion(
  propertyId: string,
  version: number,
  storagePath: string,
): Promise<void> {
  const { error } = await supabase.rpc("finalize_property_authorization_pdf", {
    p_property_id: propertyId,
    p_version: version,
    p_storage_path: storagePath,
  });
  if (error) throw new CrudApiError(error.message);
}

export async function updatePropertyValue(id: string, value: number): Promise<Property> {
  const { data, error } = await supabase
    .from("crm_property_catalog")
    .update({ value, updated_at: new Date().toISOString() })
    .eq("external_id", id)
    .select("*")
    .single();
  if (error) throw new CrudApiError(error.message);
  return rowToProperty(data);
}

export async function findMatchingPropertyId(input: PropertyInput): Promise<string | null> {
  const checks = [
    ["wimoveis_code", clean(input.wimoveisCode)],
    ["dfimoveis_code", clean(input.dfimoveisCode)],
  ] as const;
  for (const [column, value] of checks) {
    if (!value) continue;
    const { data, error } = await supabase
      .from("crm_property_catalog")
      .select("external_id")
      .ilike(column, value)
      .limit(1)
      .maybeSingle();
    if (error) throw new CrudApiError(error.message);
    if (data?.external_id) return String(data.external_id);
  }
  return null;
}

export async function deleteProperty(id: string): Promise<{ _id: string }> {
  const bucket = supabase.storage.from("property-authorizations");
  const { data: rootFiles, error: rootListError } = await bucket.list(id, { limit: 1000 });
  if (rootListError) throw new CrudApiError(rootListError.message);
  const { data: pdfFiles, error: pdfListError } = await bucket.list(`${id}/pdfs`, { limit: 1000 });
  if (pdfListError) throw new CrudApiError(pdfListError.message);
  const storagePaths = [
    ...(rootFiles ?? []).filter((file) => file.name !== "pdfs").map((file) => `${id}/${file.name}`),
    ...(pdfFiles ?? []).map((file) => `${id}/pdfs/${file.name}`),
  ];
  const { error } = await supabase.rpc("delete_property_metadata", { p_property_id: id });
  if (error) throw new CrudApiError(error.message);
  if (storagePaths.length) {
    const { error: storageError } = await bucket.remove(storagePaths);
    if (storageError)
      throw new CrudApiError(
        `Imóvel excluído, mas não foi possível apagar os arquivos: ${storageError.message}`,
      );
  }
  return { _id: id };
}

export async function setPropertyCaptureRankingEnabled(
  propertyId: string,
  enabled: boolean,
): Promise<void> {
  const { error } = await supabase.rpc("set_property_capture_ranking_enabled", {
    p_property_id: propertyId,
    p_enabled: enabled,
  });
  if (error) throw new CrudApiError(error.message);
}

-- 20260819000013_fix_authorization_rpc.sql
-- Restaura e corrige a RPC submit_property_authorization_phase1 que foi omitida nas migrations 11/12
-- Remove as obrigatoriedades de campos (Fase 1) permitindo envio vazio, conforme solicitação do usuário.

CREATE OR REPLACE FUNCTION public.submit_property_authorization_phase1(
  p_external_id text,
  p_catalog_data jsonb,
  p_auth_data jsonb,
  p_capturer_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_role text;
  v_email text;
  v_sonialima_exclusivity text;
BEGIN
  SELECT role, email INTO v_role, v_email FROM public.profiles WHERE id = auth.uid();
  IF v_role != 'broker' AND NOT public.is_allyson_admin() THEN
    RAISE EXCEPTION 'Apenas corretores e o administrador geral (Allyson) podem cadastrar captações iniciais.';
  END IF;

  IF EXISTS (SELECT 1 FROM public.crm_property_catalog WHERE external_id = p_external_id) THEN
    RAISE EXCEPTION 'Imóvel já existente. A submissão inicial só pode ser feita para imóveis novos.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_capturer_id AND role = 'broker') THEN
    RAISE EXCEPTION 'Captador inválido.';
  END IF;

  -- O controle interno da SoniaLima é sempre NULL na criação inicial. Só o AcessoCRM pode alterar via RPC específica depois.
  v_sonialima_exclusivity := null;

  -- 1. Inserir Catálogo (Forçar PENDING)
  -- Permite campos vazios. Se nulo ou vazio na UI, grava strings vazias em vez de rejeitar.
  INSERT INTO public.crm_property_catalog (
    external_id,
    title,
    address,
    neighborhood,
    city,
    property_type,
    purpose,
    value,
    owner_name,
    status,
    has_photos,
    created_by,
    registration_phase,
    public_modalidade,
    sonialima_exclusivity_control,
    updated_at
  ) VALUES (
    p_external_id,
    COALESCE(p_catalog_data->>'title', ''),
    COALESCE(p_catalog_data->>'address', p_catalog_data->>'title', ''),
    COALESCE(p_catalog_data->>'neighborhood', ''),
    COALESCE(p_catalog_data->>'city', ''),
    COALESCE(p_catalog_data->>'type', ''),
    COALESCE(p_catalog_data->>'purpose', ''),
    COALESCE(NULLIF(trim(p_catalog_data->>'value'), '')::numeric, 0),
    COALESCE(p_catalog_data->>'ownerName', ''),
    COALESCE(NULLIF(trim(p_catalog_data->>'status'), ''), 'Ativo'),
    COALESCE((p_catalog_data->>'hasPhotos')::boolean, false),
    auth.uid(),
    'PENDING',
    COALESCE(NULLIF(trim(p_auth_data->>'modalidade'), ''), 'Sem termo de autorização'),
    v_sonialima_exclusivity,
    now()
  );

  -- 2. Inserir Autorização
  INSERT INTO public.crm_property_authorizations (
    property_id,
    submitted_by,
    saldo_devedor,
    valor_prestacao,
    agente_financeiro,
    metragem,
    valor_pretendido,
    valor_avaliacao,
    iptu,
    numero_inscricao,
    vagas_garagem,
    administradora_condominio,
    telefone_condominio,
    valor_condominio,
    prop1_nome,
    prop1_profissao,
    prop1_estado_civil,
    prop1_cpf,
    prop1_cnh_rg,
    prop1_orgao_expedidor,
    prop1_uf,
    prop1_nacionalidade,
    prop1_telefone,
    prop1_email,
    prop2_nome,
    prop2_profissao,
    prop2_estado_civil,
    prop2_cpf,
    prop2_cnh_rg,
    prop2_orgao_expedidor,
    prop2_uf,
    prop2_nacionalidade,
    prop2_telefone,
    prop2_email,
    modalidade,
    observacoes_cliente,
    prazo_clausula_2,
    honorarios_clausula_4_pct,
    regularizacao_status,
    escritura_status,
    observacoes_proprietario,
    informacoes_relevantes,
    updated_at
  ) VALUES (
    p_external_id,
    auth.uid(),
    COALESCE(NULLIF(trim(p_auth_data->>'saldoDevedor'), '')::numeric, 0),
    COALESCE(NULLIF(trim(p_auth_data->>'valorPrestacao'), '')::numeric, 0),
    COALESCE(p_auth_data->>'agenteFinanceiro', ''),
    COALESCE(NULLIF(trim(p_auth_data->>'metragem'), '')::numeric, 0),
    COALESCE(NULLIF(trim(p_auth_data->>'valorPretendido'), '')::numeric, 0),
    COALESCE(NULLIF(trim(p_auth_data->>'valorAvaliacao'), '')::numeric, 0),
    COALESCE(NULLIF(trim(p_auth_data->>'iptu'), '')::numeric, 0),
    COALESCE(p_auth_data->>'numeroInscricao', ''),
    COALESCE(NULLIF(trim(p_auth_data->>'vagasGaragem'), '')::integer, 0),
    COALESCE(p_auth_data->>'administradoraCondominio', ''),
    COALESCE(p_auth_data->>'telefoneCondominio', ''),
    COALESCE(NULLIF(trim(p_auth_data->>'valorCondominio'), '')::numeric, 0),
    COALESCE(p_auth_data->>'prop1Nome', ''),
    COALESCE(p_auth_data->>'prop1Profissao', ''),
    COALESCE(p_auth_data->>'prop1EstadoCivil', ''),
    COALESCE(p_auth_data->>'prop1Cpf', ''),
    COALESCE(p_auth_data->>'prop1CnhRg', ''),
    COALESCE(p_auth_data->>'prop1OrgaoExpedidor', ''),
    COALESCE(p_auth_data->>'prop1Uf', ''),
    COALESCE(p_auth_data->>'prop1Nacionalidade', ''),
    COALESCE(p_auth_data->>'prop1Telefone', ''),
    COALESCE(p_auth_data->>'prop1Email', ''),
    p_auth_data->>'prop2Nome',
    p_auth_data->>'prop2Profissao',
    p_auth_data->>'prop2EstadoCivil',
    p_auth_data->>'prop2Cpf',
    p_auth_data->>'prop2CnhRg',
    p_auth_data->>'prop2OrgaoExpedidor',
    p_auth_data->>'prop2Uf',
    p_auth_data->>'prop2Nacionalidade',
    p_auth_data->>'prop2Telefone',
    p_auth_data->>'prop2Email',
    COALESCE(NULLIF(trim(p_auth_data->>'modalidade'), ''), 'Sem termo de autorização'),
    COALESCE(p_auth_data->>'observacoesCliente', ''),
    COALESCE(NULLIF(trim(p_auth_data->>'prazoClausula2'), ''), '0'),
    COALESCE(NULLIF(trim(replace(p_auth_data->>'honorariosClausula4Pct', ',', '.')), '')::numeric, 0),
    COALESCE(NULLIF(trim(p_auth_data->>'regularizacaoStatus'), ''), 'Não regularizado'),
    COALESCE(NULLIF(trim(p_auth_data->>'escrituraStatus'), ''), 'Sem escritura'),
    p_auth_data->>'observacoesProprietario',
    p_auth_data->>'informacoesRelevantes',
    now()
  );

  -- 3. Associar Captador
  INSERT INTO public.crm_property_capturer_assignments (
    property_id,
    broker_id,
    assigned_by
  ) VALUES (
    p_external_id,
    p_capturer_id,
    auth.uid()
  );
END;
$$;

REVOKE ALL ON FUNCTION public.submit_property_authorization_phase1(text, jsonb, jsonb, uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.submit_property_authorization_phase1(text, jsonb, jsonb, uuid) TO authenticated, service_role;

-- Fase 1 e 2 - Controle de Cadastro e Autorização de Venda

-- 1. Modificar crm_property_catalog
ALTER TABLE public.crm_property_catalog
ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES auth.users(id),
ADD COLUMN IF NOT EXISTS registration_phase text CHECK (registration_phase IN ('PENDING', 'COMPLETED')) DEFAULT 'COMPLETED',
ADD COLUMN IF NOT EXISTS public_modalidade text,
ADD COLUMN IF NOT EXISTS sonialima_exclusivity_control text CHECK (sonialima_exclusivity_control IN ('COM EXCLUSIVIDADE', 'SEM EXCLUSIVIDADE'));

-- 1.A Proteger controle exclusivo SoniaLima no backend
CREATE OR REPLACE FUNCTION protect_sonialima_exclusivity()
RETURNS trigger AS $$
BEGIN
  IF NEW.sonialima_exclusivity_control IS DISTINCT FROM OLD.sonialima_exclusivity_control THEN
    IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND email ILIKE 'unassigned-institutional@example.invalid') THEN
      RAISE EXCEPTION 'Apenas o perfil SoniaLima/AcessoCRM pode alterar o Controle de Exclusividade interno.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public;

DROP TRIGGER IF EXISTS trg_protect_sonialima_exclusivity ON public.crm_property_catalog;
CREATE TRIGGER trg_protect_sonialima_exclusivity
BEFORE UPDATE ON public.crm_property_catalog
FOR EACH ROW EXECUTE FUNCTION protect_sonialima_exclusivity();


-- 1.B Função de Segurança Centralizada para RLS de Autorizações
CREATE OR REPLACE FUNCTION public.can_access_property_authorization(p_property_id text, p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_role text;
  v_email text;
  v_submitted_by uuid;
BEGIN
  SELECT role, email INTO v_role, v_email FROM public.profiles WHERE id = p_user_id;

  IF v_role = 'admin' AND (v_email ILIKE 'crmsoniaallyson@gmail.com' OR v_email ILIKE 'unassigned-institutional@example.invalid') THEN
    RETURN true;
  END IF;

  SELECT submitted_by INTO v_submitted_by FROM public.crm_property_authorizations WHERE property_id = p_property_id;
  IF v_submitted_by = p_user_id THEN
    RETURN true;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.crm_property_capturer_assignments
    WHERE property_id = p_property_id AND broker_id = p_user_id
  ) THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$$;

-- 1.C RPC exclusiva para AcessoCRM setar a exclusividade
CREATE OR REPLACE FUNCTION public.set_sonialima_property_exclusivity(p_property_id text, p_exclusivity text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND email ILIKE 'unassigned-institutional@example.invalid') THEN
    RAISE EXCEPTION 'Apenas o perfil SoniaLima/AcessoCRM pode alterar o Controle de Exclusividade interno.';
  END IF;

  IF p_exclusivity NOT IN ('COM EXCLUSIVIDADE', 'SEM EXCLUSIVIDADE') THEN
    RAISE EXCEPTION 'Valor de exclusividade inválido.';
  END IF;

  UPDATE public.crm_property_catalog
  SET sonialima_exclusivity_control = p_exclusivity
  WHERE external_id = p_property_id;
END;
$$;

-- 1.1 Bloquear INSERT indiscriminado na crm_property_catalog e permitir apenas perfis válidos.
-- Remover policy genérica se existir
DROP POLICY IF EXISTS "Enable insert for authenticated users only" ON public.crm_property_catalog;
DROP POLICY IF EXISTS "Only Allyson creates properties" ON public.crm_property_catalog;
DROP POLICY IF EXISTS "Insert for authorized CRM roles" ON public.crm_property_catalog;
CREATE POLICY "Insert for authorized CRM roles"
ON public.crm_property_catalog FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'
    AND profiles.email ILIKE 'crmsoniaallyson@gmail.com'
  )
  AND sonialima_exclusivity_control IS NULL
);

-- 1.2 UPDATE POLICY
DROP POLICY IF EXISTS "Authenticated users update properties" ON public.crm_property_catalog;
DROP POLICY IF EXISTS "Allyson can update all properties" ON public.crm_property_catalog;
CREATE POLICY "Allyson can update all properties"
ON public.crm_property_catalog FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'
    AND profiles.email ILIKE 'crmsoniaallyson@gmail.com'
  )
);

CREATE OR REPLACE FUNCTION delete_property_metadata(p_property_id text)
RETURNS void AS $$
BEGIN
  RAISE EXCEPTION 'Exclusão desabilitada permanentemente.';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public;

CREATE OR REPLACE FUNCTION prevent_property_deletion()
RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'A exclusão de imóveis está desabilitada em todo o sistema.';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public;

DROP TRIGGER IF EXISTS trg_prevent_property_deletion ON public.crm_property_catalog;
CREATE TRIGGER trg_prevent_property_deletion
BEFORE DELETE ON public.crm_property_catalog
FOR EACH ROW EXECUTE FUNCTION prevent_property_deletion();

-- 2. Tabela crm_property_authorizations (Captação)
CREATE TABLE IF NOT EXISTS public.crm_property_authorizations (
    property_id text PRIMARY KEY REFERENCES public.crm_property_catalog(external_id) ON DELETE RESTRICT,
    submitted_by uuid REFERENCES auth.users(id) NOT NULL,
    authorization_started_at timestamptz,
    initial_documents_finalized_at timestamptz,

    saldo_devedor numeric NOT NULL,
    valor_prestacao numeric NOT NULL,
    agente_financeiro text NOT NULL,
    metragem numeric NOT NULL,
    valor_pretendido numeric NOT NULL,
    valor_avaliacao numeric NOT NULL,
    iptu numeric NOT NULL,
    numero_inscricao text NOT NULL,
    vagas_garagem integer NOT NULL,
    administradora_condominio text NOT NULL,
    telefone_condominio text NOT NULL,
    valor_condominio numeric NOT NULL,

    prop1_nome text NOT NULL,
    prop1_profissao text NOT NULL,
    prop1_estado_civil text NOT NULL,
    prop1_cpf text NOT NULL,
    prop1_cnh_rg text NOT NULL,
    prop1_orgao_expedidor text NOT NULL,
    prop1_uf text NOT NULL,
    prop1_nacionalidade text NOT NULL,
    prop1_telefone text NOT NULL,
    prop1_email text NOT NULL,

    prop2_nome text,
    prop2_profissao text,
    prop2_estado_civil text,
    prop2_cpf text,
    prop2_cnh_rg text,
    prop2_orgao_expedidor text,
    prop2_uf text,
    prop2_nacionalidade text,
    prop2_telefone text,
    prop2_email text,

    modalidade text NOT NULL CHECK (modalidade IN ('Com exclusividade', 'Termo sem exclusividade', 'Sem termo de autorização')),
    observacoes_cliente text NOT NULL,
    prazo_clausula_2 text NOT NULL,
    honorarios_clausula_4_pct numeric NOT NULL,

    regularizacao_status text NOT NULL CHECK (regularizacao_status IN ('Regularizado', 'Não regularizado')),
    escritura_status text NOT NULL CHECK (escritura_status IN ('Com escritura', 'Sem escritura')),
    observacoes_proprietario text,
    informacoes_relevantes text,

    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now()
);

-- 2.A Trigger para manter public_modalidade na crm_property_catalog
CREATE OR REPLACE FUNCTION sync_property_modalidade()
RETURNS trigger AS $$
BEGIN
  UPDATE public.crm_property_catalog
  SET public_modalidade = NEW.modalidade
  WHERE external_id = NEW.property_id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public;

DROP TRIGGER IF EXISTS trg_sync_property_modalidade ON public.crm_property_authorizations;
CREATE TRIGGER trg_sync_property_modalidade
AFTER INSERT OR UPDATE OF modalidade ON public.crm_property_authorizations
FOR EACH ROW EXECUTE FUNCTION sync_property_modalidade();

ALTER TABLE public.crm_property_authorizations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Visibilidade privada autenticada para autorizações"
ON public.crm_property_authorizations FOR SELECT
TO authenticated
USING (
  public.can_access_property_authorization(property_id, auth.uid())
);

CREATE POLICY "Apenas Allyson pode editar autorizações"
ON public.crm_property_authorizations FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'
    AND profiles.email ILIKE 'crmsoniaallyson@gmail.com'
  )
);

CREATE POLICY "Insert for authorized CRM roles authorizations"
ON public.crm_property_authorizations FOR INSERT
TO authenticated
WITH CHECK (false); -- Insert agora só pela RPC Atômica

-- 3. Versionamento de PDFs (crm_property_authorization_pdfs)
CREATE TABLE IF NOT EXISTS public.crm_property_authorization_pdfs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id text REFERENCES public.crm_property_catalog(external_id) ON DELETE RESTRICT,
  generated_by uuid REFERENCES auth.users(id) NOT NULL,
  generated_at timestamptz DEFAULT NULL,
  version_number integer NOT NULL,
  storage_path text NOT NULL,
  status text DEFAULT 'RESERVED' CHECK (status IN ('RESERVED', 'FINALIZED')),
  UNIQUE(property_id, version_number)
);


-- 3.A RPC para reservar a versão
CREATE OR REPLACE FUNCTION public.reserve_property_authorization_pdf(p_property_id text)
RETURNS jsonb AS $$
DECLARE
  v_is_authorized boolean := false;
  v_next_version integer;
  v_storage_path text;
  v_res_id uuid;
BEGIN
  IF EXISTS (SELECT 1 FROM crm_property_authorizations WHERE property_id = p_property_id AND submitted_by = auth.uid()) THEN
    v_is_authorized := true;
  ELSIF EXISTS (SELECT 1 FROM crm_property_capturer_assignments WHERE property_id = p_property_id AND broker_id = auth.uid()) THEN
    v_is_authorized := true;
  ELSIF EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin' AND (email ILIKE 'crmsoniaallyson@gmail.com' OR email ILIKE 'unassigned-institutional@example.invalid')) THEN
    v_is_authorized := true;
  END IF;

  IF NOT v_is_authorized THEN
    RAISE EXCEPTION 'Não autorizado a gerar PDF para este imóvel.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('reserve_pdf:' || p_property_id));

  PERFORM 1 FROM public.crm_property_authorizations
  WHERE property_id = p_property_id
  FOR UPDATE;

  DECLARE
    v_existing_reserved record;
  BEGIN
    SELECT * INTO v_existing_reserved
    FROM crm_property_authorization_pdfs
    WHERE property_id = p_property_id AND status = 'RESERVED'
    LIMIT 1;

    IF FOUND THEN
      IF v_existing_reserved.generated_by = auth.uid() THEN
        RETURN jsonb_build_object('id', v_existing_reserved.id, 'version', v_existing_reserved.version_number, 'storage_path', v_existing_reserved.storage_path);
      ELSE
        RAISE EXCEPTION 'Geração em andamento por outro usuário.';
      END IF;
    END IF;
  END;

  SELECT COALESCE(MAX(version_number), 0) + 1 INTO v_next_version
  FROM crm_property_authorization_pdfs
  WHERE property_id = p_property_id;

  v_storage_path := p_property_id || '/pdfs/v' || v_next_version || '_' || substr(md5(random()::text), 1, 8) || '.pdf';

  INSERT INTO crm_property_authorization_pdfs (property_id, generated_by, version_number, storage_path, status)
  VALUES (p_property_id, auth.uid(), v_next_version, v_storage_path, 'RESERVED')
  RETURNING id INTO v_res_id;

  RETURN jsonb_build_object('id', v_res_id, 'version', v_next_version, 'storage_path', v_storage_path);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public;

CREATE OR REPLACE FUNCTION public.finalize_property_authorization_pdf(p_property_id text, p_version integer, p_storage_path text)
RETURNS void AS $$
DECLARE
  v_started_at timestamptz;
  v_res record;
BEGIN
  IF NOT public.can_access_property_authorization(p_property_id, auth.uid()) THEN
    RAISE EXCEPTION 'Não autorizado a finalizar PDF para este imóvel.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM storage.objects
    WHERE bucket_id = 'property-authorizations'
      AND name = p_storage_path
      AND lower(coalesce(metadata->>'mimetype', '')) = 'application/pdf'
  ) THEN
    RAISE EXCEPTION 'Arquivo PDF válido não encontrado no storage.';
  END IF;

  IF p_storage_path NOT LIKE p_property_id || '/pdfs/v' || p_version || '\_%' ESCAPE '\' THEN
    RAISE EXCEPTION 'Caminho de armazenamento inválido ou não corresponde à versão.';
  END IF;

  IF right(p_storage_path, 4) != '.pdf' THEN
    RAISE EXCEPTION 'O arquivo deve possuir extensão .pdf.';
  END IF;

  SELECT * INTO v_res FROM crm_property_authorization_pdfs
  WHERE property_id = p_property_id
    AND version_number = p_version
    AND storage_path = p_storage_path
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reserva não encontrada.';
  END IF;

  IF v_res.status != 'RESERVED' THEN
    RAISE EXCEPTION 'Reserva inválida ou já finalizada.';
  END IF;

  IF v_res.generated_by != auth.uid() THEN
    RAISE EXCEPTION 'Somente o criador da reserva pode finalizá-la.';
  END IF;

  UPDATE crm_property_authorization_pdfs
  SET status = 'FINALIZED', generated_at = now()
  WHERE id = v_res.id;

  SELECT authorization_started_at INTO v_started_at
  FROM crm_property_authorizations
  WHERE property_id = p_property_id;

  IF v_started_at IS NULL THEN
    UPDATE crm_property_authorizations
    SET authorization_started_at = now(), updated_at = now()
    WHERE property_id = p_property_id;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public;
ALTER TABLE public.crm_property_authorization_pdfs ENABLE ROW LEVEL SECURITY;


CREATE POLICY "Insert PDFs bloqueado, use RPC"
ON public.crm_property_authorization_pdfs FOR INSERT
TO authenticated
WITH CHECK (false);

-- 4. Notificação de Propriedade Pendente
CREATE OR REPLACE FUNCTION notify_allyson_pending_property()
RETURNS trigger AS $$
BEGIN
  IF NEW.registration_phase = 'PENDING' AND (TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND OLD.registration_phase IS DISTINCT FROM 'PENDING')) THEN
    INSERT INTO crm_notification_outbox (recipient_id, kind, title, body, url, payload)
    SELECT
      id,
      'property_pending',
      'Novo imóvel pendente de cadastro!',
      'O imóvel "' || NEW.title || '" foi cadastrado e aguarda finalização.',
      '/imoveis?focusPropertyId=' || NEW.external_id,
      jsonb_build_object('propertyId', NEW.external_id)
    FROM profiles
    WHERE email ILIKE 'crmsoniaallyson@gmail.com';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public;

DROP TRIGGER IF EXISTS trg_notify_allyson_pending_property ON public.crm_property_catalog;
CREATE TRIGGER trg_notify_allyson_pending_property
AFTER INSERT OR UPDATE ON public.crm_property_catalog
FOR EACH ROW
EXECUTE FUNCTION notify_allyson_pending_property();

-- 5. Lembretes e Job (crm_authorization_reminders_log)
CREATE TABLE IF NOT EXISTS public.crm_authorization_reminders_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id text REFERENCES public.crm_property_catalog(external_id) ON DELETE RESTRICT,
  days_remaining integer NOT NULL,
  sent_at timestamptz DEFAULT now(),
  UNIQUE (property_id, days_remaining)
);

-- Log interno: nenhuma leitura/escrita direta pelo cliente. A função SECURITY DEFINER do job continua operando.
ALTER TABLE public.crm_authorization_reminders_log ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION process_authorization_reminders()
RETURNS void AS $$
DECLARE
  rec RECORD;
  v_days_passed integer;
  v_days_remaining integer;
  v_reminder_target integer;
  v_author_id uuid;
BEGIN
  FOR rec IN
    SELECT a.property_id, a.authorization_started_at, c.title, a.submitted_by
    FROM crm_property_authorizations a
    JOIN crm_property_catalog c ON c.external_id = a.property_id
    WHERE a.authorization_started_at IS NOT NULL
  LOOP
    v_days_passed := TRUNC(EXTRACT(EPOCH FROM (now() - rec.authorization_started_at)) / 86400);
    v_days_remaining := 180 - v_days_passed;
    v_author_id := rec.submitted_by;

    FOREACH v_reminder_target IN ARRAY ARRAY[150, 120, 90, 60, 30, 0]
    LOOP
      IF v_days_remaining <= v_reminder_target THEN
        IF NOT EXISTS (
          SELECT 1 FROM crm_authorization_reminders_log
          WHERE property_id = rec.property_id AND days_remaining = v_reminder_target
        ) THEN
          -- Notify author
          INSERT INTO crm_notification_outbox (recipient_id, kind, title, body, url, payload)
          VALUES (
            v_author_id,
            'property_authorization_reminder',
            CASE WHEN v_reminder_target = 0 THEN 'Autorização Vencida!' ELSE 'Autorização vencendo em ' || v_reminder_target || ' dias' END,
            'O imóvel "' || rec.title || '" ' || CASE WHEN v_reminder_target = 0 THEN 'está com a autorização vencida.' ELSE 'vence em breve.' END,
            '/imoveis?focusPropertyId=' || rec.property_id,
            jsonb_build_object('propertyId', rec.property_id, 'daysRemaining', v_reminder_target)
          );

          -- Notify acessoCRM
          INSERT INTO crm_notification_outbox (recipient_id, kind, title, body, url, payload)
          SELECT
            id,
            'property_authorization_reminder',
            CASE WHEN v_reminder_target = 0 THEN 'Autorização Vencida!' ELSE 'Autorização vencendo em ' || v_reminder_target || ' dias' END,
            'O imóvel "' || rec.title || '" ' || CASE WHEN v_reminder_target = 0 THEN 'está com a autorização vencida.' ELSE 'vence em breve.' END,
            '/imoveis?focusPropertyId=' || rec.property_id,
            jsonb_build_object('propertyId', rec.property_id, 'daysRemaining', v_reminder_target)
          FROM profiles WHERE email ILIKE 'unassigned-institutional@example.invalid';

          -- Log it
          INSERT INTO crm_authorization_reminders_log (property_id, days_remaining)
          VALUES (rec.property_id, v_reminder_target);
        END IF;
      END IF;
    END LOOP;
  END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public;

-- Remove o job se existir para garantir idempotência
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'property_authorization_reminders_job') THEN
    PERFORM cron.unschedule('property_authorization_reminders_job');
  END IF;
END;
$$;

-- Job to run daily
SELECT cron.schedule('property_authorization_reminders_job', '0 6 * * *', 'SELECT public.process_authorization_reminders()');



-- 3. Transação Atômica da Fase 1 (Submissão Inicial)
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

    -- Validação de campos obrigatórios backend (Catálogo)
  IF p_catalog_data->>'title' IS NULL OR trim(p_catalog_data->>'title') = '' THEN
    RAISE EXCEPTION 'Endereço/Título do imóvel é obrigatório.';
  END IF;
  IF p_catalog_data->>'neighborhood' IS NULL OR trim(p_catalog_data->>'neighborhood') = '' THEN
    RAISE EXCEPTION 'Bairro é obrigatório.';
  END IF;
  IF p_catalog_data->>'city' IS NULL OR trim(p_catalog_data->>'city') = '' THEN
    RAISE EXCEPTION 'Cidade é obrigatória.';
  END IF;
  IF p_catalog_data->>'type' IS NULL OR trim(p_catalog_data->>'type') = '' THEN
    RAISE EXCEPTION 'Tipo do imóvel é obrigatório.';
  END IF;
  IF p_catalog_data->>'purpose' IS NULL OR trim(p_catalog_data->>'purpose') = '' THEN
    RAISE EXCEPTION 'Finalidade é obrigatória.';
  END IF;

  -- Validação de campos obrigatórios backend (Imóvel Autorização)
  IF p_auth_data->>'saldoDevedor' IS NULL OR trim(p_auth_data->>'saldoDevedor') = '' THEN RAISE EXCEPTION 'Saldo devedor é obrigatório.'; END IF;
  IF p_auth_data->>'valorPrestacao' IS NULL OR trim(p_auth_data->>'valorPrestacao') = '' THEN RAISE EXCEPTION 'Valor da prestação é obrigatório.'; END IF;
  IF p_auth_data->>'agenteFinanceiro' IS NULL OR trim(p_auth_data->>'agenteFinanceiro') = '' THEN RAISE EXCEPTION 'Agente financeiro é obrigatório.'; END IF;
  IF p_auth_data->>'metragem' IS NULL OR trim(p_auth_data->>'metragem') = '' THEN RAISE EXCEPTION 'Metragem é obrigatória.'; END IF;
  IF p_auth_data->>'valorPretendido' IS NULL OR trim(p_auth_data->>'valorPretendido') = '' THEN RAISE EXCEPTION 'Valor pretendido é obrigatório.'; END IF;
  IF p_auth_data->>'valorAvaliacao' IS NULL OR trim(p_auth_data->>'valorAvaliacao') = '' THEN RAISE EXCEPTION 'Valor de avaliação é obrigatório.'; END IF;
  IF p_auth_data->>'iptu' IS NULL OR trim(p_auth_data->>'iptu') = '' THEN RAISE EXCEPTION 'IPTU é obrigatório.'; END IF;
  IF p_auth_data->>'numeroInscricao' IS NULL OR trim(p_auth_data->>'numeroInscricao') = '' THEN RAISE EXCEPTION 'Número de inscrição é obrigatório.'; END IF;
  IF p_auth_data->>'vagasGaragem' IS NULL OR trim(p_auth_data->>'vagasGaragem') = '' THEN RAISE EXCEPTION 'Vagas de garagem é obrigatório.'; END IF;
  IF p_auth_data->>'administradoraCondominio' IS NULL OR trim(p_auth_data->>'administradoraCondominio') = '' THEN RAISE EXCEPTION 'Administradora do condomínio é obrigatória.'; END IF;
  IF p_auth_data->>'telefoneCondominio' IS NULL OR trim(p_auth_data->>'telefoneCondominio') = '' THEN RAISE EXCEPTION 'Telefone do condomínio é obrigatório.'; END IF;
  IF p_auth_data->>'valorCondominio' IS NULL OR trim(p_auth_data->>'valorCondominio') = '' THEN RAISE EXCEPTION 'Valor do condomínio é obrigatório.'; END IF;

  -- Validação Proprietário 1
  IF p_auth_data->>'prop1Nome' IS NULL OR trim(p_auth_data->>'prop1Nome') = '' THEN RAISE EXCEPTION 'Nome do proprietário 1 é obrigatório.'; END IF;
  IF p_auth_data->>'prop1Profissao' IS NULL OR trim(p_auth_data->>'prop1Profissao') = '' THEN RAISE EXCEPTION 'Profissão do proprietário 1 é obrigatória.'; END IF;
  IF p_auth_data->>'prop1EstadoCivil' IS NULL OR trim(p_auth_data->>'prop1EstadoCivil') = '' THEN RAISE EXCEPTION 'Estado civil do proprietário 1 é obrigatório.'; END IF;
  IF p_auth_data->>'prop1Cpf' IS NULL OR trim(p_auth_data->>'prop1Cpf') = '' THEN RAISE EXCEPTION 'CPF do proprietário 1 é obrigatório.'; END IF;
  IF p_auth_data->>'prop1CnhRg' IS NULL OR trim(p_auth_data->>'prop1CnhRg') = '' THEN RAISE EXCEPTION 'CNH/RG do proprietário 1 é obrigatório.'; END IF;
  IF p_auth_data->>'prop1OrgaoExpedidor' IS NULL OR trim(p_auth_data->>'prop1OrgaoExpedidor') = '' THEN RAISE EXCEPTION 'Órgão expedidor do proprietário 1 é obrigatório.'; END IF;
  IF p_auth_data->>'prop1Uf' IS NULL OR trim(p_auth_data->>'prop1Uf') = '' THEN RAISE EXCEPTION 'UF do proprietário 1 é obrigatório.'; END IF;
  IF p_auth_data->>'prop1Nacionalidade' IS NULL OR trim(p_auth_data->>'prop1Nacionalidade') = '' THEN RAISE EXCEPTION 'Nacionalidade do proprietário 1 é obrigatória.'; END IF;
  IF p_auth_data->>'prop1Telefone' IS NULL OR trim(p_auth_data->>'prop1Telefone') = '' THEN RAISE EXCEPTION 'Telefone do proprietário 1 é obrigatório.'; END IF;
  IF p_auth_data->>'prop1Email' IS NULL OR trim(p_auth_data->>'prop1Email') = '' THEN RAISE EXCEPTION 'Email do proprietário 1 é obrigatório.'; END IF;

  -- Validação Contratual
  IF p_auth_data->>'modalidade' IS NULL OR trim(p_auth_data->>'modalidade') = '' THEN RAISE EXCEPTION 'Modalidade é obrigatória.'; END IF;
  IF p_auth_data->>'observacoesCliente' IS NULL OR trim(p_auth_data->>'observacoesCliente') = '' THEN RAISE EXCEPTION 'Observações do cliente é obrigatório.'; END IF;
  IF p_auth_data->>'prazoClausula2' IS NULL OR trim(p_auth_data->>'prazoClausula2') = '' THEN RAISE EXCEPTION 'Prazo da cláusula 02 é obrigatório.'; END IF;
  IF trim(p_auth_data->>'prazoClausula2') !~ '^[0-9]+$' THEN RAISE EXCEPTION 'Prazo da cláusula 02 deve ser informado somente em dias numéricos.'; END IF;
  IF p_auth_data->>'honorariosClausula4Pct' IS NULL OR trim(p_auth_data->>'honorariosClausula4Pct') = '' THEN RAISE EXCEPTION 'Percentual da cláusula 04 é obrigatório.'; END IF;
  IF p_auth_data->>'regularizacaoStatus' IS NULL OR trim(p_auth_data->>'regularizacaoStatus') = '' THEN RAISE EXCEPTION 'Status de regularização é obrigatório.'; END IF;
  IF p_auth_data->>'escrituraStatus' IS NULL OR trim(p_auth_data->>'escrituraStatus') = '' THEN RAISE EXCEPTION 'Status de escritura é obrigatório.'; END IF;

  -- Validação Proprietário 2 (All or Nothing)
  IF (p_auth_data->>'prop2Nome' IS NOT NULL AND trim(p_auth_data->>'prop2Nome') <> '') OR
     (p_auth_data->>'prop2Profissao' IS NOT NULL AND trim(p_auth_data->>'prop2Profissao') <> '') OR
     (p_auth_data->>'prop2EstadoCivil' IS NOT NULL AND trim(p_auth_data->>'prop2EstadoCivil') <> '') OR
     (p_auth_data->>'prop2Cpf' IS NOT NULL AND trim(p_auth_data->>'prop2Cpf') <> '') OR
     (p_auth_data->>'prop2CnhRg' IS NOT NULL AND trim(p_auth_data->>'prop2CnhRg') <> '') OR
     (p_auth_data->>'prop2OrgaoExpedidor' IS NOT NULL AND trim(p_auth_data->>'prop2OrgaoExpedidor') <> '') OR
     (p_auth_data->>'prop2Uf' IS NOT NULL AND trim(p_auth_data->>'prop2Uf') <> '') OR
     (p_auth_data->>'prop2Nacionalidade' IS NOT NULL AND trim(p_auth_data->>'prop2Nacionalidade') <> '') OR
     (p_auth_data->>'prop2Telefone' IS NOT NULL AND trim(p_auth_data->>'prop2Telefone') <> '') OR
     (p_auth_data->>'prop2Email' IS NOT NULL AND trim(p_auth_data->>'prop2Email') <> '') THEN
    IF (p_auth_data->>'prop2Nome' IS NULL OR trim(p_auth_data->>'prop2Nome') = '') OR
       (p_auth_data->>'prop2Profissao' IS NULL OR trim(p_auth_data->>'prop2Profissao') = '') OR
       (p_auth_data->>'prop2EstadoCivil' IS NULL OR trim(p_auth_data->>'prop2EstadoCivil') = '') OR
       (p_auth_data->>'prop2Cpf' IS NULL OR trim(p_auth_data->>'prop2Cpf') = '') OR
       (p_auth_data->>'prop2CnhRg' IS NULL OR trim(p_auth_data->>'prop2CnhRg') = '') OR
       (p_auth_data->>'prop2OrgaoExpedidor' IS NULL OR trim(p_auth_data->>'prop2OrgaoExpedidor') = '') OR
       (p_auth_data->>'prop2Uf' IS NULL OR trim(p_auth_data->>'prop2Uf') = '') OR
       (p_auth_data->>'prop2Nacionalidade' IS NULL OR trim(p_auth_data->>'prop2Nacionalidade') = '') OR
       (p_auth_data->>'prop2Telefone' IS NULL OR trim(p_auth_data->>'prop2Telefone') = '') OR
       (p_auth_data->>'prop2Email' IS NULL OR trim(p_auth_data->>'prop2Email') = '') THEN
      RAISE EXCEPTION 'Se o segundo proprietário for informado, todos os seus dados (nome, profissão, estado civil, CPF, RG, órgão expedidor, UF, nacionalidade, telefone, email) são obrigatórios.';
    END IF;
  END IF;

  -- 1. Inserir Catálogo (Forçar PENDING)
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
    p_catalog_data->>'title',
    COALESCE(p_catalog_data->>'address', p_catalog_data->>'title'),
    p_catalog_data->>'neighborhood',
    p_catalog_data->>'city',
    p_catalog_data->>'type',
    p_catalog_data->>'purpose',
    COALESCE((p_catalog_data->>'value')::numeric, 0),
    p_catalog_data->>'ownerName',
    COALESCE(p_catalog_data->>'status', 'Ativo'),
    COALESCE((p_catalog_data->>'hasPhotos')::boolean, false),
    auth.uid(),
    'PENDING',
    p_auth_data->>'modalidade',
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
    (p_auth_data->>'saldoDevedor')::numeric,
    (p_auth_data->>'valorPrestacao')::numeric,
    p_auth_data->>'agenteFinanceiro',
    (p_auth_data->>'metragem')::numeric,
    (p_auth_data->>'valorPretendido')::numeric,
    (p_auth_data->>'valorAvaliacao')::numeric,
    (p_auth_data->>'iptu')::numeric,
    p_auth_data->>'numeroInscricao',
    (p_auth_data->>'vagasGaragem')::integer,
    p_auth_data->>'administradoraCondominio',
    p_auth_data->>'telefoneCondominio',
    (p_auth_data->>'valorCondominio')::numeric,
    p_auth_data->>'prop1Nome',
    p_auth_data->>'prop1Profissao',
    p_auth_data->>'prop1EstadoCivil',
    p_auth_data->>'prop1Cpf',
    p_auth_data->>'prop1CnhRg',
    p_auth_data->>'prop1OrgaoExpedidor',
    p_auth_data->>'prop1Uf',
    p_auth_data->>'prop1Nacionalidade',
    p_auth_data->>'prop1Telefone',
    p_auth_data->>'prop1Email',
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
    p_auth_data->>'modalidade',
    p_auth_data->>'observacoesCliente',
    p_auth_data->>'prazoClausula2',
    (p_auth_data->>'honorariosClausula4Pct')::numeric,
    p_auth_data->>'regularizacaoStatus',
    p_auth_data->>'escrituraStatus',
    p_auth_data->>'observacoesProprietario',
    p_auth_data->>'informacoesRelevantes',
    now()
  );

  -- 3. Inserir Document Responsibilities
  INSERT INTO public.crm_property_document_responsibilities (
    external_id, title, updated_at
  ) VALUES (
    p_external_id, p_catalog_data->>'title', now()
  );

  -- 4. Inserir Captador
  INSERT INTO public.crm_property_capturer_assignments (
    property_id, broker_id, broker_name, set_by, created_at, updated_at
  ) VALUES (
    p_external_id,
    p_capturer_id,
    (SELECT COALESCE(full_name, email) FROM public.profiles WHERE id = p_capturer_id),
    auth.uid(),
    now(),
    now()
  );

END;
$$;

-- 6. Atualizar can_read_property para permitir que autores e captadores vejam o imóvel
CREATE OR REPLACE FUNCTION public.can_read_property(p_property_id text)
RETURNS boolean AS $$
DECLARE
  v_role text;
BEGIN
  SELECT role INTO v_role FROM public.profiles WHERE id = auth.uid();

  IF v_role = 'admin' THEN
    RETURN true;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.crm_property_broker_access
    WHERE property_id = p_property_id AND broker_id = auth.uid()
  ) THEN
    RETURN true;
  END IF;

  IF public.can_access_property_authorization(p_property_id, auth.uid()) THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public;

REVOKE ALL ON FUNCTION public.can_read_property(text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.can_read_property(text) TO authenticated, service_role;

-- 6.A Após a submissão, gestão de corretores/captadores é exclusiva do Allyson.
-- Isso também fecha os caminhos históricos que permitiam alterações pelo AcessoCRM.
CREATE OR REPLACE FUNCTION public.can_manage_property_brokers()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT public.is_allyson_admin();
$$;

REVOKE ALL ON FUNCTION public.can_manage_property_brokers() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.can_manage_property_brokers() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.set_property_capturers(
  p_property_id text,
  p_selections text[]
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  normalized_property_id text := nullif(trim(p_property_id), '');
  normalized_selections text[];
  selection text;
  selected_profile public.profiles%rowtype;
  selected_ids uuid[] := '{}'::uuid[];
BEGIN
  IF NOT public.can_manage_property_brokers() THEN
    RAISE EXCEPTION 'Somente Allyson pode selecionar os captadores.';
  END IF;

  IF normalized_property_id IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.crm_property_catalog AS catalog
    WHERE catalog.external_id = normalized_property_id
  ) THEN
    RAISE EXCEPTION 'Imóvel não encontrado no catálogo.';
  END IF;

  SELECT array_agg(trim(item) ORDER BY ordinal)
  INTO normalized_selections
  FROM unnest(coalesce(p_selections, '{}'::text[])) WITH ORDINALITY AS input(item, ordinal)
  WHERE nullif(trim(item), '') IS NOT NULL;

  IF coalesce(cardinality(normalized_selections), 0) NOT BETWEEN 1 AND 2 THEN
    RAISE EXCEPTION 'Selecione um ou dois captadores.';
  END IF;
  IF cardinality(normalized_selections) = 2
     AND normalized_selections[1] = normalized_selections[2] THEN
    RAISE EXCEPTION 'Escolha dois captadores diferentes.';
  END IF;

  FOREACH selection IN ARRAY normalized_selections LOOP
    selected_profile := NULL;
    IF selection = '__sonialima__' THEN
      SELECT profile.*
      INTO selected_profile
      FROM public.profiles AS profile
      WHERE profile.role = 'admin'
        AND lower(trim(profile.email)) = 'unassigned-institutional@example.invalid';
    ELSE
      BEGIN
        SELECT profile.*
        INTO selected_profile
        FROM public.profiles AS profile
        WHERE profile.id = selection::uuid
          AND profile.role = 'broker';
      EXCEPTION WHEN invalid_text_representation THEN
        RAISE EXCEPTION 'Captador inválido.';
      END;
    END IF;

    IF selected_profile.id IS NULL THEN
      RAISE EXCEPTION 'Captador inválido.';
    END IF;
    IF selected_profile.id = ANY(selected_ids) THEN
      RAISE EXCEPTION 'Escolha dois captadores diferentes.';
    END IF;
    selected_ids := array_append(selected_ids, selected_profile.id);
  END LOOP;

  DELETE FROM public.crm_property_capturer_assignments AS assignment
  WHERE assignment.property_id = normalized_property_id;

  INSERT INTO public.crm_property_capturer_assignments (
    property_id, broker_id, broker_name, is_institutional, set_by
  )
  SELECT
    normalized_property_id,
    profile.id,
    CASE
      WHEN lower(trim(profile.email)) = 'unassigned-institutional@example.invalid' THEN 'SoniaLima'
      ELSE coalesce(nullif(trim(profile.full_name), ''), profile.email)
    END,
    false,
    auth.uid()
  FROM public.profiles AS profile
  WHERE profile.id = ANY(selected_ids);
END;
$$;

REVOKE ALL ON FUNCTION public.set_property_capturers(text, text[]) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.set_property_capturers(text, text[]) TO authenticated;

-- 6.B Durante a fase PENDING, os demais campos administrativos ficam exclusivos do Allyson.
-- Para imóveis já COMPLETED, preservam-se as permissões históricas do CRM.
CREATE OR REPLACE FUNCTION public.set_property_reviewability(
  p_property_id text,
  p_reviewable boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF auth.uid() IS NULL OR public.is_restricted_admin() THEN
    RAISE EXCEPTION 'Seu acesso não permite alterar esta classificação.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.crm_property_catalog
    WHERE external_id = p_property_id AND registration_phase = 'PENDING'
  ) AND NOT public.is_allyson_admin() THEN
    RAISE EXCEPTION 'Somente Allyson pode alterar dados administrativos de um imóvel pendente de cadastro.';
  END IF;

  INSERT INTO public.crm_property_reviewability (
    property_id, reviewable, updated_by, updated_at
  ) VALUES (
    p_property_id, coalesce(p_reviewable, false), auth.uid(), now()
  )
  ON CONFLICT (property_id) DO UPDATE SET
    reviewable = excluded.reviewable,
    updated_by = excluded.updated_by,
    updated_at = excluded.updated_at;
END;
$$;

REVOKE ALL ON FUNCTION public.set_property_reviewability(text, boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.set_property_reviewability(text, boolean) TO authenticated;

CREATE OR REPLACE FUNCTION public.sync_property_public_link(
  p_property_id text,
  p_url text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  normalized_url text := trim(coalesce(p_url, ''));
BEGIN
  IF auth.uid() IS NULL OR public.is_restricted_admin() THEN
    RAISE EXCEPTION 'Seu acesso não permite editar o link do imóvel.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.crm_property_catalog
    WHERE external_id = p_property_id AND registration_phase = 'PENDING'
  ) AND NOT public.is_allyson_admin() THEN
    RAISE EXCEPTION 'Somente Allyson pode alterar dados administrativos de um imóvel pendente de cadastro.';
  END IF;

  IF normalized_url = '' THEN
    DELETE FROM public.crm_property_public_links
    WHERE property_id = p_property_id;
    RETURN;
  END IF;

  IF normalized_url !~* '^https?://' THEN
    RAISE EXCEPTION 'Informe um link completo iniciado por http:// ou https://.';
  END IF;

  INSERT INTO public.crm_property_public_links (property_id, url, updated_by, updated_at)
  VALUES (p_property_id, normalized_url, auth.uid(), now())
  ON CONFLICT (property_id) DO UPDATE SET
    url = excluded.url,
    updated_by = excluded.updated_by,
    updated_at = excluded.updated_at;
END;
$$;

REVOKE ALL ON FUNCTION public.sync_property_public_link(text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.sync_property_public_link(text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.sync_property_portal_references(
  p_property_id text,
  p_wimoveis_listing_id text,
  p_dfimoveis_listing_id text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  caller_email text;
  caller_is_allyson boolean := public.is_allyson_admin();
  normalized_property_id text := nullif(trim(p_property_id), '');
  normalized_wimoveis_id text := nullif(trim(p_wimoveis_listing_id), '');
  normalized_dfimoveis_id text := nullif(trim(p_dfimoveis_listing_id), '');
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Sessão não encontrada.';
  END IF;

  SELECT lower(trim(profile.email)) INTO caller_email
  FROM public.profiles AS profile
  WHERE profile.id = auth.uid();

  IF normalized_property_id IS NULL THEN
    RAISE EXCEPTION 'Identificador do imóvel é obrigatório.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.crm_property_catalog
    WHERE external_id = normalized_property_id AND registration_phase = 'PENDING'
  ) AND NOT caller_is_allyson THEN
    RAISE EXCEPTION 'Somente Allyson pode alterar códigos de anúncios de um imóvel pendente de cadastro.';
  END IF;

  IF NOT caller_is_allyson AND caller_email NOT IN (
    'crmthiago@sonialima.com.br', 'unassigned-operator@example.invalid'
  ) THEN
    RAISE EXCEPTION 'Somente Allyson, Thiago e Vitor podem alterar códigos de anúncios.';
  END IF;

  IF NOT caller_is_allyson AND EXISTS (
    SELECT 1 FROM public.crm_property_portal_references AS reference
    WHERE reference.property_id <> normalized_property_id AND (
      (reference.portal = 'wimoveis' AND reference.external_listing_id = normalized_wimoveis_id)
      OR (reference.portal = 'dfimoveis' AND reference.external_listing_id = normalized_dfimoveis_id)
    )
  ) THEN
    RAISE EXCEPTION 'Um dos códigos informados já pertence a outro imóvel.';
  END IF;

  DELETE FROM public.crm_property_portal_references AS reference
  WHERE reference.property_id = normalized_property_id
    AND reference.portal IN ('wimoveis', 'dfimoveis');

  IF caller_is_allyson THEN
    INSERT INTO public.crm_property_portal_references(portal, external_listing_id, property_id)
    SELECT portal, external_listing_id, normalized_property_id
    FROM (VALUES
      ('wimoveis'::text, normalized_wimoveis_id),
      ('dfimoveis'::text, normalized_dfimoveis_id)
    ) AS codes(portal, external_listing_id)
    WHERE external_listing_id IS NOT NULL
    ON CONFLICT (portal, external_listing_id) DO UPDATE
      SET property_id = excluded.property_id, updated_at = now();
  ELSE
    INSERT INTO public.crm_property_portal_references(portal, external_listing_id, property_id)
    SELECT portal, external_listing_id, normalized_property_id
    FROM (VALUES
      ('wimoveis'::text, normalized_wimoveis_id),
      ('dfimoveis'::text, normalized_dfimoveis_id)
    ) AS codes(portal, external_listing_id)
    WHERE external_listing_id IS NOT NULL
    ON CONFLICT (portal, external_listing_id) DO NOTHING;

    IF normalized_wimoveis_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.crm_property_portal_references AS reference
      WHERE reference.portal = 'wimoveis'
        AND reference.external_listing_id = normalized_wimoveis_id
        AND reference.property_id = normalized_property_id
    ) THEN
      RAISE EXCEPTION 'O código W Imóveis informado já pertence a outro imóvel.';
    END IF;

    IF normalized_dfimoveis_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.crm_property_portal_references AS reference
      WHERE reference.portal = 'dfimoveis'
        AND reference.external_listing_id = normalized_dfimoveis_id
        AND reference.property_id = normalized_property_id
    ) THEN
      RAISE EXCEPTION 'O código DF Imóveis informado já pertence a outro imóvel.';
    END IF;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.sync_property_portal_references(text, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.sync_property_portal_references(text, text, text) TO authenticated;

-- RPC para finalizar sessão de envio de documentos
CREATE OR REPLACE FUNCTION public.finalize_initial_documents(p_property_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.crm_property_authorizations
    WHERE property_id = p_property_id AND submitted_by = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Apenas o corretor que criou a ficha pode finalizar o envio de documentos originais.';
  END IF;

  UPDATE public.crm_property_authorizations
  SET initial_documents_finalized_at = now()
  WHERE property_id = p_property_id AND initial_documents_finalized_at IS NULL;
END;
$$;

-- 7. Revoke and Grant Security for all RPCs
REVOKE ALL ON FUNCTION public.can_access_property_authorization(text, uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.can_access_property_authorization(text, uuid) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.set_sonialima_property_exclusivity(text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.set_sonialima_property_exclusivity(text, text) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.reserve_property_authorization_pdf(text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.reserve_property_authorization_pdf(text) TO authenticated;

REVOKE ALL ON FUNCTION public.finalize_property_authorization_pdf(text, integer, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.finalize_property_authorization_pdf(text, integer, text) TO authenticated;

REVOKE ALL ON FUNCTION public.process_authorization_reminders() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.process_authorization_reminders() TO service_role;

REVOKE ALL ON FUNCTION public.submit_property_authorization_phase1(text, jsonb, jsonb, uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.submit_property_authorization_phase1(text, jsonb, jsonb, uuid) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.finalize_initial_documents(text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.finalize_initial_documents(text) TO authenticated;


CREATE OR REPLACE FUNCTION public.get_property_capturer_details(p_property_id text)
RETURNS TABLE(name text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NOT public.can_access_property_authorization(p_property_id, auth.uid()) THEN
    RAISE EXCEPTION 'Acesso negado.';
  END IF;

  RETURN QUERY
  SELECT COALESCE(NULLIF(p.full_name, ''), NULLIF(a.broker_name, ''), p.email)::text
  FROM public.crm_property_capturer_assignments AS a
  LEFT JOIN public.profiles AS p ON p.id = a.broker_id
  WHERE a.property_id = p_property_id
  ORDER BY a.created_at ASC
  LIMIT 1;
END;
$$;
REVOKE ALL ON FUNCTION public.get_property_capturer_details(text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_property_capturer_details(text) TO authenticated, service_role;

-- Policies for crm_property_authorization_pdfs
ALTER TABLE public.crm_property_authorization_pdfs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Select PDFs para os 4 perfis" ON public.crm_property_authorization_pdfs;
ALTER TABLE public.crm_property_authorization_pdfs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Enable read access for permitted users" ON public.crm_property_authorization_pdfs;
CREATE POLICY "Enable read access for permitted users"
ON public.crm_property_authorization_pdfs
FOR SELECT
TO authenticated
USING (public.can_access_property_authorization(property_id, auth.uid()));

DROP POLICY IF EXISTS "Block direct inserts" ON public.crm_property_authorization_pdfs;
CREATE POLICY "Block direct inserts"
ON public.crm_property_authorization_pdfs
FOR INSERT
TO authenticated
WITH CHECK (false);

DROP POLICY IF EXISTS "Block direct updates" ON public.crm_property_authorization_pdfs;
CREATE POLICY "Block direct updates"
ON public.crm_property_authorization_pdfs
FOR UPDATE
TO authenticated
USING (false);

DROP POLICY IF EXISTS "Block direct deletes" ON public.crm_property_authorization_pdfs;
CREATE POLICY "Block direct deletes"
ON public.crm_property_authorization_pdfs
FOR DELETE
TO authenticated
USING (false);

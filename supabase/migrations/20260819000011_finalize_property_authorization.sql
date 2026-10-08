-- ETAPA 3: 20260819000011_finalize_property_authorization.sql
-- Consolidação Idempotente da Autorização de Venda
-- Não recria tabelas do zero para evitar colisão com schema remoto existente. Adiciona colunas se faltarem e atualiza todo o resto (functions, RLS, triggers, storage).

-- 1. Modificar crm_property_catalog (Idempotente: ADD COLUMN IF NOT EXISTS)
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

-- 1.1 Bloquear INSERT indiscriminado na crm_property_catalog
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


-- 2. Tabela crm_property_authorizations (Captação) - Assegurando existência com CREATE e adicionando colunas com ALTER
CREATE TABLE IF NOT EXISTS public.crm_property_authorizations (
    property_id text PRIMARY KEY REFERENCES public.crm_property_catalog(external_id) ON DELETE RESTRICT,
    submitted_by uuid REFERENCES auth.users(id) NOT NULL
);

ALTER TABLE public.crm_property_authorizations
    ADD COLUMN IF NOT EXISTS authorization_started_at timestamptz,
    ADD COLUMN IF NOT EXISTS initial_documents_finalized_at timestamptz,
    ADD COLUMN IF NOT EXISTS saldo_devedor numeric DEFAULT 0 NOT NULL,
    ADD COLUMN IF NOT EXISTS valor_prestacao numeric DEFAULT 0 NOT NULL,
    ADD COLUMN IF NOT EXISTS agente_financeiro text DEFAULT '' NOT NULL,
    ADD COLUMN IF NOT EXISTS metragem numeric DEFAULT 0 NOT NULL,
    ADD COLUMN IF NOT EXISTS valor_pretendido numeric DEFAULT 0 NOT NULL,
    ADD COLUMN IF NOT EXISTS valor_avaliacao numeric DEFAULT 0 NOT NULL,
    ADD COLUMN IF NOT EXISTS iptu numeric DEFAULT 0 NOT NULL,
    ADD COLUMN IF NOT EXISTS numero_inscricao text DEFAULT '' NOT NULL,
    ADD COLUMN IF NOT EXISTS vagas_garagem integer DEFAULT 0 NOT NULL,
    ADD COLUMN IF NOT EXISTS administradora_condominio text DEFAULT '' NOT NULL,
    ADD COLUMN IF NOT EXISTS telefone_condominio text DEFAULT '' NOT NULL,
    ADD COLUMN IF NOT EXISTS valor_condominio numeric DEFAULT 0 NOT NULL,
    ADD COLUMN IF NOT EXISTS prop1_nome text DEFAULT '' NOT NULL,
    ADD COLUMN IF NOT EXISTS prop1_profissao text DEFAULT '' NOT NULL,
    ADD COLUMN IF NOT EXISTS prop1_estado_civil text DEFAULT '' NOT NULL,
    ADD COLUMN IF NOT EXISTS prop1_cpf text DEFAULT '' NOT NULL,
    ADD COLUMN IF NOT EXISTS prop1_cnh_rg text DEFAULT '' NOT NULL,
    ADD COLUMN IF NOT EXISTS prop1_orgao_expedidor text DEFAULT '' NOT NULL,
    ADD COLUMN IF NOT EXISTS prop1_uf text DEFAULT '' NOT NULL,
    ADD COLUMN IF NOT EXISTS prop1_nacionalidade text DEFAULT '' NOT NULL,
    ADD COLUMN IF NOT EXISTS prop1_telefone text DEFAULT '' NOT NULL,
    ADD COLUMN IF NOT EXISTS prop1_email text DEFAULT '' NOT NULL,
    ADD COLUMN IF NOT EXISTS prop2_nome text,
    ADD COLUMN IF NOT EXISTS prop2_profissao text,
    ADD COLUMN IF NOT EXISTS prop2_estado_civil text,
    ADD COLUMN IF NOT EXISTS prop2_cpf text,
    ADD COLUMN IF NOT EXISTS prop2_cnh_rg text,
    ADD COLUMN IF NOT EXISTS prop2_orgao_expedidor text,
    ADD COLUMN IF NOT EXISTS prop2_uf text,
    ADD COLUMN IF NOT EXISTS prop2_nacionalidade text,
    ADD COLUMN IF NOT EXISTS prop2_telefone text,
    ADD COLUMN IF NOT EXISTS prop2_email text,
    ADD COLUMN IF NOT EXISTS modalidade text DEFAULT 'Sem termo de autorização' NOT NULL CHECK (modalidade IN ('Com exclusividade', 'Termo sem exclusividade', 'Sem termo de autorização')),
    ADD COLUMN IF NOT EXISTS observacoes_cliente text DEFAULT '' NOT NULL,
    ADD COLUMN IF NOT EXISTS prazo_clausula_2 text DEFAULT '0' NOT NULL,
    ADD COLUMN IF NOT EXISTS honorarios_clausula_4_pct numeric DEFAULT 0 NOT NULL,
    ADD COLUMN IF NOT EXISTS regularizacao_status text DEFAULT 'Não regularizado' NOT NULL CHECK (regularizacao_status IN ('Regularizado', 'Não regularizado')),
    ADD COLUMN IF NOT EXISTS escritura_status text DEFAULT 'Sem escritura' NOT NULL CHECK (escritura_status IN ('Com escritura', 'Sem escritura')),
    ADD COLUMN IF NOT EXISTS observacoes_proprietario text,
    ADD COLUMN IF NOT EXISTS informacoes_relevantes text,
    ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now(),
    ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();

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

DROP POLICY IF EXISTS "Visibilidade privada autenticada para autorizações" ON public.crm_property_authorizations;
CREATE POLICY "Visibilidade privada autenticada para autorizações"
ON public.crm_property_authorizations FOR SELECT
TO authenticated
USING (
  public.can_access_property_authorization(property_id, auth.uid())
);

DROP POLICY IF EXISTS "Apenas Allyson pode editar autorizações" ON public.crm_property_authorizations;
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

DROP POLICY IF EXISTS "Insert for authorized CRM roles authorizations" ON public.crm_property_authorizations;
CREATE POLICY "Insert for authorized CRM roles authorizations"
ON public.crm_property_authorizations FOR INSERT
TO authenticated
WITH CHECK (false);

-- 3. Versionamento de PDFs (crm_property_authorization_pdfs)
CREATE TABLE IF NOT EXISTS public.crm_property_authorization_pdfs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id text REFERENCES public.crm_property_catalog(external_id) ON DELETE RESTRICT,
  generated_by uuid REFERENCES auth.users(id) NOT NULL
);

ALTER TABLE public.crm_property_authorization_pdfs
  ADD COLUMN IF NOT EXISTS generated_at timestamptz DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS version_number integer DEFAULT 1 NOT NULL,
  ADD COLUMN IF NOT EXISTS storage_path text DEFAULT '' NOT NULL,
  ADD COLUMN IF NOT EXISTS status text DEFAULT 'RESERVED' CHECK (status IN ('RESERVED', 'FINALIZED'));

-- Adicionando CONSTRAINT se não existir
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'crm_property_authorization_pdfs_property_id_version_number_key'
  ) THEN
    ALTER TABLE public.crm_property_authorization_pdfs ADD CONSTRAINT crm_property_authorization_pdfs_property_id_version_number_key UNIQUE (property_id, version_number);
  END IF;
END $$;


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

DROP POLICY IF EXISTS "Insert PDFs bloqueado, use RPC" ON public.crm_property_authorization_pdfs;
CREATE POLICY "Insert PDFs bloqueado, use RPC"
ON public.crm_property_authorization_pdfs FOR INSERT
TO authenticated
WITH CHECK (false);

-- Políticas finais na crm_property_authorization_pdfs
DROP POLICY IF EXISTS "Select PDFs para os 4 perfis" ON public.crm_property_authorization_pdfs;
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
  property_id text REFERENCES public.crm_property_catalog(external_id) ON DELETE RESTRICT
);

ALTER TABLE public.crm_authorization_reminders_log
  ADD COLUMN IF NOT EXISTS days_remaining integer DEFAULT 0 NOT NULL,
  ADD COLUMN IF NOT EXISTS sent_at timestamptz DEFAULT now();

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'crm_authorization_reminders_log_property_id_days_remaining_key'
  ) THEN
    ALTER TABLE public.crm_authorization_reminders_log ADD CONSTRAINT crm_authorization_reminders_log_property_id_days_remaining_key UNIQUE (property_id, days_remaining);
  END IF;
END $$;

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


-- 6. Storage Policies
INSERT INTO storage.buckets (id, name, public)
VALUES ('property-authorizations', 'property-authorizations', false)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "property_auth_select" ON storage.objects;
CREATE POLICY "property_auth_select"
ON storage.objects FOR SELECT
TO authenticated
USING (
  bucket_id = 'property-authorizations' AND
  public.can_access_property_authorization(split_part(name, '/', 1), auth.uid())
);

DROP POLICY IF EXISTS "property_auth_insert_pdf" ON storage.objects;
CREATE POLICY "property_auth_insert_pdf"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'property-authorizations' AND
  split_part(name, '/', 2) = 'pdfs' AND
  right(lower(name), 4) = '.pdf' AND
  lower(coalesce(metadata->>'mimetype', '')) = 'application/pdf' AND
  EXISTS (
    SELECT 1 FROM public.crm_property_authorization_pdfs
    WHERE storage_path = name
      AND generated_by = auth.uid()
      AND status = 'RESERVED'
  )
);

DROP POLICY IF EXISTS "property_auth_insert_original" ON storage.objects;
CREATE POLICY "property_auth_insert_original"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'property-authorizations' AND
  split_part(name, '/', 2) != 'pdfs' AND (
    (
      EXISTS (
        SELECT 1 FROM public.crm_property_authorizations a
        WHERE a.property_id = split_part(name, '/', 1)
        AND a.submitted_by = auth.uid()
        AND a.initial_documents_finalized_at IS NULL
      )
    ) OR (
      EXISTS (
        SELECT 1 FROM public.profiles
        WHERE id = auth.uid() AND role = 'admin' AND email ilike 'crmsoniaallyson@gmail.com'
      )
    )
  )
);

DROP POLICY IF EXISTS "property_auth_update_original" ON storage.objects;
CREATE POLICY "property_auth_update_original"
ON storage.objects FOR UPDATE
TO authenticated
USING (
  bucket_id = 'property-authorizations' AND
  split_part(name, '/', 2) != 'pdfs' AND
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role = 'admin' AND email ilike 'crmsoniaallyson@gmail.com'
  )
);

DROP POLICY IF EXISTS "property_auth_delete_original" ON storage.objects;
CREATE POLICY "property_auth_delete_original"
ON storage.objects FOR DELETE
TO authenticated
USING (
  bucket_id = 'property-authorizations' AND
  split_part(name, '/', 2) != 'pdfs' AND
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role = 'admin' AND email ilike 'crmsoniaallyson@gmail.com'
  )
);

-- Revoke/Grant permissões essenciais
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

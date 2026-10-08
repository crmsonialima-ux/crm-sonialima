-- Quatro estados operacionais do ranking: três respostas e NULL (pendente/zero ponto).
ALTER TABLE public.crm_property_catalog
  DROP CONSTRAINT IF EXISTS crm_property_catalog_sonialima_exclusivity_control_check;

ALTER TABLE public.crm_property_catalog
  ADD CONSTRAINT crm_property_catalog_sonialima_exclusivity_control_check
  CHECK (
    sonialima_exclusivity_control IS NULL
    OR sonialima_exclusivity_control IN (
      'COM EXCLUSIVIDADE',
      'SEM EXCLUSIVIDADE',
      'SEM AUTORIZACAO DE VENDA'
    )
  );

CREATE OR REPLACE FUNCTION public.protect_sonialima_exclusivity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NEW.sonialima_exclusivity_control IS DISTINCT FROM OLD.sonialima_exclusivity_control THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.profiles
      WHERE id = auth.uid()
        AND role = 'admin'
        AND lower(trim(email)) = 'crmsoniaallyson@gmail.com'
    ) THEN
      RAISE EXCEPTION 'Somente Allyson pode definir a classificação do imóvel.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.set_sonialima_property_exclusivity(
  p_property_id text,
  p_exclusivity text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.profiles
    WHERE id = auth.uid()
      AND role = 'admin'
      AND lower(trim(email)) = 'crmsoniaallyson@gmail.com'
  ) THEN
    RAISE EXCEPTION 'Somente Allyson pode definir a classificação do imóvel.';
  END IF;

  IF p_exclusivity NOT IN (
    'COM EXCLUSIVIDADE',
    'SEM EXCLUSIVIDADE',
    'SEM AUTORIZACAO DE VENDA'
  ) THEN
    RAISE EXCEPTION 'Classificação inválida.';
  END IF;

  UPDATE public.crm_property_catalog
  SET sonialima_exclusivity_control = p_exclusivity
  WHERE external_id = p_property_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Imóvel não encontrado.';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.set_sonialima_property_exclusivity(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_sonialima_property_exclusivity(text, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_capture_ranking_rows()
RETURNS TABLE (
  broker_id uuid,
  broker_name text,
  broker_email text,
  property_id text,
  cadastrado_em timestamptz,
  titulo text,
  endereco text,
  valor numeric,
  status text,
  classificacao text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT
    profile.id,
    CASE
      WHEN lower(trim(profile.email)) = 'unassigned-institutional@example.invalid' THEN 'SoniaLima'
      ELSE coalesce(nullif(trim(profile.full_name), ''), profile.email)
    END::text,
    profile.email::text,
    assignment.property_id,
    coalesce(catalog.entered_at, catalog.created_at),
    catalog.title,
    catalog.address,
    catalog.value,
    catalog.status,
    catalog.sonialima_exclusivity_control
  FROM public.profiles AS profile
  LEFT JOIN public.crm_property_capturer_assignments AS assignment
    ON assignment.broker_id = profile.id
  LEFT JOIN public.crm_property_catalog AS catalog
    ON catalog.external_id = assignment.property_id
  WHERE lower(trim(profile.email)) <> 'crmsoniaallyson@gmail.com'
    AND (
      profile.role = 'broker'
      OR lower(trim(profile.email)) = 'unassigned-institutional@example.invalid'
    )
  ORDER BY profile.full_name NULLS LAST, assignment.created_at;
$$;

REVOKE ALL ON FUNCTION public.get_capture_ranking_rows() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_capture_ranking_rows() TO authenticated, service_role;

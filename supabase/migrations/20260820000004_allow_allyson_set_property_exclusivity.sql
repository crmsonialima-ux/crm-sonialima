-- Allyson e a conta SoniaLima podem definir a exclusividade que alimenta o ranking de captação.
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
      AND lower(trim(email)) IN ('crmsoniaallyson@gmail.com', 'unassigned-institutional@example.invalid')
  ) THEN
    RAISE EXCEPTION 'Somente Allyson ou SoniaLima podem definir a exclusividade.';
  END IF;

  IF p_exclusivity NOT IN ('COM EXCLUSIVIDADE', 'SEM EXCLUSIVIDADE') THEN
    RAISE EXCEPTION 'Exclusividade inválida.';
  END IF;

  UPDATE public.crm_properties
  SET sonialima_exclusivity_control = p_exclusivity
  WHERE external_id = p_property_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Imóvel não encontrado.';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.set_sonialima_property_exclusivity(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_sonialima_property_exclusivity(text, text) TO authenticated, service_role;

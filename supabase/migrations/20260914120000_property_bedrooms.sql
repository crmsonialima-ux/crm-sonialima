begin;

-- NULL significa não informado, inclusive para os imóveis já cadastrados.
alter table public.crm_property_catalog
  add column bedrooms integer check (bedrooms >= 0);

comment on column public.crm_property_catalog.bedrooms is
  'Número de quartos. NULL = não informado; zero = imóvel sem quartos.';

-- Preserva as regras e correções da RPC instalada, incluindo os captadores.
do $$
declare
  definition text;
  updated_definition text;
begin
  select pg_get_functiondef(
    'public.submit_property_authorization_phase1(text,jsonb,jsonb,uuid)'::regprocedure
  ) into definition;

  updated_definition := regexp_replace(
    definition,
    '(INSERT INTO public[.]crm_property_catalog[[:space:]]*[(][[:space:]]*)external_id,',
    E'\\1bedrooms, external_id,'
  );
  if updated_definition is not distinct from definition then
    raise exception 'Não foi possível adicionar quartos às colunas da RPC de cadastro.';
  end if;

  definition := updated_definition;
  updated_definition := regexp_replace(
    definition,
    '([)][[:space:]]*VALUES[[:space:]]*[(][[:space:]]*)p_external_id,',
    E'\\1NULLIF(trim(p_catalog_data->>''bedrooms''), '''')::integer, p_external_id,'
  );
  if updated_definition is not distinct from definition then
    raise exception 'Não foi possível adicionar quartos aos valores da RPC de cadastro.';
  end if;

  execute updated_definition;
end;
$$;

notify pgrst, 'reload schema';
commit;

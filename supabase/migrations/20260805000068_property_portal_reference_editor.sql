-- Administradores podem editar qualquer referência de portal. Corretores podem
-- editar somente as referências dos imóveis aos quais já estão associados; a
-- lista de corretores autorizados continua exclusiva do administrador.
create or replace function public.sync_property_portal_references(
  p_property_id text,
  p_wimoveis_listing_id text,
  p_dfimoveis_listing_id text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller_is_admin boolean := public.is_admin();
  normalized_wimoveis_id text := nullif(trim(p_wimoveis_listing_id), '');
  normalized_dfimoveis_id text := nullif(trim(p_dfimoveis_listing_id), '');
begin
  if auth.uid() is null then
    raise exception 'Sessão não encontrada.';
  end if;
  if nullif(trim(p_property_id), '') is null then
    raise exception 'Identificador do imóvel é obrigatório.';
  end if;

  if not caller_is_admin and not exists (
    select 1
    from public.crm_property_broker_access access
    join public.profiles profile on profile.id = access.broker_id
    where access.property_id = trim(p_property_id)
      and access.broker_id = auth.uid()
      and profile.role = 'broker'
  ) then
    raise exception 'Você não pode editar os códigos de portal deste imóvel.';
  end if;

  -- Um corretor não pode tomar para seu imóvel um código já associado a outro.
  -- O administrador conserva a possibilidade de corrigir/reassociar códigos.
  if not caller_is_admin and exists (
    select 1
    from public.crm_property_portal_references reference
    where reference.property_id <> trim(p_property_id)
      and (
        (
          reference.portal = 'wimoveis'
          and reference.external_listing_id = normalized_wimoveis_id
        )
        or (
          reference.portal = 'dfimoveis'
          and reference.external_listing_id = normalized_dfimoveis_id
        )
      )
  ) then
    raise exception 'Um dos códigos informados já pertence a outro imóvel.';
  end if;

  delete from public.crm_property_portal_references
  where property_id = trim(p_property_id)
    and portal in ('wimoveis', 'dfimoveis');

  if caller_is_admin then
    insert into public.crm_property_portal_references (
      portal,
      external_listing_id,
      property_id
    )
    select portal, external_listing_id, trim(p_property_id)
    from (values
      ('wimoveis'::text, normalized_wimoveis_id),
      ('dfimoveis'::text, normalized_dfimoveis_id)
    ) as references_to_save(portal, external_listing_id)
    where external_listing_id is not null
    on conflict (portal, external_listing_id) do update
      set property_id = excluded.property_id,
          updated_at = now();
  else
    -- `do nothing` prevents a concurrent edit from remapping another property's
    -- code. The checks below turn that conflict into a clear, atomic error.
    insert into public.crm_property_portal_references (
      portal,
      external_listing_id,
      property_id
    )
    select portal, external_listing_id, trim(p_property_id)
    from (values
      ('wimoveis'::text, normalized_wimoveis_id),
      ('dfimoveis'::text, normalized_dfimoveis_id)
    ) as references_to_save(portal, external_listing_id)
    where external_listing_id is not null
    on conflict (portal, external_listing_id) do nothing;

    if normalized_wimoveis_id is not null and not exists (
      select 1
      from public.crm_property_portal_references reference
      where reference.portal = 'wimoveis'
        and reference.external_listing_id = normalized_wimoveis_id
        and reference.property_id = trim(p_property_id)
    ) then
      raise exception 'O código W Imóveis informado já pertence a outro imóvel.';
    end if;
    if normalized_dfimoveis_id is not null and not exists (
      select 1
      from public.crm_property_portal_references reference
      where reference.portal = 'dfimoveis'
        and reference.external_listing_id = normalized_dfimoveis_id
        and reference.property_id = trim(p_property_id)
    ) then
      raise exception 'O código DF Imóveis informado já pertence a outro imóvel.';
    end if;
  end if;
end;
$$;

revoke all on function public.sync_property_portal_references(text, text, text)
  from public, anon;
grant execute on function public.sync_property_portal_references(text, text, text)
  to authenticated;

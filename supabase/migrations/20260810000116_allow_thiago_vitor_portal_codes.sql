create or replace function public.sync_property_portal_references(
  p_property_id text,
  p_wimoveis_listing_id text,
  p_dfimoveis_listing_id text
)
returns void language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  caller_email text;
  caller_is_allyson boolean := public.is_allyson_admin();
  normalized_property_id text := nullif(trim(p_property_id), '');
  normalized_wimoveis_id text := nullif(trim(p_wimoveis_listing_id), '');
  normalized_dfimoveis_id text := nullif(trim(p_dfimoveis_listing_id), '');
begin
  if auth.uid() is null then raise exception 'Sessão não encontrada.'; end if;
  select lower(trim(profile.email)) into caller_email
  from public.profiles profile where profile.id=auth.uid();

  if not caller_is_allyson and caller_email not in (
    'crmthiago@sonialima.com.br', 'unassigned-operator@example.invalid'
  ) then raise exception 'Somente Allyson, Thiago e Vitor podem alterar códigos de anúncios.'; end if;
  if normalized_property_id is null then
    raise exception 'Identificador do imóvel é obrigatório.';
  end if;

  if not caller_is_allyson and exists (
    select 1 from public.crm_property_portal_references reference
    where reference.property_id<>normalized_property_id and (
      (reference.portal='wimoveis' and reference.external_listing_id=normalized_wimoveis_id)
      or (reference.portal='dfimoveis' and reference.external_listing_id=normalized_dfimoveis_id)
    )
  ) then raise exception 'Um dos códigos informados já pertence a outro imóvel.'; end if;

  delete from public.crm_property_portal_references reference
  where reference.property_id=normalized_property_id
    and reference.portal in ('wimoveis','dfimoveis');

  if caller_is_allyson then
    insert into public.crm_property_portal_references(portal,external_listing_id,property_id)
    select portal, external_listing_id, normalized_property_id
    from (values ('wimoveis'::text,normalized_wimoveis_id),
      ('dfimoveis'::text,normalized_dfimoveis_id)) codes(portal,external_listing_id)
    where external_listing_id is not null
    on conflict (portal,external_listing_id) do update
      set property_id=excluded.property_id,updated_at=now();
  else
    insert into public.crm_property_portal_references(portal,external_listing_id,property_id)
    select portal, external_listing_id, normalized_property_id
    from (values ('wimoveis'::text,normalized_wimoveis_id),
      ('dfimoveis'::text,normalized_dfimoveis_id)) codes(portal,external_listing_id)
    where external_listing_id is not null
    on conflict (portal,external_listing_id) do nothing;

    if normalized_wimoveis_id is not null and not exists (
      select 1 from public.crm_property_portal_references reference
      where reference.portal='wimoveis'
        and reference.external_listing_id=normalized_wimoveis_id
        and reference.property_id=normalized_property_id
    ) then raise exception 'O código W Imóveis informado já pertence a outro imóvel.'; end if;
    if normalized_dfimoveis_id is not null and not exists (
      select 1 from public.crm_property_portal_references reference
      where reference.portal='dfimoveis'
        and reference.external_listing_id=normalized_dfimoveis_id
        and reference.property_id=normalized_property_id
    ) then raise exception 'O código DF Imóveis informado já pertence a outro imóvel.'; end if;
  end if;
end;
$$;

revoke all on function public.sync_property_portal_references(text,text,text)
  from public,anon;
grant execute on function public.sync_property_portal_references(text,text,text)
  to authenticated;

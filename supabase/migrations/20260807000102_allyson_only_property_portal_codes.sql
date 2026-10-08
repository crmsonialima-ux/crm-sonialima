-- Portal listing codes identify the property in automated lead imports. Only
-- Allyson may change them, both in the catalog and in the reference table.
create or replace function public.protect_property_portal_codes()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if (
    new.wimoveis_code is distinct from old.wimoveis_code
    or new.dfimoveis_code is distinct from old.dfimoveis_code
  ) and not public.is_allyson_admin() then
    raise exception 'Somente Allyson pode alterar os códigos W Imóveis e DF Imóveis.';
  end if;
  return new;
end;
$$;

revoke all on function public.protect_property_portal_codes() from public, anon, authenticated;

drop trigger if exists protect_property_portal_codes
  on public.crm_property_catalog;
create trigger protect_property_portal_codes
before update of wimoveis_code, dfimoveis_code
on public.crm_property_catalog
for each row execute function public.protect_property_portal_codes();

create or replace function public.sync_property_portal_references(
  p_property_id text,
  p_wimoveis_listing_id text,
  p_dfimoveis_listing_id text
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  normalized_property_id text := nullif(trim(p_property_id), '');
  normalized_wimoveis_id text := nullif(trim(p_wimoveis_listing_id), '');
  normalized_dfimoveis_id text := nullif(trim(p_dfimoveis_listing_id), '');
begin
  if not public.is_allyson_admin() then
    raise exception 'Somente Allyson pode alterar os códigos W Imóveis e DF Imóveis.';
  end if;
  if normalized_property_id is null then
    raise exception 'Identificador do imóvel é obrigatório.';
  end if;
  if not exists (
    select 1 from public.crm_property_catalog
    where external_id = normalized_property_id
  ) then
    raise exception 'Imóvel não encontrado.';
  end if;

  if exists (
    select 1
    from public.crm_property_portal_references as reference
    where reference.property_id <> normalized_property_id
      and (
        (reference.portal = 'wimoveis' and reference.external_listing_id = normalized_wimoveis_id)
        or
        (reference.portal = 'dfimoveis' and reference.external_listing_id = normalized_dfimoveis_id)
      )
  ) then
    raise exception 'Um dos códigos informados já pertence a outro imóvel.';
  end if;

  delete from public.crm_property_portal_references
  where property_id = normalized_property_id
    and portal in ('wimoveis', 'dfimoveis');

  insert into public.crm_property_portal_references (
    portal,
    external_listing_id,
    property_id
  )
  select portal, external_listing_id, normalized_property_id
  from (values
    ('wimoveis'::text, normalized_wimoveis_id),
    ('dfimoveis'::text, normalized_dfimoveis_id)
  ) as references_to_save(portal, external_listing_id)
  where external_listing_id is not null;
end;
$$;

revoke all on function public.sync_property_portal_references(text, text, text)
  from public, anon;
grant execute on function public.sync_property_portal_references(text, text, text)
  to authenticated;

-- Broker assignments are visible and editable only to Allyson and the
-- restricted CRM administration account.
create or replace function public.can_manage_property_brokers()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select public.is_allyson_admin() or public.is_restricted_admin();
$$;

revoke all on function public.can_manage_property_brokers() from public, anon;
grant execute on function public.can_manage_property_brokers() to authenticated, service_role;

create or replace function public.protect_property_broker_assignments()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if new.brokers is distinct from old.brokers
     and not public.can_manage_property_brokers() then
    raise exception 'Somente Allyson e o acesso CRM podem alterar os corretores responsáveis.';
  end if;
  return new;
end;
$$;

revoke all on function public.protect_property_broker_assignments()
  from public, anon, authenticated;

drop trigger if exists protect_property_broker_assignments
  on public.crm_property_catalog;
create trigger protect_property_broker_assignments
before update of brokers
on public.crm_property_catalog
for each row execute function public.protect_property_broker_assignments();

create or replace function public.sync_property_broker_access(
  p_property_id text,
  p_broker_names text[]
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  normalized_property_id text := nullif(trim(p_property_id), '');
  normalized_broker_names text[] := coalesce(p_broker_names, array[]::text[]);
begin
  if not public.can_manage_property_brokers() then
    raise exception 'Somente Allyson e o acesso CRM podem alterar os corretores responsáveis.';
  end if;
  if normalized_property_id is null then
    raise exception 'Identificador do imóvel é obrigatório.';
  end if;
  if cardinality(normalized_broker_names) = 0 then
    raise exception 'Selecione ao menos um corretor responsável.';
  end if;

  delete from public.crm_property_broker_access
  where property_id = normalized_property_id;

  insert into public.crm_property_broker_access (property_id, broker_id)
  select distinct normalized_property_id, profile.id
  from public.profiles as profile
  where profile.role = 'broker'
    and profile.full_name = any(normalized_broker_names);

  if (select count(*) from public.crm_property_broker_access where property_id = normalized_property_id)
     <> cardinality(normalized_broker_names) then
    raise exception 'Um ou mais corretores selecionados não foram encontrados no Supabase.';
  end if;

  update public.crm_property_catalog
  set brokers = array_to_string(normalized_broker_names, ', '),
      updated_at = now()
  where external_id = normalized_property_id;

  if not found then
    raise exception 'Imóvel não encontrado.';
  end if;
end;
$$;

revoke all on function public.sync_property_broker_access(text, text[])
  from public, anon;
grant execute on function public.sync_property_broker_access(text, text[])
  to authenticated;

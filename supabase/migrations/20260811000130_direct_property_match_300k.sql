begin;

-- Resolve a referencia comercial do lead pelos campos preenchidos no cadastro
-- e, quando eles estiverem ausentes, pelo imovel vinculado ao proprio lead.
create or replace function public.crm_evaluate_property_matches(p_property_id text)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  property_row public.crm_property_catalog%rowtype;
  lead_row record;
  inserted_match boolean;
  notified integer := 0;
begin
  select property.*
  into property_row
  from public.crm_property_catalog as property
  where property.external_id = p_property_id
  for update;

  if not found or property_row.match_checked_at is not null then
    return 0;
  end if;

  for lead_row in
    select
      lead.id,
      lead.owner_id,
      lead.name,
      coalesce(nullif(trim(lead.desired_location), ''), reference_property.neighborhood) as match_location,
      coalesce(lead.desired_property_value, reference_property.value) as match_value
    from public.crm_leads as lead
    left join lateral (
      select catalog.neighborhood, catalog.value
      from public.crm_property_catalog as catalog
      where catalog.external_id = lead.property_catalog_id
         or (
           lead.property_catalog_id is null
           and nullif(trim(lead.property_interest), '') is not null
           and (
             public.crm_normalize_property_match_text(catalog.title)
               = public.crm_normalize_property_match_text(lead.property_interest)
             or public.crm_normalize_property_match_text(catalog.address)
               = public.crm_normalize_property_match_text(lead.property_interest)
           )
         )
      order by (catalog.external_id = lead.property_catalog_id) desc, catalog.updated_at desc
      limit 1
    ) as reference_property on true
    where lead.stage in (
      'Standby',
      'Nao teve interesse',
      'NÃ£o teve interesse',
      'Aguardando imovel similar',
      'Aguardando imÃ³vel similar'
    )
      and lead.owner_id is not null
      and property_row.value is not null
      and coalesce(lead.desired_property_value, reference_property.value) is not null
      and abs(
        property_row.value - coalesce(lead.desired_property_value, reference_property.value)
      ) <= 300000
  loop
    if not public.crm_property_neighborhood_matches(
      lead_row.match_location,
      property_row.neighborhood
    ) then
      continue;
    end if;

    inserted_match := false;
    insert into public.crm_property_match_notifications (lead_id, property_external_id)
    values (lead_row.id, property_row.external_id)
    on conflict do nothing
    returning true into inserted_match;

    if inserted_match then
      insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
      values (
        lead_row.owner_id,
        'property_match',
        'Imovel similar encontrado',
        'O imovel ' || property_row.title || ' pode ser de interesse do lead '
          || lead_row.name || '.',
        '/leads?lead=' || lead_row.id::text,
        jsonb_build_object(
          'leadId', lead_row.id,
          'propertyId', property_row.external_id,
          'name', lead_row.name,
          'propertyValue', property_row.value,
          'desiredPropertyValue', lead_row.match_value,
          'desiredLocation', lead_row.match_location,
          'propertyNeighborhood', property_row.neighborhood
        )
      );
      notified := notified + 1;
    end if;
  end loop;

  update public.crm_property_catalog as property
  set match_checked_at = now()
  where property.external_id = property_row.external_id;

  return notified;
end;
$$;

create or replace function public.crm_evaluate_matches_for_waiting_lead(p_lead_id uuid)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  lead_row public.crm_leads%rowtype;
  reference_row record;
  property_row record;
  match_location text;
  match_value numeric;
  inserted_match boolean;
  notified integer := 0;
begin
  select lead.* into lead_row
  from public.crm_leads as lead
  where lead.id = p_lead_id;

  if not found
     or lead_row.stage not in ('Aguardando imovel similar', 'Aguardando imÃ³vel similar') then
    return 0;
  end if;

  select catalog.neighborhood, catalog.value
  into reference_row
  from public.crm_property_catalog as catalog
  where catalog.external_id = lead_row.property_catalog_id
     or (
       lead_row.property_catalog_id is null
       and nullif(trim(lead_row.property_interest), '') is not null
       and (
         public.crm_normalize_property_match_text(catalog.title)
           = public.crm_normalize_property_match_text(lead_row.property_interest)
         or public.crm_normalize_property_match_text(catalog.address)
           = public.crm_normalize_property_match_text(lead_row.property_interest)
       )
     )
  order by (catalog.external_id = lead_row.property_catalog_id) desc, catalog.updated_at desc
  limit 1;

  match_location := coalesce(nullif(trim(lead_row.desired_location), ''), reference_row.neighborhood);
  match_value := coalesce(lead_row.desired_property_value, reference_row.value);

  if match_location is null or match_value is null then
    return 0;
  end if;

  for property_row in
    select property.*
    from public.crm_property_catalog as property
    where property.value is not null
      and abs(property.value - match_value) <= 300000
      and public.crm_property_neighborhood_matches(match_location, property.neighborhood)
    order by property.created_at desc
    limit 10
  loop
    inserted_match := false;
    insert into public.crm_property_match_notifications (lead_id, property_external_id)
    values (lead_row.id, property_row.external_id)
    on conflict do nothing
    returning true into inserted_match;

    if inserted_match then
      insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
      values (
        lead_row.owner_id,
        'property_match',
        'Imovel similar encontrado',
        'O imovel ' || property_row.title || ' pode ser de interesse do lead '
          || lead_row.name || '.',
        '/leads?lead=' || lead_row.id::text,
        jsonb_build_object(
          'leadId', lead_row.id,
          'propertyId', property_row.external_id,
          'name', lead_row.name,
          'propertyValue', property_row.value,
          'desiredPropertyValue', match_value,
          'desiredLocation', match_location,
          'propertyNeighborhood', property_row.neighborhood
        )
      );
      notified := notified + 1;
    end if;
  end loop;

  return notified;
end;
$$;

-- Uma alteracao comercial relevante permite uma nova avaliacao do imovel.
create or replace function public.crm_reset_property_match_check()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if new.title is distinct from old.title
     or new.address is distinct from old.address
     or new.neighborhood is distinct from old.neighborhood
     or new.city is distinct from old.city
     or new.value is distinct from old.value then
    new.match_checked_at := null;
  end if;
  return new;
end;
$$;

drop trigger if exists crm_property_catalog_reset_match_check on public.crm_property_catalog;
create trigger crm_property_catalog_reset_match_check
before update of title, address, neighborhood, city, value
on public.crm_property_catalog
for each row execute function public.crm_reset_property_match_check();

-- O cadastro manual da tela grava direto no catalogo. Este gatilho garante que
-- ele passe pela mesma verificacao imediata usada pela sincronizacao externa.
create or replace function public.crm_evaluate_property_after_write()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if new.match_checked_at is null then
    perform public.crm_evaluate_property_matches(new.external_id);
  end if;
  return new;
end;
$$;

drop trigger if exists crm_property_catalog_evaluate_after_write on public.crm_property_catalog;
create trigger crm_property_catalog_evaluate_after_write
after insert or update of title, address, neighborhood, city, value, match_checked_at
on public.crm_property_catalog
for each row execute function public.crm_evaluate_property_after_write();

revoke all on function public.crm_evaluate_property_matches(text)
  from public, anon, authenticated;
grant execute on function public.crm_evaluate_property_matches(text) to service_role;
revoke all on function public.crm_evaluate_matches_for_waiting_lead(uuid)
  from public, anon, authenticated;
grant execute on function public.crm_evaluate_matches_for_waiting_lead(uuid) to service_role;
revoke all on function public.crm_reset_property_match_check()
  from public, anon, authenticated;
revoke all on function public.crm_evaluate_property_after_write()
  from public, anon, authenticated;

commit;

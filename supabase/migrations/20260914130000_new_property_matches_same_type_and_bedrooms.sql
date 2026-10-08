begin;

-- Uma edi??o nunca deve reabrir a avalia??o nem gerar novas ofertas.
drop trigger if exists crm_property_catalog_reset_match_check on public.crm_property_catalog;
drop trigger if exists crm_property_catalog_evaluate_after_write on public.crm_property_catalog;
drop trigger if exists crm_leads_check_similar_properties_when_waiting on public.crm_leads;

-- Fecha a avalia??o dos im?veis anteriores sem disparar ofertas retroativas.
update public.crm_property_catalog
set match_checked_at = now()
where match_checked_at is null;

-- Compara??o exata do tipo (normalizando somente acentos, caixa e espa?os).
-- Sem im?vel vinculado, tipo ou quartos informados, n?o h? oferta autom?tica.
create or replace function public.crm_property_matches_reference(
  p_lead_id uuid,
  p_property_id text
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, extensions
as $$
  select exists (
    select 1
    from public.crm_leads as lead
    join public.crm_property_catalog as reference_property
      on reference_property.external_id = lead.property_catalog_id
    join public.crm_property_catalog as candidate
      on candidate.external_id = p_property_id
    where lead.id = p_lead_id
      and candidate.external_id <> reference_property.external_id
      and candidate.bedrooms = reference_property.bedrooms
      and nullif(public.crm_normalize_property_match_text(reference_property.property_type), '') is not null
      and public.crm_normalize_property_match_text(candidate.property_type)
        = public.crm_normalize_property_match_text(reference_property.property_type)
  );
$$;

revoke all on function public.crm_property_matches_reference(uuid, text)
  from public, anon, authenticated;
grant execute on function public.crm_property_matches_reference(uuid, text) to service_role;

create or replace function public.crm_evaluate_property_matches(p_property_id text)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  property_row public.crm_property_catalog%rowtype;
  lead_row record;
  property_search_text text;
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

  property_search_text := concat_ws(
    ' ', property_row.neighborhood, property_row.address,
    property_row.title, property_row.city
  );

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
    where public.crm_normalize_property_match_text(lead.stage) in (
      'standby', 'nao teve interesse', 'aguardando imovel similar'
    )
      and lead.owner_id is not null
      and public.crm_property_matches_reference(lead.id, property_row.external_id)
      and property_row.value is not null
      and coalesce(lead.desired_property_value, reference_property.value) is not null
      and abs(property_row.value - coalesce(lead.desired_property_value, reference_property.value)) <= 300000
  loop
    if not public.crm_property_neighborhood_matches(
      lead_row.match_location,
      property_search_text
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
        'Imóvel similar encontrado',
        'O imóvel ' || property_row.title || ' pode ser de interesse do lead ' || lead_row.name || '.',
        '/leads?focusLeadId=' || lead_row.id::text,
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

-- A avalia??o ocorre uma ?nica vez, na inser??o, mesmo se n?o houver matches.
create or replace function public.crm_evaluate_property_after_write()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'INSERT' then
    perform public.crm_evaluate_property_matches(new.external_id);
  end if;
  return new;
end;
$$;

create trigger crm_property_catalog_evaluate_after_write
after insert on public.crm_property_catalog
for each row execute function public.crm_evaluate_property_after_write();

-- Mant?m a assinatura para compatibilidade, sem buscar estoque antigo.
create or replace function public.crm_evaluate_matches_for_waiting_lead(p_lead_id uuid)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  return 0;
end;
$$;

-- Edi??es podem retirar sugest?es incompat?veis, mas nunca criar sugest?es.
create or replace function public.crm_dismiss_incompatible_property_matches()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if new.bedrooms is distinct from old.bedrooms
     or new.property_type is distinct from old.property_type then
    update public.crm_property_match_notifications as match
    set dismissed_at = now()
    where match.dismissed_at is null
      and match.offer_started_at is null
      and (
        match.property_external_id = new.external_id
        or exists (
          select 1 from public.crm_leads as lead
          where lead.id = match.lead_id and lead.property_catalog_id = new.external_id
        )
      )
      and not public.crm_property_matches_reference(match.lead_id, match.property_external_id);
  end if;
  return new;
end;
$$;

create trigger crm_property_catalog_dismiss_incompatible_matches
after update of bedrooms, property_type on public.crm_property_catalog
for each row execute function public.crm_dismiss_incompatible_property_matches();

-- Retira sugest?es pendentes incompat?veis e preserva o hist?rico das iniciadas.
update public.crm_property_match_notifications as match
set dismissed_at = now()
where match.dismissed_at is null
  and match.offer_started_at is null
  and not public.crm_property_matches_reference(match.lead_id, match.property_external_id);

revoke all on function public.crm_evaluate_property_matches(text) from public, anon, authenticated;
grant execute on function public.crm_evaluate_property_matches(text) to service_role;
revoke all on function public.crm_evaluate_property_after_write() from public, anon, authenticated;
revoke all on function public.crm_evaluate_matches_for_waiting_lead(uuid) from public, anon, authenticated;
grant execute on function public.crm_evaluate_matches_for_waiting_lead(uuid) to service_role;
revoke all on function public.crm_dismiss_incompatible_property_matches() from public, anon, authenticated;

notify pgrst, 'reload schema';
commit;

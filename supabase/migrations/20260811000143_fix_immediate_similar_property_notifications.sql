begin;

-- Aceita acentos, caixa, texto adicional e pequenos erros de digitacao no bairro.
create or replace function public.crm_property_neighborhood_matches(
  p_desired_location text,
  p_property_neighborhood text
)
returns boolean
language sql
immutable
parallel safe
set search_path = pg_catalog, public, extensions
as $$
  with normalized as (
    select
      public.crm_normalize_property_match_text(coalesce(p_desired_location, '')) as desired,
      public.crm_normalize_property_match_text(coalesce(p_property_neighborhood, '')) as property
  )
  select desired <> ''
     and property <> ''
     and (
       position(desired in property) > 0
       or position(property in desired) > 0
       or similarity(desired, property) >= 0.35
       or word_similarity(desired, property) >= 0.42
       or word_similarity(property, desired) >= 0.42
     )
  from normalized;
$$;

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

-- Reavalia somente os cadastros recentes para recuperar os testes feitos antes
-- da correcao, sem disparar avisos sobre todo o catalogo historico.
update public.crm_property_catalog
set match_checked_at = null
where created_at >= now() - interval '2 hours';

revoke all on function public.crm_property_neighborhood_matches(text, text)
  from public, anon, authenticated;
grant execute on function public.crm_property_neighborhood_matches(text, text) to service_role;
revoke all on function public.crm_evaluate_property_matches(text)
  from public, anon, authenticated;
grant execute on function public.crm_evaluate_property_matches(text) to service_role;

commit;

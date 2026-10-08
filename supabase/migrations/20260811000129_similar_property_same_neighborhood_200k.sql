begin;

-- A compatibilidade comercial exige o mesmo bairro e aceita uma variacao de
-- ate R$ 200 mil para baixo ou para cima do valor desejado pelo lead.
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
      public.crm_normalize_property_match_text(
        split_part(coalesce(p_desired_location, ''), ',', 1)
      ) as desired,
      public.crm_normalize_property_match_text(p_property_neighborhood) as property
  )
  select desired <> ''
     and property <> ''
     and (
       position(desired in property) > 0
       or position(property in desired) > 0
       or similarity(desired, property) >= 0.45
       or word_similarity(desired, property) >= 0.55
       or word_similarity(property, desired) >= 0.55
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
  matched boolean;
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
    select lead.id, lead.owner_id, lead.name, lead.desired_location,
           lead.desired_property_value
    from public.crm_leads as lead
    where lead.stage in (
      'Standby',
      'Nao teve interesse',
      'NÃ£o teve interesse',
      'Aguardando imovel similar',
      'Aguardando imÃ³vel similar'
    )
      and lead.not_interested_at is not null
      and lead.not_interested_at <= property_row.created_at
      and lead.desired_property_value is not null
      and property_row.value is not null
      and abs(property_row.value - lead.desired_property_value) <= 200000
  loop
    if not public.crm_property_neighborhood_matches(
      lead_row.desired_location,
      property_row.neighborhood
    ) then
      continue;
    end if;

    matched := false;
    insert into public.crm_property_match_notifications (lead_id, property_external_id)
    values (lead_row.id, property_row.external_id)
    on conflict do nothing
    returning true into matched;

    if matched then
      insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
      values (
        lead_row.owner_id,
        'property_match',
        'Imovel similar encontrado',
        'O imovel ' || property_row.title || ' pode ser de interesse do lead '
          || lead_row.name || '.',
        '/imoveis',
        jsonb_build_object(
          'leadId', lead_row.id,
          'propertyId', property_row.external_id,
          'name', lead_row.name,
          'propertyValue', property_row.value,
          'desiredPropertyValue', lead_row.desired_property_value,
          'desiredLocation', lead_row.desired_location,
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
  property_row record;
  matched boolean;
  notified integer := 0;
begin
  select lead.*
  into lead_row
  from public.crm_leads as lead
  where lead.id = p_lead_id;

  if not found
     or lead_row.stage not in ('Aguardando imovel similar', 'Aguardando imÃ³vel similar') then
    return 0;
  end if;

  for property_row in
    select property.*
    from public.crm_property_catalog as property
    where lead_row.desired_property_value is not null
      and property.value is not null
      and abs(property.value - lead_row.desired_property_value) <= 200000
      and public.crm_property_neighborhood_matches(
        lead_row.desired_location,
        property.neighborhood
      )
    order by property.created_at desc
    limit 10
  loop
    matched := false;
    insert into public.crm_property_match_notifications (lead_id, property_external_id)
    values (lead_row.id, property_row.external_id)
    on conflict do nothing
    returning true into matched;

    if matched then
      insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
      values (
        lead_row.owner_id,
        'property_match',
        'Imovel similar encontrado',
        'O imovel ' || property_row.title || ' pode ser de interesse do lead '
          || lead_row.name || '.',
        '/imoveis',
        jsonb_build_object(
          'leadId', lead_row.id,
          'propertyId', property_row.external_id,
          'name', lead_row.name,
          'propertyValue', property_row.value,
          'desiredPropertyValue', lead_row.desired_property_value,
          'desiredLocation', lead_row.desired_location,
          'propertyNeighborhood', property_row.neighborhood
        )
      );
      notified := notified + 1;
    end if;
  end loop;

  return notified;
end;
$$;

revoke all on function public.crm_evaluate_property_matches(text)
  from public, anon, authenticated;
grant execute on function public.crm_evaluate_property_matches(text) to service_role;
revoke all on function public.crm_evaluate_matches_for_waiting_lead(uuid)
  from public, anon, authenticated;
grant execute on function public.crm_evaluate_matches_for_waiting_lead(uuid) to service_role;
revoke all on function public.crm_property_neighborhood_matches(text, text)
  from public, anon, authenticated;
grant execute on function public.crm_property_neighborhood_matches(text, text) to service_role;

commit;

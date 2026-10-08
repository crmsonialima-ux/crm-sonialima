begin;

insert into public.crm_notification_delivery_policies (kind, delivery_mode, rationale)
values (
  'property_match',
  'immediate',
  'Imovel similar exige contato comercial assim que a compatibilidade for encontrada.'
)
on conflict (kind) do update
set delivery_mode = excluded.delivery_mode,
    rationale = excluded.rationale,
    updated_at = now();

create or replace function public.set_not_interested_timestamp()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if new.stage in ('Standby', 'Nao teve interesse', 'NÃ£o teve interesse', 'Aguardando imovel similar', 'Aguardando imÃ³vel similar')
     and old.stage not in ('Standby', 'Nao teve interesse', 'NÃ£o teve interesse', 'Aguardando imovel similar', 'Aguardando imÃ³vel similar') then
    new.not_interested_at := now();
  elsif new.stage not in ('Standby', 'Nao teve interesse', 'NÃ£o teve interesse', 'Aguardando imovel similar', 'Aguardando imÃ³vel similar')
        and old.stage in ('Standby', 'Nao teve interesse', 'NÃ£o teve interesse', 'Aguardando imovel similar', 'Aguardando imÃ³vel similar') then
    new.not_interested_at := null;
  end if;
  return new;
end;
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
  desired_region text;
  property_search_text text;
  normalized_neighborhood text;
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

  property_search_text := public.crm_normalize_property_match_text(
    concat_ws(' ', property_row.address, property_row.neighborhood, property_row.city, property_row.title)
  );
  normalized_neighborhood := public.crm_normalize_property_match_text(property_row.neighborhood);

  for lead_row in
    select lead.id, lead.owner_id, lead.name, lead.desired_location
    from public.crm_leads as lead
    where lead.stage in ('Standby', 'Nao teve interesse', 'NÃ£o teve interesse', 'Aguardando imovel similar', 'Aguardando imÃ³vel similar')
      and lead.not_interested_at is not null
      and lead.not_interested_at <= property_row.created_at
      and lead.desired_property_value is not null
      and property_row.value is not null
      and property_row.value <= lead.desired_property_value + 50000
  loop
    desired_region := public.crm_normalize_property_match_text(split_part(lead_row.desired_location, ',', 1));
    if desired_region = '' or not (
      position(desired_region in property_search_text) > 0
      or similarity(desired_region, normalized_neighborhood) >= 0.50
      or word_similarity(desired_region, property_search_text) >= 0.50
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
        'O imovel ' || property_row.title || ' pode atender ao lead ' || lead_row.name || '.',
        '/imoveis',
        jsonb_build_object(
          'leadId', lead_row.id,
          'propertyId', property_row.external_id,
          'name', lead_row.name,
          'propertyValue', property_row.value,
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
  select lead.* into lead_row
  from public.crm_leads as lead
  where lead.id = p_lead_id;

  if not found or lead_row.stage not in ('Aguardando imovel similar', 'Aguardando imÃ³vel similar') then
    return 0;
  end if;

  for property_row in
    select property.*
    from public.crm_property_catalog as property
    where lead_row.desired_property_value is not null
      and property.value is not null
      and property.value <= lead_row.desired_property_value + 50000
      and public.crm_normalize_property_match_text(split_part(lead_row.desired_location, ',', 1)) <> ''
      and (
        position(
          public.crm_normalize_property_match_text(split_part(lead_row.desired_location, ',', 1))
          in public.crm_normalize_property_match_text(
            concat_ws(' ', property.address, property.neighborhood, property.city, property.title)
          )
        ) > 0
        or similarity(
          public.crm_normalize_property_match_text(split_part(lead_row.desired_location, ',', 1)),
          public.crm_normalize_property_match_text(property.neighborhood)
        ) >= 0.50
        or word_similarity(
          public.crm_normalize_property_match_text(split_part(lead_row.desired_location, ',', 1)),
          public.crm_normalize_property_match_text(
            concat_ws(' ', property.address, property.neighborhood, property.city, property.title)
          )
        ) >= 0.50
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
        'O imovel ' || property_row.title || ' pode atender ao lead ' || lead_row.name || '.',
        '/imoveis',
        jsonb_build_object(
          'leadId', lead_row.id,
          'propertyId', property_row.external_id,
          'name', lead_row.name,
          'propertyValue', property_row.value,
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

create or replace function public.crm_check_similar_properties_when_waiting()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if new.stage in ('Aguardando imovel similar', 'Aguardando imÃ³vel similar')
     and old.stage not in ('Aguardando imovel similar', 'Aguardando imÃ³vel similar') then
    perform public.crm_evaluate_matches_for_waiting_lead(new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists crm_leads_check_similar_properties_when_waiting on public.crm_leads;
create trigger crm_leads_check_similar_properties_when_waiting
after update of stage on public.crm_leads
for each row execute function public.crm_check_similar_properties_when_waiting();

revoke all on function public.crm_evaluate_property_matches(text) from public, anon, authenticated;
grant execute on function public.crm_evaluate_property_matches(text) to service_role;
revoke all on function public.crm_evaluate_matches_for_waiting_lead(uuid) from public, anon, authenticated;
grant execute on function public.crm_evaluate_matches_for_waiting_lead(uuid) to service_role;

commit;

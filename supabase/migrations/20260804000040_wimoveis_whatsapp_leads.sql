-- Leads originados no formulário da W Imóveis.
-- O número é usado exclusivamente para montar o link wa.me do corretor escolhido.
alter table public.profiles
  add column if not exists whatsapp_phone text;

create or replace function public.create_wimoveis_whatsapp_lead(
  p_name text,
  p_phone text,
  p_email text,
  p_property_external_id text,
  p_message text default ''
)
returns table (
  lead_id uuid,
  assigned_owner_id uuid,
  assigned_owner_name text,
  assigned_owner_whatsapp text,
  property_title text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  selected_property record;
  next_broker record;
  existing_lead record;
  next_position integer;
  normalized_phone text;
  lead_type_value text;
  has_restricted_brokers boolean := false;
  inserted_lead uuid;
begin
  if nullif(trim(p_name), '') is null then
    raise exception 'Informe o nome do cliente.';
  end if;

  normalized_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if length(normalized_phone) < 10 then
    raise exception 'Informe um telefone válido, com DDD.';
  end if;

  select external_id, title, address, neighborhood, city, purpose, value
  into selected_property
  from public.crm_property_catalog
  where external_id = nullif(trim(p_property_external_id), '');

  if selected_property.external_id is null then
    raise exception 'O imóvel informado pela W Imóveis não foi encontrado no catálogo do CRM.';
  end if;

  lead_type_value := case
    when lower(coalesce(selected_property.purpose, '')) like '%alug%'
      or lower(coalesce(selected_property.purpose, '')) like '%loca%'
      then 'Aluguel'
    else 'Venda'
  end;

  -- Evita que duplo clique reordene a fila ou crie dois leads para o mesmo imóvel.
  perform pg_advisory_xact_lock(hashtext('wimoveis:' || normalized_phone || ':' || selected_property.external_id));
  select lead.id, lead.owner_id, profile.full_name, profile.email, profile.whatsapp_phone
  into existing_lead
  from public.crm_leads lead
  join public.profiles profile on profile.id = lead.owner_id
  where regexp_replace(coalesce(lead.phone, ''), '\D', '', 'g') = normalized_phone
    and lead.property_interest = selected_property.title
    and lead.channel = 'W Imóveis — WhatsApp'
  order by lead.created_at desc
  limit 1;

  if existing_lead.id is not null then
    if nullif(regexp_replace(coalesce(existing_lead.whatsapp_phone, ''), '\D', '', 'g'), '') is null then
      raise exception 'O corretor responsável já não possui WhatsApp configurado.';
    end if;
    return query select existing_lead.id, existing_lead.owner_id,
      coalesce(nullif(existing_lead.full_name, ''), existing_lead.email),
      regexp_replace(existing_lead.whatsapp_phone, '\D', '', 'g'), selected_property.title;
    return;
  end if;

  has_restricted_brokers := exists (
    select 1 from public.crm_property_broker_access access
    where access.property_id = selected_property.external_id
  );

  perform pg_advisory_xact_lock(hashtext('lead-distribution:' || lead_type_value));
  select queue.broker_id, profile.full_name, profile.email, profile.whatsapp_phone
  into next_broker
  from public.lead_distribution_queue queue
  join public.profiles profile on profile.id = queue.broker_id
  where queue.lead_type = lead_type_value
    and profile.role = 'broker'
    and not coalesce(profile.lead_distribution_blocked, false)
    and (
      not has_restricted_brokers
      or exists (
        select 1 from public.crm_property_broker_access access
        where access.property_id = selected_property.external_id
          and access.broker_id = queue.broker_id
      )
    )
  order by queue.position
  limit 1
  for update of queue skip locked;

  if next_broker.broker_id is null then
    raise exception 'Não há corretores habilitados na fila de % para este imóvel.', lead_type_value;
  end if;
  if nullif(regexp_replace(coalesce(next_broker.whatsapp_phone, ''), '\D', '', 'g'), '') is null then
    raise exception 'O próximo corretor da fila não possui WhatsApp configurado. Configure-o antes de ativar a integração.';
  end if;

  select coalesce(max(position), 0) + 1 into next_position
  from public.lead_distribution_queue
  where lead_type = lead_type_value;
  update public.lead_distribution_queue
  set position = next_position, updated_at = now()
  where lead_type = lead_type_value and broker_id = next_broker.broker_id;

  insert into public.crm_leads (
    name, phone, email, property_interest, stage, channel, budget, notes, owner_id, created_by,
    lead_type, desired_property_value, desired_location
  ) values (
    trim(p_name), normalized_phone, nullif(trim(p_email), ''), selected_property.title,
    'Lead', 'W Imóveis — WhatsApp', 0,
    nullif(trim(p_message), ''), next_broker.broker_id, next_broker.broker_id,
    lead_type_value, coalesce(selected_property.value, 0),
    nullif(concat_ws(', ', selected_property.neighborhood, selected_property.city, selected_property.address), '')
  ) returning id into inserted_lead;

  return query select inserted_lead, next_broker.broker_id,
    coalesce(nullif(next_broker.full_name, ''), next_broker.email),
    regexp_replace(next_broker.whatsapp_phone, '\D', '', 'g'), selected_property.title;
end;
$$;

revoke all on function public.create_wimoveis_whatsapp_lead(text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.create_wimoveis_whatsapp_lead(text, text, text, text, text) to service_role;

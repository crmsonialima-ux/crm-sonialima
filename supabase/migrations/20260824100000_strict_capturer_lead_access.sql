begin;

create or replace function public.get_next_property_lead_broker(
  p_property_id text,
  p_lead_type text
)
returns table (broker_id uuid, full_name text, email text)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  normalized_property_id text := nullif(trim(coalesce(p_property_id, '')), '');
  roulette_state public.crm_property_lead_roulette%rowtype;
  primary_capturer_id uuid;
  next_broker record;
  next_position integer;
  has_capturer boolean := false;
begin
  if p_lead_type not in ('Venda', 'Aluguel') then
    raise exception 'Tipo de lead invalido.';
  end if;

  if normalized_property_id is not null then
    perform pg_advisory_xact_lock(
      hashtext('property-lead-roulette:' || normalized_property_id)
    );

    select assignment.broker_id
    into primary_capturer_id
    from public.crm_property_capturer_assignments as assignment
    join public.profiles as profile on profile.id = assignment.broker_id
    join public.crm_property_broker_access as access
      on access.broker_id = assignment.broker_id
     and access.property_id = assignment.property_id
    where assignment.property_id = normalized_property_id
      and profile.role = 'broker'
      and not coalesce(profile.lead_distribution_blocked, false)
      and (
        profile.lead_distribution_blocked_until is null
        or profile.lead_distribution_blocked_until <= now()
      )
    order by assignment.created_at, assignment.broker_id
    limit 1;

    has_capturer := primary_capturer_id is not null;
  end if;

  if has_capturer then
    insert into public.crm_property_lead_roulette(property_id)
    values (normalized_property_id)
    on conflict (property_id) do nothing;

    select state.*
    into roulette_state
    from public.crm_property_lead_roulette as state
    where state.property_id = normalized_property_id
    for update;

    if roulette_state.captador_round then
      select profile.id, profile.full_name, profile.email
      into next_broker
      from public.profiles as profile
      where profile.id = primary_capturer_id;

      if next_broker.id is null then
        raise exception 'Captador principal do imovel nao foi encontrado.';
      end if;

      if roulette_state.captador_leads_delivered = 0 then
        update public.crm_property_lead_roulette
        set captador_leads_delivered = 1,
            queue_leads_delivered = 0,
            updated_at = now()
        where property_id = normalized_property_id;
      else
        update public.crm_property_lead_roulette
        set captador_round = false,
            captador_leads_delivered = 0,
            queue_leads_delivered = 0,
            updated_at = now()
        where property_id = normalized_property_id;
      end if;

      return query
      select next_broker.id::uuid, next_broker.full_name::text, next_broker.email::text;
      return;
    end if;

    select queue.broker_id, profile.full_name, profile.email
    into next_broker
    from public.lead_distribution_queue as queue
    join public.profiles as profile on profile.id = queue.broker_id
    join public.crm_property_broker_access as access
      on access.property_id = normalized_property_id
     and access.broker_id = queue.broker_id
    where queue.lead_type = p_lead_type
      and profile.role = 'broker'
      and not coalesce(profile.lead_distribution_blocked, false)
      and (
        profile.lead_distribution_blocked_until is null
        or profile.lead_distribution_blocked_until <= now()
      )
      and queue.broker_id <> primary_capturer_id
    order by queue.position
    limit 1
    for update of queue skip locked;

    if next_broker.broker_id is null then
      raise exception 'Nao ha outro corretor elegivel na esteira deste imovel alem do captador.';
    end if;

    select coalesce(max(queue.position), 0) + 1
    into next_position
    from public.lead_distribution_queue as queue
    where queue.lead_type = p_lead_type;

    update public.lead_distribution_queue as queue
    set position = next_position,
        updated_at = now()
    where queue.lead_type = p_lead_type
      and queue.broker_id = next_broker.broker_id;

    update public.crm_property_lead_roulette
    set captador_round = true,
        captador_leads_delivered = 0,
        queue_leads_delivered = 0,
        updated_at = now()
    where property_id = normalized_property_id;

    return query
    select next_broker.broker_id::uuid, next_broker.full_name::text, next_broker.email::text;
    return;
  end if;

  if normalized_property_id is null then
    select queue.broker_id, profile.full_name, profile.email
    into next_broker
    from public.lead_distribution_queue as queue
    join public.profiles as profile on profile.id = queue.broker_id
    where queue.lead_type = p_lead_type
      and profile.role = 'broker'
      and not coalesce(profile.lead_distribution_blocked, false)
      and (
        profile.lead_distribution_blocked_until is null
        or profile.lead_distribution_blocked_until <= now()
      )
    order by queue.position
    limit 1
    for update of queue skip locked;
  else
    select queue.broker_id, profile.full_name, profile.email
    into next_broker
    from public.lead_distribution_queue as queue
    join public.profiles as profile on profile.id = queue.broker_id
    join public.crm_property_broker_access as access
      on access.property_id = normalized_property_id
     and access.broker_id = queue.broker_id
    where queue.lead_type = p_lead_type
      and profile.role = 'broker'
      and not coalesce(profile.lead_distribution_blocked, false)
      and (
        profile.lead_distribution_blocked_until is null
        or profile.lead_distribution_blocked_until <= now()
      )
    order by queue.position
    limit 1
    for update of queue skip locked;
  end if;

  if next_broker.broker_id is null then
    return;
  end if;

  select coalesce(max(queue.position), 0) + 1
  into next_position
  from public.lead_distribution_queue as queue
  where queue.lead_type = p_lead_type;

  update public.lead_distribution_queue as queue
  set position = next_position,
      updated_at = now()
  where queue.lead_type = p_lead_type
    and queue.broker_id = next_broker.broker_id;

  return query
  select next_broker.broker_id::uuid, next_broker.full_name::text, next_broker.email::text;
end;
$$;

create or replace function public.create_distributed_lead(
  p_name text,
  p_phone text,
  p_email text,
  p_property_interest text,
  p_stage text,
  p_channel text,
  p_notes text,
  p_external_id text,
  p_lead_type text,
  p_desired_property_value numeric,
  p_desired_location text
)
returns table (lead_id uuid, assigned_owner_id uuid, assigned_owner_name text)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  next_broker record;
  inserted_lead uuid;
  normalized_phone text;
  selected_property_id text;
  is_queue_lead boolean := false;
  primary_capturer_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Sessao nao encontrada.';
  end if;
  if p_lead_type not in ('Venda', 'Aluguel') then
    raise exception 'Tipo de lead invalido.';
  end if;
  if coalesce(p_desired_property_value, 0) <= 0 then
    raise exception 'Informe o valor medio do imovel desejado.';
  end if;
  if nullif(trim(p_desired_location), '') is null then
    raise exception 'Informe a localizacao desejada.';
  end if;

  select catalog.external_id
  into selected_property_id
  from public.crm_property_catalog as catalog
  where catalog.external_id = nullif(trim(coalesce(p_external_id, '')), '')
     or lower(catalog.title) = lower(trim(coalesce(p_property_interest, '')))
     or lower(coalesce(catalog.address, '')) = lower(trim(coalesce(p_property_interest, '')))
  order by
    (catalog.external_id = nullif(trim(coalesce(p_external_id, '')), '')) desc,
    catalog.updated_at desc
  limit 1;

  perform pg_advisory_xact_lock(hashtext('lead-distribution:' || p_lead_type));

  normalized_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if normalized_phone = '' then
    raise exception 'Telefone e obrigatorio.';
  end if;
  perform pg_advisory_xact_lock(hashtext(normalized_phone));
  if exists (
    select 1
    from public.crm_leads as lead
    where regexp_replace(coalesce(lead.phone, ''), '\D', '', 'g') = normalized_phone
  ) then
    raise exception 'Ja existe um lead cadastrado com este telefone.';
  end if;

  select *
  into next_broker
  from public.get_next_property_lead_broker(selected_property_id, p_lead_type);

  if next_broker.broker_id is null then
    if selected_property_id is not null then
      raise exception 'Nenhum corretor elegivel foi encontrado para este imovel na fila de %.', p_lead_type;
    end if;
    raise exception 'Nao ha corretores habilitados na fila de %.', p_lead_type;
  end if;

  select assignment.broker_id
  into primary_capturer_id
  from public.crm_property_capturer_assignments as assignment
  join public.profiles as profile on profile.id = assignment.broker_id
  join public.crm_property_broker_access as access
    on access.broker_id = assignment.broker_id
   and access.property_id = assignment.property_id
  where assignment.property_id = selected_property_id
    and profile.role = 'broker'
    and not coalesce(profile.lead_distribution_blocked, false)
    and (
      profile.lead_distribution_blocked_until is null
      or profile.lead_distribution_blocked_until <= now()
    )
  order by assignment.created_at, assignment.broker_id
  limit 1;

  is_queue_lead := primary_capturer_id is not null
    and next_broker.broker_id <> primary_capturer_id;

  insert into public.crm_leads (
    name, phone, email, property_interest, property_catalog_id, stage, channel,
    budget, notes, owner_id, created_by, external_id, lead_type,
    desired_property_value, desired_location, property_roulette_queue_lead,
    property_roulette_excluded_capturer_id
  ) values (
    trim(p_name), nullif(trim(p_phone), ''), nullif(trim(p_email), ''),
    nullif(trim(p_property_interest), ''), selected_property_id, p_stage,
    nullif(trim(p_channel), ''), 0, nullif(trim(p_notes), ''),
    next_broker.broker_id, auth.uid(), nullif(trim(p_external_id), ''), p_lead_type,
    p_desired_property_value, trim(p_desired_location), is_queue_lead,
    case when is_queue_lead then primary_capturer_id else null end
  )
  returning id into inserted_lead;

  return query
  select inserted_lead,
         next_broker.broker_id,
         coalesce(nullif(next_broker.full_name, ''), next_broker.email);
end;
$$;

create or replace function public.create_distributed_lead(
  p_name text,
  p_phone text,
  p_email text,
  p_property_interest text,
  p_stage text,
  p_channel text,
  p_notes text,
  p_external_id text,
  p_lead_type text
)
returns table (lead_id uuid, assigned_owner_id uuid, assigned_owner_name text)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  next_broker record;
  inserted_lead uuid;
  normalized_phone text;
  selected_property_id text;
  is_queue_lead boolean := false;
  primary_capturer_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Sessao nao encontrada.';
  end if;
  if p_lead_type not in ('Venda', 'Aluguel') then
    raise exception 'Tipo de lead invalido.';
  end if;

  select catalog.external_id
  into selected_property_id
  from public.crm_property_catalog as catalog
  where catalog.external_id = nullif(trim(coalesce(p_external_id, '')), '')
     or lower(catalog.title) = lower(trim(coalesce(p_property_interest, '')))
     or lower(coalesce(catalog.address, '')) = lower(trim(coalesce(p_property_interest, '')))
  order by
    (catalog.external_id = nullif(trim(coalesce(p_external_id, '')), '')) desc,
    catalog.updated_at desc
  limit 1;

  perform pg_advisory_xact_lock(hashtext('lead-distribution:' || p_lead_type));

  normalized_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if normalized_phone = '' then
    raise exception 'Telefone e obrigatorio.';
  end if;
  perform pg_advisory_xact_lock(hashtext(normalized_phone));
  if exists (
    select 1 from public.crm_leads as lead
    where regexp_replace(coalesce(lead.phone, ''), '\D', '', 'g') = normalized_phone
  ) then
    raise exception 'Ja existe um lead cadastrado com este telefone.';
  end if;

  select *
  into next_broker
  from public.get_next_property_lead_broker(selected_property_id, p_lead_type);

  if next_broker.broker_id is null then
    raise exception 'Nao ha corretor elegivel para este lead.';
  end if;

  select assignment.broker_id
  into primary_capturer_id
  from public.crm_property_capturer_assignments as assignment
  join public.profiles as profile on profile.id = assignment.broker_id
  join public.crm_property_broker_access as access
    on access.broker_id = assignment.broker_id
   and access.property_id = assignment.property_id
  where assignment.property_id = selected_property_id
    and profile.role = 'broker'
    and not coalesce(profile.lead_distribution_blocked, false)
    and (
      profile.lead_distribution_blocked_until is null
      or profile.lead_distribution_blocked_until <= now()
    )
  order by assignment.created_at, assignment.broker_id
  limit 1;

  is_queue_lead := primary_capturer_id is not null
    and next_broker.broker_id <> primary_capturer_id;

  insert into public.crm_leads (
    name, phone, email, property_interest, property_catalog_id, stage, channel,
    budget, notes, owner_id, created_by, external_id, lead_type,
    property_roulette_queue_lead, property_roulette_excluded_capturer_id
  ) values (
    trim(p_name), nullif(trim(p_phone), ''), nullif(trim(p_email), ''),
    nullif(trim(p_property_interest), ''), selected_property_id, p_stage,
    nullif(trim(p_channel), ''), 0, nullif(trim(p_notes), ''),
    next_broker.broker_id, auth.uid(), nullif(trim(p_external_id), ''), p_lead_type,
    is_queue_lead, case when is_queue_lead then primary_capturer_id else null end
  )
  returning id into inserted_lead;

  return query
  select inserted_lead,
         next_broker.broker_id,
         coalesce(nullif(next_broker.full_name, ''), next_broker.email);
end;
$$;

create or replace function public.create_portal_vrsync_lead(
  p_portal text,
  p_provider text,
  p_channel text,
  p_origin_lead_id text,
  p_client_listing_id text,
  p_name text,
  p_phone text,
  p_email text,
  p_message text,
  p_transaction_type text,
  p_lead_origin text,
  p_payload jsonb default '{}'::jsonb
)
returns table (lead_id uuid, assigned_owner_id uuid, assigned_owner_name text, duplicate boolean)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  selected_property record;
  next_broker record;
  previous_receipt record;
  lead_type_value text;
  inserted_lead uuid;
  normalized_phone text;
  property_title_value text;
  desired_location_value text;
  selected_property_id text;
  desired_property_value numeric := 0;
  is_queue_lead boolean := false;
  primary_capturer_id uuid;
begin
  if p_portal not in ('wimoveis', 'dfimoveis', 'zap') then
    raise exception 'Portal nao reconhecido.';
  end if;
  if nullif(trim(p_origin_lead_id), '') is null then
    raise exception 'originLeadId e obrigatorio.';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_provider || ':' || trim(p_origin_lead_id)));

  select receipt.lead_id, lead.owner_id, profile.full_name, profile.email
  into previous_receipt
  from public.crm_external_lead_receipts as receipt
  join public.crm_leads as lead on lead.id = receipt.lead_id
  join public.profiles as profile on profile.id = lead.owner_id
  where receipt.provider = p_provider
    and receipt.origin_lead_id = trim(p_origin_lead_id);

  if previous_receipt.lead_id is not null then
    return query
    select previous_receipt.lead_id,
           previous_receipt.owner_id,
           coalesce(nullif(previous_receipt.full_name, ''), previous_receipt.email),
           true;
    return;
  end if;

  lead_type_value := case upper(trim(coalesce(p_transaction_type, '')))
    when 'RENT' then 'Aluguel'
    when 'SELL' then 'Venda'
    else null
  end;
  if lead_type_value is null then
    raise exception 'transactionType deve ser SELL ou RENT.';
  end if;

  if nullif(trim(p_client_listing_id), '') is not null then
    select coalesce(
      (
        select reference.property_id
        from public.crm_property_portal_references as reference
        where reference.portal = case when p_portal = 'zap' then 'wimoveis' else p_portal end
          and reference.external_listing_id = trim(p_client_listing_id)
        limit 1
      ),
      trim(p_client_listing_id)
    )
    into selected_property_id;

    select catalog.external_id, catalog.title, catalog.address,
           catalog.neighborhood, catalog.city, catalog.value
    into selected_property
    from public.crm_property_catalog as catalog
    where catalog.external_id = selected_property_id;

    if selected_property.external_id is null then
      raise exception 'clientListingId nao encontrado no catalogo ou nas referencias do portal: %', trim(p_client_listing_id);
    end if;

    selected_property_id := selected_property.external_id;
    property_title_value := selected_property.title;
    desired_property_value := coalesce(selected_property.value, 0);
    desired_location_value := nullif(
      concat_ws(', ', selected_property.neighborhood, selected_property.city, selected_property.address),
      ''
    );
  elsif upper(trim(coalesce(p_lead_origin, ''))) = 'MCMV_OLX' then
    property_title_value := 'Simulacao Minha Casa Minha Vida';
  else
    raise exception 'clientListingId e obrigatorio para leads de anuncio.';
  end if;

  perform pg_advisory_xact_lock(hashtext('lead-distribution:' || lead_type_value));

  select *
  into next_broker
  from public.get_next_property_lead_broker(selected_property_id, lead_type_value);

  if next_broker.broker_id is null then
    raise exception 'Nao ha corretores habilitados na fila de % para este lead.', lead_type_value;
  end if;

  select assignment.broker_id
  into primary_capturer_id
  from public.crm_property_capturer_assignments as assignment
  join public.profiles as profile on profile.id = assignment.broker_id
  join public.crm_property_broker_access as access
    on access.broker_id = assignment.broker_id
   and access.property_id = assignment.property_id
  where assignment.property_id = selected_property_id
    and profile.role = 'broker'
    and not coalesce(profile.lead_distribution_blocked, false)
    and (
      profile.lead_distribution_blocked_until is null
      or profile.lead_distribution_blocked_until <= now()
    )
  order by assignment.created_at, assignment.broker_id
  limit 1;

  is_queue_lead := primary_capturer_id is not null
    and next_broker.broker_id <> primary_capturer_id;

  normalized_phone := nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '');

  insert into public.crm_leads (
    name, phone, email, property_interest, property_catalog_id, stage, channel,
    budget, notes, owner_id, created_by, lead_type, desired_property_value,
    desired_location, external_id, property_roulette_queue_lead,
    property_roulette_excluded_capturer_id
  ) values (
    coalesce(nullif(trim(p_name), ''), 'Lead sem nome'), normalized_phone,
    nullif(trim(p_email), ''), property_title_value, selected_property_id,
    'Lead', p_channel, 0, nullif(trim(p_message), ''), next_broker.broker_id,
    next_broker.broker_id, lead_type_value, desired_property_value,
    desired_location_value, selected_property_id, is_queue_lead,
    case when is_queue_lead then primary_capturer_id else null end
  )
  returning id into inserted_lead;

  insert into public.crm_external_lead_receipts(provider, origin_lead_id, lead_id, payload)
  values (p_provider, trim(p_origin_lead_id), inserted_lead, coalesce(p_payload, '{}'::jsonb));

  return query
  select inserted_lead,
         next_broker.broker_id,
         coalesce(nullif(next_broker.full_name, ''), next_broker.email),
         false;
end;
$$;

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
set search_path = pg_catalog, public
as $$
declare
  selected_property record;
  next_broker record;
  existing_lead record;
  normalized_phone text;
  lead_type_value text;
  inserted_lead uuid;
  broker_whatsapp text;
  is_queue_lead boolean := false;
  primary_capturer_id uuid;
begin
  if nullif(trim(p_name), '') is null then
    raise exception 'Informe o nome do cliente.';
  end if;

  normalized_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if length(normalized_phone) < 10 then
    raise exception 'Informe um telefone valido, com DDD.';
  end if;

  select catalog.external_id, catalog.title, catalog.address, catalog.neighborhood,
         catalog.city, catalog.purpose, catalog.value
  into selected_property
  from public.crm_property_catalog as catalog
  where catalog.external_id = nullif(trim(p_property_external_id), '');

  if selected_property.external_id is null then
    raise exception 'O imovel informado pela W Imoveis nao foi encontrado no catalogo do CRM.';
  end if;

  lead_type_value := case
    when lower(coalesce(selected_property.purpose, '')) like '%alug%'
      or lower(coalesce(selected_property.purpose, '')) like '%loca%'
      then 'Aluguel'
    else 'Venda'
  end;

  perform pg_advisory_xact_lock(
    hashtext('wimoveis:' || normalized_phone || ':' || selected_property.external_id)
  );

  select lead.id, lead.owner_id, profile.full_name, profile.email, profile.whatsapp_phone
  into existing_lead
  from public.crm_leads as lead
  join public.profiles as profile on profile.id = lead.owner_id
  where regexp_replace(coalesce(lead.phone, ''), '\D', '', 'g') = normalized_phone
    and lead.property_interest = selected_property.title
    and lead.channel = 'W Imóveis — WhatsApp'
  order by lead.created_at desc
  limit 1;

  if existing_lead.id is not null then
    if nullif(regexp_replace(coalesce(existing_lead.whatsapp_phone, ''), '\D', '', 'g'), '') is null then
      raise exception 'O corretor responsavel ja nao possui WhatsApp configurado.';
    end if;

    return query
    select existing_lead.id,
           existing_lead.owner_id,
           coalesce(nullif(existing_lead.full_name, ''), existing_lead.email),
           regexp_replace(existing_lead.whatsapp_phone, '\D', '', 'g'),
           selected_property.title;
    return;
  end if;

  perform pg_advisory_xact_lock(hashtext('lead-distribution:' || lead_type_value));

  select *
  into next_broker
  from public.get_next_property_lead_broker(selected_property.external_id, lead_type_value);

  if next_broker.broker_id is null then
    raise exception 'Nao ha corretores habilitados na fila de % para este imovel.', lead_type_value;
  end if;

  select regexp_replace(coalesce(profile.whatsapp_phone, ''), '\D', '', 'g')
  into broker_whatsapp
  from public.profiles as profile
  where profile.id = next_broker.broker_id;

  if nullif(broker_whatsapp, '') is null then
    raise exception 'O corretor escolhido pela distribuicao nao possui WhatsApp configurado.';
  end if;

  select assignment.broker_id
  into primary_capturer_id
  from public.crm_property_capturer_assignments as assignment
  join public.profiles as profile on profile.id = assignment.broker_id
  join public.crm_property_broker_access as access
    on access.broker_id = assignment.broker_id
   and access.property_id = assignment.property_id
  where assignment.property_id = selected_property.external_id
    and profile.role = 'broker'
    and not coalesce(profile.lead_distribution_blocked, false)
    and (
      profile.lead_distribution_blocked_until is null
      or profile.lead_distribution_blocked_until <= now()
    )
  order by assignment.created_at, assignment.broker_id
  limit 1;

  is_queue_lead := primary_capturer_id is not null
    and next_broker.broker_id <> primary_capturer_id;

  insert into public.crm_leads (
    name, phone, email, property_interest, property_catalog_id, stage, channel,
    budget, notes, owner_id, created_by, lead_type, desired_property_value,
    desired_location, external_id, property_roulette_queue_lead,
    property_roulette_excluded_capturer_id
  ) values (
    trim(p_name), normalized_phone, nullif(trim(p_email), ''), selected_property.title,
    selected_property.external_id, 'Lead', 'W Imóveis — WhatsApp', 0,
    nullif(trim(p_message), ''), next_broker.broker_id, next_broker.broker_id,
    lead_type_value, coalesce(selected_property.value, 0),
    nullif(concat_ws(', ', selected_property.neighborhood, selected_property.city, selected_property.address), ''),
    selected_property.external_id, is_queue_lead,
    case when is_queue_lead then primary_capturer_id else null end
  )
  returning id into inserted_lead;

  return query
  select inserted_lead,
         next_broker.broker_id,
         coalesce(nullif(next_broker.full_name, ''), next_broker.email),
         broker_whatsapp,
         selected_property.title;
end;
$$;

commit;

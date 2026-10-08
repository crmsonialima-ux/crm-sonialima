-- Final correction for the property lead roulette.
-- Rule per property: 2 new leads to the primary capturer, then 1 new lead to the
-- normal queue excluding every capturer of that property, then repeat.
-- The queue lead may continue through the normal assignment attempts; creating it
-- already closes the queue phase so the next two NEW leads return to the capturer.

begin;

alter table public.crm_leads
  add column if not exists property_roulette_queue_lead boolean not null default false,
  add column if not exists property_roulette_excluded_capturer_id uuid references public.profiles(id) on delete set null;

comment on column public.crm_leads.property_roulette_queue_lead is
  'True only for the 1 queue lead in each property roulette cycle (2 capturer -> 1 queue).';

comment on column public.crm_leads.property_roulette_excluded_capturer_id is
  'Primary capturer excluded from every retry of the queue lead in the 2 capturer -> 1 queue cycle.';

create table if not exists public.crm_property_lead_roulette (
  property_id text primary key,
  captador_round boolean not null default true,
  captador_leads_delivered integer not null default 0,
  queue_leads_delivered integer not null default 0,
  updated_at timestamptz not null default now()
);

alter table public.crm_property_lead_roulette
  add column if not exists updated_at timestamptz not null default now();

-- Start the corrected rule cleanly for every property. This table contains only
-- routing counters; no lead, history, property or user data is removed.
update public.crm_property_lead_roulette
set captador_round = true,
    captador_leads_delivered = 0,
    queue_leads_delivered = 0,
    updated_at = now();

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

  -- Keep all choices for one property serialized even when different intake
  -- functions receive leads at the same time.
  if normalized_property_id is not null then
    perform pg_advisory_xact_lock(
      hashtext('property-lead-roulette:' || normalized_property_id)
    );

    select assignment.broker_id
    into primary_capturer_id
    from public.crm_property_capturer_assignments as assignment
    join public.profiles as profile on profile.id = assignment.broker_id
    where assignment.property_id = normalized_property_id
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
      -- First and second new lead always go to the PRIMARY capturer.
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
        -- Exactly two capturer leads completed. The NEXT new lead is the one
        -- queue lead of this cycle.
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

    -- Third new lead: enter the normal queue, but NEVER choose the primary capturer
    -- of this property. The property-specific broker list remains authoritative.
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

    -- Critical point: this ONE new queue lead closes the queue phase immediately.
    -- Acceptance/timeout of this lead does not postpone the next 2 capturer leads.
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

  -- Property without capturer (or non-property lead): preserve normal queue.
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

revoke all on function public.get_next_property_lead_broker(text, text) from public, anon;
grant execute on function public.get_next_property_lead_broker(text, text) to authenticated, service_role;

-- Current CRM signature (11 parameters). This is the signature actually called by
-- create_lead_with_phones and by Vitor's queue path.
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

  select capturer.broker_id
  into primary_capturer_id
  from public.crm_property_capturer_assignments as capturer
  where capturer.property_id = selected_property_id
  order by capturer.created_at, capturer.broker_id
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

revoke all on function public.create_distributed_lead(
  text, text, text, text, text, text, text, text, text, numeric, text
) from public, anon;
grant execute on function public.create_distributed_lead(
  text, text, text, text, text, text, text, text, text, numeric, text
) to authenticated, service_role;

-- Keep the older 9-parameter overload correct as well, because it was introduced
-- by the first roulette migration and may still be called by external code.
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

  select capturer.broker_id
  into primary_capturer_id
  from public.crm_property_capturer_assignments as capturer
  where capturer.property_id = selected_property_id
  order by capturer.created_at, capturer.broker_id
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

revoke all on function public.create_distributed_lead(
  text, text, text, text, text, text, text, text, text
) from public, anon;
grant execute on function public.create_distributed_lead(
  text, text, text, text, text, text, text, text, text
) to authenticated, service_role;

-- Shared VRSYNC intake (DF Imoveis / W Imoveis / Grupo OLX).
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

  select capturer.broker_id
  into primary_capturer_id
  from public.crm_property_capturer_assignments as capturer
  where capturer.property_id = selected_property_id
  order by capturer.created_at, capturer.broker_id
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

revoke all on function public.create_portal_vrsync_lead(
  text, text, text, text, text, text, text, text, text, text, text, jsonb
) from public, anon, authenticated;
grant execute on function public.create_portal_vrsync_lead(
  text, text, text, text, text, text, text, text, text, text, text, jsonb
) to service_role;

-- Grupo OLX/ZAP wrapper now uses the same corrected property roulette.
create or replace function public.create_zap_vrsync_lead(
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
returns table (
  lead_id uuid,
  assigned_owner_id uuid,
  assigned_owner_name text,
  duplicate boolean
)
language sql
security definer
set search_path = pg_catalog, public
as $$
  select *
  from public.create_portal_vrsync_lead(
    'wimoveis',
    'grupo-olx',
    'Grupo OLX — W Imóveis',
    p_origin_lead_id,
    p_client_listing_id,
    p_name,
    p_phone,
    p_email,
    p_message,
    p_transaction_type,
    p_lead_origin,
    p_payload
  );
$$;

revoke all on function public.create_zap_vrsync_lead(
  text, text, text, text, text, text, text, text, jsonb
) from public, anon, authenticated;
grant execute on function public.create_zap_vrsync_lead(
  text, text, text, text, text, text, text, text, jsonb
) to service_role;

-- Direct W Imoveis WhatsApp entry point.
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

  select capturer.broker_id
  into primary_capturer_id
  from public.crm_property_capturer_assignments as capturer
  where capturer.property_id = selected_property.external_id
  order by capturer.created_at, capturer.broker_id
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

revoke all on function public.create_wimoveis_whatsapp_lead(text, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.create_wimoveis_whatsapp_lead(text, text, text, text, text)
  to service_role;

create or replace function public.process_whatsapp_inbound_message(
  p_message_id text,
  p_phone text,
  p_contact_name text,
  p_message_text text,
  p_received_at timestamptz,
  p_portal text,
  p_external_code text,
  p_phone_number_id text,
  p_parse_status text,
  p_parse_reason text,
  p_payload jsonb default '{}'::jsonb
)
returns table (
  status text,
  lead_id uuid,
  duplicate boolean,
  event_id uuid
)
language plpgsql
security definer
set search_path = public
as $$
declare
  existing_event record;
  inbound_event_id uuid;
  integration_enabled boolean := false;
  normalized_portal text;
  normalized_parse_status text;
  normalized_external_code text;
  normalized_phone text;
  selected_property record;
  selected_property_id text;
  selected_broker record;
  existing_lead record;
  existing_owner_eligible boolean := false;
  eligible_brokers uuid[] := array[]::uuid[];
  next_position integer;
  lead_type_value text;
  purpose_normalized text;
  purpose_is_sale boolean;
  purpose_is_rent boolean;
  channel_value text;
  property_location text;
  inserted_lead_id uuid;
  is_queue_lead boolean := false;
  primary_capturer_id uuid;
  failure_sqlstate text;
begin
  if nullif(trim(coalesce(p_message_id, '')), '') is null then
    raise exception 'message_id do WhatsApp e obrigatorio.';
  end if;

  perform pg_advisory_xact_lock(
    hashtext('whatsapp-inbound:' || trim(p_message_id))
  );

  select event.status, event.lead_id, event.id
  into existing_event
  from public.crm_whatsapp_inbound_events as event
  where event.message_id = trim(p_message_id);

  if existing_event.id is not null then
    return query
    select existing_event.status::text, existing_event.lead_id::uuid, true, existing_event.id::uuid;
    return;
  end if;

  normalized_portal := case lower(trim(coalesce(p_portal, '')))
    when 'wimoveis' then 'wimoveis'
    when 'dfimoveis' then 'dfimoveis'
    else null
  end;
  normalized_parse_status := lower(trim(coalesce(p_parse_status, '')));
  normalized_external_code := nullif(trim(coalesce(p_external_code, '')), '');
  normalized_phone := public.normalize_crm_phone_identity(p_phone);

  insert into public.crm_whatsapp_inbound_events(
    message_id,
    phone_number_id,
    sender_phone,
    contact_name,
    message_text,
    message_received_at,
    parse_status,
    parse_reason,
    portal,
    external_listing_id,
    status,
    raw_payload
  ) values (
    trim(p_message_id),
    nullif(trim(coalesce(p_phone_number_id, '')), ''),
    normalized_phone,
    nullif(trim(coalesce(p_contact_name, '')), ''),
    nullif(left(trim(coalesce(p_message_text, '')), 8000), ''),
    p_received_at,
    coalesce(nullif(normalized_parse_status, ''), 'invalid'),
    nullif(left(trim(coalesce(p_parse_reason, '')), 500), ''),
    normalized_portal,
    normalized_external_code,
    'received',
    coalesce(p_payload, '{}'::jsonb)
  )
  returning id into inbound_event_id;

  -- O evento bruto fica fora do sub-bloco. Se qualquer etapa posterior falhar,
  -- o processamento e revertido sem perder a trilha de auditoria recebida.
  begin

  select integration.enabled
  into integration_enabled
  from public.crm_portal_lead_integrations as integration
  where integration.provider = 'whatsapp_business';

  if not coalesce(integration_enabled, false) then
    update public.crm_whatsapp_inbound_events as event
    set status = 'integration_paused',
        status_reason = 'Recebimento de leads do WhatsApp pausado no CRM.',
        processed_at = now(),
        updated_at = now()
    where event.id = inbound_event_id;

    return query select 'integration_paused'::text, null::uuid, false, inbound_event_id;
    return;
  end if;

  if normalized_parse_status = 'ignored' then
    update public.crm_whatsapp_inbound_events as event
    set status = 'ignored',
        status_reason = coalesce(nullif(trim(p_parse_reason), ''), 'Mensagem sem referencia segura de imovel.'),
        processed_at = now(),
        updated_at = now()
    where event.id = inbound_event_id;

    return query select 'ignored'::text, null::uuid, false, inbound_event_id;
    return;
  end if;

  if normalized_parse_status = 'ambiguous' then
    update public.crm_whatsapp_inbound_events as event
    set status = 'ambiguous',
        status_reason = coalesce(nullif(trim(p_parse_reason), ''), 'Foram encontrados codigos conflitantes.'),
        processed_at = now(),
        updated_at = now()
    where event.id = inbound_event_id;

    perform public.enqueue_whatsapp_admin_notification(
      inbound_event_id,
      'whatsapp_message_ambiguous',
      'Mensagem de portal precisa de revisao',
      'O WhatsApp recebeu uma mensagem com referencias de imovel conflitantes.',
      jsonb_build_object('phone', normalized_phone, 'messageId', trim(p_message_id))
    );

    return query select 'ambiguous'::text, null::uuid, false, inbound_event_id;
    return;
  end if;

  if normalized_parse_status <> 'matched_candidate'
     or normalized_portal is null
     or normalized_external_code is null then
    update public.crm_whatsapp_inbound_events as event
    set status = 'invalid_payload',
        status_reason = 'Parser nao forneceu portal e codigo validos.',
        processed_at = now(),
        updated_at = now()
    where event.id = inbound_event_id;

    perform public.enqueue_whatsapp_admin_notification(
      inbound_event_id,
      'whatsapp_lead_intervention',
      'Falha ao interpretar mensagem de portal',
      'Uma mensagem candidata a lead nao trouxe portal e codigo validos.',
      jsonb_build_object('phone', normalized_phone, 'messageId', trim(p_message_id))
    );

    return query select 'invalid_payload'::text, null::uuid, false, inbound_event_id;
    return;
  end if;

  select
    reference.property_id,
    property.external_id,
    property.title,
    property.address,
    property.neighborhood,
    property.city,
    property.purpose,
    property.value
  into selected_property
  from public.crm_property_portal_references as reference
  join public.crm_property_catalog as property
    on property.external_id = reference.property_id
  where reference.portal = normalized_portal
    and reference.external_listing_id = normalized_external_code
  limit 1;

  if selected_property.external_id is null then
    update public.crm_whatsapp_inbound_events as event
    set status = 'property_not_found',
        status_reason = 'Codigo externo nao localizado nas referencias do CRM.',
        processed_at = now(),
        updated_at = now()
    where event.id = inbound_event_id;

    perform public.enqueue_whatsapp_admin_notification(
      inbound_event_id,
      'whatsapp_code_unmatched',
      'Lead recebido com codigo de imovel nao localizado',
      'Origem: ' || case normalized_portal when 'dfimoveis' then 'DF Imóveis' else 'W Imóveis' end
        || '. Codigo: ' || normalized_external_code
        || '. Cliente: ' || coalesce(nullif(trim(p_contact_name), ''), 'sem nome')
        || '. Telefone: ' || coalesce(normalized_phone, 'nao informado') || '.',
      jsonb_build_object(
        'sourcePortal', normalized_portal,
        'externalCode', normalized_external_code,
        'contactName', nullif(trim(p_contact_name), ''),
        'phone', normalized_phone,
        'message', nullif(trim(p_message_text), ''),
        'receivedAt', p_received_at,
        'messageId', trim(p_message_id)
      )
    );

    return query select 'property_not_found'::text, null::uuid, false, inbound_event_id;
    return;
  end if;

  selected_property_id := selected_property.external_id;
  update public.crm_whatsapp_inbound_events as event
  set property_id = selected_property_id,
      updated_at = now()
  where event.id = inbound_event_id;

  purpose_normalized := lower(translate(
    coalesce(selected_property.purpose, ''),
    'ÁÀÂÃÉÊÍÓÔÕÚÇáàâãéêíóôõúç',
    'AAAAEEIOOOUCaaaaeeiooouc'
  ));
  purpose_is_sale := purpose_normalized like '%vend%';
  purpose_is_rent := purpose_normalized like '%alug%' or purpose_normalized like '%loca%';

  if purpose_is_sale = purpose_is_rent then
    update public.crm_whatsapp_inbound_events as event
    set status = 'configuration_error',
        status_reason = 'Finalidade do imovel ausente ou ambigua: ' || coalesce(selected_property.purpose, 'nao informada'),
        processed_at = now(),
        updated_at = now()
    where event.id = inbound_event_id;

    perform public.enqueue_whatsapp_admin_notification(
      inbound_event_id,
      'whatsapp_lead_intervention',
      'Imovel sem finalidade unica para distribuicao',
      'Revise a finalidade do imovel ' || selected_property.title
        || ' antes de distribuir o lead do codigo ' || normalized_external_code || '.',
      jsonb_build_object(
        'propertyId', selected_property_id,
        'sourcePortal', normalized_portal,
        'externalCode', normalized_external_code
      )
    );

    return query select 'configuration_error'::text, null::uuid, false, inbound_event_id;
    return;
  end if;

  lead_type_value := case when purpose_is_rent then 'Aluguel' else 'Venda' end;
  channel_value := case normalized_portal
    when 'dfimoveis' then 'DF Imóveis'
    else 'W Imóveis'
  end;

  if normalized_phone is null or length(normalized_phone) not in (10, 11) then
    update public.crm_whatsapp_inbound_events as event
    set status = 'invalid_phone',
        status_reason = 'Telefone do remetente ausente ou invalido.',
        processed_at = now(),
        updated_at = now()
    where event.id = inbound_event_id;

    perform public.enqueue_whatsapp_admin_notification(
      inbound_event_id,
      'whatsapp_lead_intervention',
      'Lead de portal sem telefone valido',
      'Nao foi possivel distribuir o contato do codigo ' || normalized_external_code
        || ' porque o WhatsApp nao trouxe um telefone valido.',
      jsonb_build_object(
        'propertyId', selected_property_id,
        'sourcePortal', normalized_portal,
        'externalCode', normalized_external_code,
        'leadType', lead_type_value
      )
    );

    return query select 'invalid_phone'::text, null::uuid, false, inbound_event_id;
    return;
  end if;

  -- Mantem a mesma ordem de locks usada pelo cadastro manual atual:
  -- primeiro a esteira da finalidade, depois o telefone. Isso evita deadlock
  -- entre um cadastro manual e um webhook simultaneos do mesmo contato.
  perform pg_advisory_xact_lock(hashtext('lead-distribution:' || lead_type_value));
  perform pg_advisory_xact_lock(hashtext(normalized_phone));

  select lead.id, lead.owner_id, lead.name
  into existing_lead
  from public.crm_leads as lead
  where public.normalize_crm_phone_identity(lead.phone) = normalized_phone
  order by lead.created_at desc, lead.id
  limit 1;

  if existing_lead.id is not null then
    select exists (
      select 1
      from public.profiles as profile
      join public.lead_distribution_queue as queue
        on queue.broker_id = profile.id
       and queue.lead_type = lead_type_value
      join public.crm_property_broker_access as access
        on access.property_id = selected_property_id
       and access.broker_id = profile.id
      where profile.id = existing_lead.owner_id
        and profile.role = 'broker'
        and not coalesce(profile.lead_distribution_blocked, false)
    )
    into existing_owner_eligible;

    if not existing_owner_eligible then
      update public.crm_whatsapp_inbound_events as event
      set status = 'configuration_error',
          status_reason = 'O telefone pertence a um lead cujo responsavel nao esta elegivel para este imovel.',
          property_id = selected_property_id,
          lead_id = existing_lead.id,
          processed_at = now(),
          updated_at = now()
      where event.id = inbound_event_id;

      perform public.enqueue_whatsapp_admin_notification(
        inbound_event_id,
        'whatsapp_lead_intervention',
        'Recontato exige intervencao administrativa',
        coalesce(nullif(existing_lead.name, ''), 'Um cliente') || ' voltou a chamar pelo '
          || channel_value || ', mas o responsavel atual nao esta autorizado e ativo para o imovel '
          || selected_property.title || '. Nenhum contato foi redistribuido automaticamente.',
        jsonb_build_object(
          'leadId', existing_lead.id,
          'propertyId', selected_property_id,
          'sourcePortal', normalized_portal,
          'externalCode', normalized_external_code,
          'phone', normalized_phone
        )
      );

      return query select 'configuration_error'::text, existing_lead.id, false, inbound_event_id;
      return;
    end if;

    update public.crm_whatsapp_inbound_events as event
    set status = 'linked_existing',
        status_reason = 'Telefone ja pertence a um lead existente; nenhuma nova rodada foi criada.',
        property_id = selected_property_id,
        lead_id = existing_lead.id,
        eligible_broker_ids = array[existing_lead.owner_id],
        processed_at = now(),
        updated_at = now()
    where event.id = inbound_event_id;

    insert into public.crm_lead_activities(
      lead_id, stage, note, author_id, author_name
    ) values (
      existing_lead.id,
      'Novo contato via WhatsApp',
      'Origem: ' || channel_value || '. Codigo: ' || normalized_external_code
        || '. Mensagem: ' || coalesce(nullif(trim(p_message_text), ''), '(sem texto)'),
      null,
      'Integracao WhatsApp'
    );

    insert into public.crm_notification_outbox(
      recipient_id, kind, title, body, url, payload
    ) values (
      existing_lead.owner_id,
      'whatsapp_existing_lead_contact',
      'Novo contato de um lead existente',
      coalesce(nullif(existing_lead.name, ''), 'Um cliente') || ' voltou a chamar pelo '
        || channel_value || ' sobre o imovel ' || selected_property.title || '.',
      '/leads',
      jsonb_build_object(
        'leadId', existing_lead.id,
        'whatsappEventId', inbound_event_id,
        'sourcePortal', normalized_portal,
        'externalCode', normalized_external_code
      )
    );

    return query select 'linked_existing'::text, existing_lead.id, false, inbound_event_id;
    return;
  end if;

  select coalesce(array_agg(candidate.broker_id order by candidate.priority, candidate.position), array[]::uuid[])
  into eligible_brokers
  from (
    select capturer.broker_id, 0 as priority, 0::bigint as position
    from public.crm_property_capturer_assignments as capturer
    where capturer.property_id = selected_property_id

    union

    select queue.broker_id, 1 as priority, queue.position::bigint
    from public.lead_distribution_queue as queue
    join public.profiles as profile
      on profile.id = queue.broker_id
    join public.crm_property_broker_access as access
      on access.property_id = selected_property_id
     and access.broker_id = queue.broker_id
    where queue.lead_type = lead_type_value
      and profile.role = 'broker'
      and not coalesce(profile.lead_distribution_blocked, false)
      and (profile.lead_distribution_blocked_until is null or profile.lead_distribution_blocked_until <= now())
  ) as candidate;

  update public.crm_whatsapp_inbound_events as event
  set eligible_broker_ids = eligible_brokers,
      updated_at = now()
  where event.id = inbound_event_id;

  if cardinality(eligible_brokers) = 0 then
    update public.crm_whatsapp_inbound_events as event
    set status = 'no_eligible_broker',
        status_reason = 'Nenhum corretor autorizado esta ativo e disponivel na fila do imovel.',
        processed_at = now(),
        updated_at = now()
    where event.id = inbound_event_id;

    perform public.enqueue_whatsapp_admin_notification(
      inbound_event_id,
      'whatsapp_lead_intervention',
      'Lead sem corretor elegivel',
      'Origem: ' || channel_value || '. Imovel: ' || selected_property.title
        || '. Codigo: ' || normalized_external_code || '. Finalidade: ' || lead_type_value
        || '. Cliente: '
        || coalesce(nullif(trim(p_contact_name), ''), 'sem nome') || '. Telefone: '
        || normalized_phone || '. Nenhum corretor autorizado esta disponivel.',
      jsonb_build_object(
        'propertyId', selected_property_id,
        'sourcePortal', normalized_portal,
        'externalCode', normalized_external_code,
        'leadType', lead_type_value,
        'phone', normalized_phone
      )
    );

    return query select 'no_eligible_broker'::text, null::uuid, false, inbound_event_id;
    return;
  end if;

  select *
  into selected_broker
  from public.get_next_property_lead_broker(selected_property_id, lead_type_value);

  if selected_broker.broker_id is null then
    update public.crm_whatsapp_inbound_events as event
    set status = 'no_eligible_broker',
        status_reason = 'A fila mudou durante o processamento e nenhum corretor permaneceu elegivel.',
        processed_at = now(),
        updated_at = now()
    where event.id = inbound_event_id;

    perform public.enqueue_whatsapp_admin_notification(
      inbound_event_id,
      'whatsapp_lead_intervention',
      'Lead sem corretor elegivel',
      'Nenhum corretor permaneceu disponivel para o imovel ' || selected_property.title || '.',
      jsonb_build_object(
        'propertyId', selected_property_id,
        'sourcePortal', normalized_portal,
        'externalCode', normalized_external_code,
        'leadType', lead_type_value
      )
    );

    return query select 'no_eligible_broker'::text, null::uuid, false, inbound_event_id;
    return;
  end if;

  select capturer.broker_id
  into primary_capturer_id
  from public.crm_property_capturer_assignments as capturer
  where capturer.property_id = selected_property_id
  order by capturer.created_at, capturer.broker_id
  limit 1;

  is_queue_lead := primary_capturer_id is not null
    and selected_broker.broker_id <> primary_capturer_id;

  property_location := nullif(
    concat_ws(
      ', ',
      nullif(trim(coalesce(selected_property.address, '')), ''),
      nullif(trim(coalesce(selected_property.neighborhood, '')), ''),
      nullif(trim(coalesce(selected_property.city, '')), '')
    ),
    ''
  );

  insert into public.crm_leads(
    name,
    phone,
    email,
    property_interest,
    stage,
    channel,
    budget,
    notes,
    owner_id,
    created_by,
    lead_type,
    desired_property_value,
    desired_location,
    property_catalog_id,
    property_roulette_queue_lead,
    property_roulette_excluded_capturer_id,
    source_portal,
    source_listing_id,
    source_message_id
  ) values (
    coalesce(nullif(trim(p_contact_name), ''), 'Lead sem nome'),
    normalized_phone,
    null,
    selected_property.title,
    'Lead',
    channel_value,
    0,
    nullif(trim(p_message_text), ''),
    selected_broker.broker_id,
    selected_broker.broker_id,
    lead_type_value,
    coalesce(selected_property.value, 0),
    property_location,
    selected_property_id,
    is_queue_lead,
    case when is_queue_lead then primary_capturer_id else null end,
    normalized_portal,
    normalized_external_code,
    trim(p_message_id)
  )
  returning id into inserted_lead_id;

  insert into public.crm_lead_activities(
    lead_id, stage, note, author_id, author_name
  ) values (
    inserted_lead_id,
    'Lead recebido via WhatsApp',
    'Origem: ' || channel_value || '. Codigo: ' || normalized_external_code
      || '. Mensagem original: ' || coalesce(nullif(trim(p_message_text), ''), '(sem texto)'),
    null,
    'Integracao WhatsApp'
  );

  update public.crm_whatsapp_inbound_events as event
  set status = 'lead_created',
      status_reason = 'Lead criado e primeira tentativa de distribuicao iniciada.',
      property_id = selected_property_id,
      lead_id = inserted_lead_id,
      processed_at = now(),
      updated_at = now()
  where event.id = inbound_event_id;

  return query select 'lead_created'::text, inserted_lead_id, false, inbound_event_id;
  exception
    when others then
      get stacked diagnostics failure_sqlstate = returned_sqlstate;

      update public.crm_whatsapp_inbound_events as event
      set status = 'failed',
          status_reason = 'Falha interna durante o processamento. Consulte o codigo SQLSTATE no evento.',
          error_sqlstate = failure_sqlstate,
          processed_at = now(),
          updated_at = now()
      where event.id = inbound_event_id;

      -- A falha do proprio canal de notificacao nao pode apagar o evento de
      -- auditoria nem impedir a resposta idempotente do webhook.
      begin
        perform public.enqueue_whatsapp_admin_notification(
          inbound_event_id,
          'whatsapp_lead_intervention',
          'Falha interna ao processar mensagem do WhatsApp',
          'O evento foi preservado para analise administrativa. Codigo SQLSTATE: '
            || coalesce(failure_sqlstate, 'desconhecido') || '.',
          jsonb_build_object('messageId', trim(p_message_id))
        );
      exception
        when others then
          null;
      end;

      return query select 'failed'::text, null::uuid, false, inbound_event_id;
      return;
  end;
end;
$$;

revoke all on function public.process_whatsapp_inbound_message(
  text, text, text, text, timestamptz, text, text, text, text, text, jsonb
) from public, anon, authenticated;
grant execute on function public.process_whatsapp_inbound_message(
  text, text, text, text, timestamptz, text, text, text, text, text, jsonb
) to service_role;

create or replace function public.process_expired_lead_assignments()
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  lead_row record;
  next_broker_id uuid;
  next_broker_name text;
  next_broker_email text;
  next_position integer;
  current_run integer;
  current_round smallint;
  attempt_count integer;
  next_attempt_number integer;
  next_duration_minutes integer;
  next_available_at timestamptz;
  next_deadline_at timestamptz;
  timeout_message text;
  source_label text;
begin
  if not public.crm_is_lead_queue_hours(now()) then
    return;
  end if;

  for lead_row in
    select lead.*
    from public.crm_leads as lead
    where lead.assignment_deadline_at <= now()
      and (
        lead.assignment_status = 'pending'
        or (
          lead.assignment_status = 'accepted'
          and lead.stage = 'Em atendimento'
        )
      )
    order by lead.assignment_deadline_at, lead.id
    for update skip locked
  loop
    update public.lead_assignment_attempts as attempt
    set expired_at = now()
    where attempt.lead_id = lead_row.id
      and attempt.broker_id = lead_row.owner_id
      and attempt.run_number = lead_row.assignment_run_number
      and attempt.expired_at is null
      and attempt.accepted_at is null;

    current_run := coalesce(lead_row.assignment_run_number, 1);
    select coalesce(max(attempt_number), 0)
    into attempt_count
    from public.lead_assignment_attempts
    where lead_id = lead_row.id
      and run_number = current_run;

    select round_number
    into current_round
    from public.lead_assignment_attempts
    where lead_id = lead_row.id
      and run_number = current_run
    order by attempt_number desc
    limit 1;
    current_round := coalesce(current_round, 1::smallint);

    if lead_row.property_catalog_id is null then
      select queue.broker_id, profile.full_name, profile.email
      into next_broker_id, next_broker_name, next_broker_email
      from public.lead_distribution_queue as queue
      join public.profiles as profile on profile.id = queue.broker_id
      where queue.lead_type = lead_row.lead_type
        and profile.role = 'broker'
        and not coalesce(profile.lead_distribution_blocked, false)
        and (profile.lead_distribution_blocked_until is null or profile.lead_distribution_blocked_until <= now())
        and (
          not coalesce(lead_row.property_roulette_queue_lead, false)
          or lead_row.property_roulette_excluded_capturer_id is null
          or queue.broker_id <> lead_row.property_roulette_excluded_capturer_id
        )
        and not exists (
          select 1
          from public.lead_assignment_attempts as attempt
          where attempt.lead_id = lead_row.id
            and attempt.run_number = current_run
            and attempt.round_number = current_round
            and attempt.broker_id = queue.broker_id
        )
      order by queue.position
      limit 1
      for update of queue skip locked;
    else
      select queue.broker_id, profile.full_name, profile.email
      into next_broker_id, next_broker_name, next_broker_email
      from public.crm_property_broker_access as access
      join public.lead_distribution_queue as queue
        on queue.broker_id = access.broker_id
       and queue.lead_type = lead_row.lead_type
      join public.profiles as profile on profile.id = access.broker_id
      where access.property_id = lead_row.property_catalog_id
        and profile.role = 'broker'
        and not coalesce(profile.lead_distribution_blocked, false)
        and (profile.lead_distribution_blocked_until is null or profile.lead_distribution_blocked_until <= now())
        and (
          not coalesce(lead_row.property_roulette_queue_lead, false)
          or lead_row.property_roulette_excluded_capturer_id is null
          or queue.broker_id <> lead_row.property_roulette_excluded_capturer_id
        )
        and not exists (
          select 1
          from public.lead_assignment_attempts as attempt
          where attempt.lead_id = lead_row.id
            and attempt.run_number = current_run
            and attempt.round_number = current_round
            and attempt.broker_id = access.broker_id
        )
      order by queue.position
      limit 1
      for update of queue skip locked;
    end if;

    if next_broker_id is null and current_round = 1 then
      current_round := 2;

      if lead_row.property_catalog_id is null then
        select queue.broker_id, profile.full_name, profile.email
        into next_broker_id, next_broker_name, next_broker_email
        from public.lead_distribution_queue as queue
        join public.profiles as profile on profile.id = queue.broker_id
        where queue.lead_type = lead_row.lead_type
          and profile.role = 'broker'
          and not coalesce(profile.lead_distribution_blocked, false)
          and (profile.lead_distribution_blocked_until is null or profile.lead_distribution_blocked_until <= now())
        and (
          not coalesce(lead_row.property_roulette_queue_lead, false)
          or lead_row.property_roulette_excluded_capturer_id is null
          or queue.broker_id <> lead_row.property_roulette_excluded_capturer_id
        )
          and not exists (
            select 1
            from public.lead_assignment_attempts as attempt
            where attempt.lead_id = lead_row.id
              and attempt.run_number = current_run
              and attempt.round_number = current_round
              and attempt.broker_id = queue.broker_id
          )
        order by queue.position
        limit 1
        for update of queue skip locked;
      else
        select queue.broker_id, profile.full_name, profile.email
        into next_broker_id, next_broker_name, next_broker_email
        from public.crm_property_broker_access as access
        join public.lead_distribution_queue as queue
          on queue.broker_id = access.broker_id
         and queue.lead_type = lead_row.lead_type
        join public.profiles as profile on profile.id = access.broker_id
        where access.property_id = lead_row.property_catalog_id
          and profile.role = 'broker'
          and not coalesce(profile.lead_distribution_blocked, false)
          and (profile.lead_distribution_blocked_until is null or profile.lead_distribution_blocked_until <= now())
        and (
          not coalesce(lead_row.property_roulette_queue_lead, false)
          or lead_row.property_roulette_excluded_capturer_id is null
          or queue.broker_id <> lead_row.property_roulette_excluded_capturer_id
        )
          and not exists (
            select 1
            from public.lead_assignment_attempts as attempt
            where attempt.lead_id = lead_row.id
              and attempt.run_number = current_run
              and attempt.round_number = current_round
              and attempt.broker_id = access.broker_id
          )
        order by queue.position
        limit 1
        for update of queue skip locked;
      end if;
    end if;

    timeout_message := case
      when lead_row.assignment_status = 'pending' then 'Prazo de aceite expirado'
      when lead_row.assignment_status = 'accepted' and lead_row.stage = 'Em atendimento' then 'Atraso no atendimento'
      else 'Prazo esgotado'
    end;

    if next_broker_id is null then
      update public.crm_leads as l
      set assignment_status = 'exhausted',
          assignment_deadline_at = null,
          assignment_available_at = null,
          assignment_reminder_sent_at = null,
          stage = 'Aguardando redistribuicao pelo Allyson'
      where l.id = lead_row.id;

      source_label := coalesce(
        nullif(lead_row.channel, ''),
        nullif(lead_row.external_id, ''),
        'Origem manual'
      );
      insert into public.crm_lead_activities(lead_id, stage, note, author_name)
      values(
        lead_row.id,
        'Distribuicao esgotada',
        timeout_message || '. Nao ha mais corretores elegiveis. Aguardando Allyson.',
        'Sistema'
      );
      insert into public.crm_notification_outbox(recipient_id, kind, title, body, url, payload)
      select
        p.id,
        'lead_assignment_exhausted',
        'Lead esgotado na distribuicao',
        lead_row.name || ' (' || source_label || ') passou por todos os corretores e retornou para a gerencia.',
        '/leads',
        jsonb_build_object('leadId', lead_row.id)
      from public.profiles as p
      where lower(trim(p.email)) in ('crmsoniaallyson@gmail.com', 'unassigned-institutional@example.invalid');
      continue;
    end if;

    select coalesce(max(position), 0) + 1
    into next_position
    from public.lead_distribution_queue
    where lead_type = lead_row.lead_type;

    update public.lead_distribution_queue
    set position = next_position, updated_at = now()
    where lead_type = lead_row.lead_type and broker_id = next_broker_id;

    next_attempt_number := attempt_count + 1;
    next_duration_minutes := case
      when next_attempt_number = 1 then 15
      else 5
    end;
    next_available_at := public.crm_next_lead_queue_moment(now());
    next_deadline_at := public.crm_add_lead_queue_minutes(next_available_at, next_duration_minutes);

    update public.crm_leads as l
    set owner_id = next_broker_id,
        assignment_status = 'pending',
        assignment_available_at = next_available_at,
        assignment_deadline_at = next_deadline_at,
        assignment_reminder_sent_at = null,
        stage = 'Aguardando atendimento'
    where l.id = lead_row.id;

    insert into public.lead_assignment_attempts (
      lead_id,
      broker_id,
      attempt_number,
      run_number,
      round_number,
      notified_at,
      deadline_at
    ) values (
      lead_row.id,
      next_broker_id,
      next_attempt_number,
      current_run,
      current_round,
      next_available_at,
      next_deadline_at
    );

    insert into public.crm_lead_activities(lead_id, stage, note, author_name)
    values(
      lead_row.id,
      'Lead redistribuido',
      timeout_message || '. Distribuido para ' || coalesce(nullif(next_broker_name, ''), next_broker_email) || ' (' || next_duration_minutes || ' min uteis).',
      'Sistema'
    );

    insert into public.crm_notification_outbox (
      recipient_id,
      kind,
      title,
      body,
      url,
      payload,
      available_at
    ) values (
      next_broker_id,
      'lead_assignment',
      'Novo lead aguardando atendimento',
      'Voce tem ' || next_duration_minutes || ' minutos uteis para iniciar o atendimento de ' || lead_row.name || '.',
      '/leads',
      jsonb_build_object(
        'leadId', lead_row.id,
        'phone', lead_row.phone,
        'name', lead_row.name,
        'attemptNumber', next_attempt_number,
        'runNumber', current_run,
        'roundNumber', current_round,
        'availableAt', next_available_at,
        'deadlineAt', next_deadline_at
      ),
      next_available_at
    );
  end loop;
end;
$$;

create or replace function public.restart_exhausted_lead_queue(p_lead_id uuid)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  lead_record public.crm_leads%rowtype;
  next_broker_id uuid;
  next_broker_name text;
  next_broker_email text;
  next_position integer;
  next_run_number integer;
  available_at timestamptz;
  deadline_at timestamptz;
begin
  if not public.is_allyson_admin() then
    raise exception 'Somente Allyson pode girar novamente um lead na esteira.';
  end if;

  select lead.*
  into lead_record
  from public.crm_leads as lead
  where lead.id = p_lead_id
  for update;

  if not found then
    raise exception 'Lead nao encontrado.';
  end if;
  if lead_record.assignment_status is distinct from 'exhausted' then
    raise exception 'Este lead nao esta com a esteira esgotada.';
  end if;

  perform pg_advisory_xact_lock(
    hashtext('lead-distribution:' || lead_record.lead_type)
  );

  select queue.broker_id, profile.full_name, profile.email
  into next_broker_id, next_broker_name, next_broker_email
  from public.lead_distribution_queue as queue
  join public.profiles as profile
    on profile.id = queue.broker_id
  where queue.lead_type = lead_record.lead_type
    and profile.role = 'broker'
    and not coalesce(profile.lead_distribution_blocked, false)
    and (
      not coalesce(lead_record.property_roulette_queue_lead, false)
      or lead_record.property_roulette_excluded_capturer_id is null
      or queue.broker_id <> lead_record.property_roulette_excluded_capturer_id
    )
    and (
      lead_record.property_catalog_id is null
      or exists (
          select 1
          from public.crm_property_broker_access as access
          where access.property_id = lead_record.property_catalog_id
            and access.broker_id = queue.broker_id
        )
    )
  order by queue.position
  limit 1
  for update of queue skip locked;

  if next_broker_id is null then
    raise exception 'Nao ha corretor elegivel na fila deste lead.';
  end if;

  select coalesce(max(queue.position), 0) + 1
  into next_position
  from public.lead_distribution_queue as queue
  where queue.lead_type = lead_record.lead_type;

  update public.lead_distribution_queue as queue
  set position = next_position,
      updated_at = now()
  where queue.lead_type = lead_record.lead_type
    and queue.broker_id = next_broker_id;

  next_run_number := greatest(coalesce(lead_record.assignment_run_number, 1), 1) + 1;
  available_at := public.crm_next_lead_queue_moment(now());
  deadline_at := public.crm_add_lead_queue_minutes(available_at, 15);

  update public.crm_leads as lead
  set owner_id = next_broker_id,
      assignment_status = 'pending',
      assignment_available_at = available_at,
      assignment_deadline_at = deadline_at,
      assignment_run_number = next_run_number,
      assignment_reminder_sent_at = null,
      stage = 'Aguardando atendimento',
      updated_at = now()
  where lead.id = lead_record.id;

  insert into public.lead_assignment_attempts (
    lead_id,
    broker_id,
    attempt_number,
    run_number,
    round_number,
    notified_at,
    deadline_at
  ) values (
    lead_record.id,
    next_broker_id,
    1,
    next_run_number,
    1,
    available_at,
    deadline_at
  );

  insert into public.crm_notification_outbox (
    recipient_id,
    kind,
    title,
    body,
    url,
    payload,
    available_at
  ) values (
    next_broker_id,
    'lead_assignment',
    'Lead reiniciado na esteira',
    'Voce tem 15 minutos uteis para iniciar o atendimento de '
      || lead_record.name || '.',
    '/leads',
    jsonb_build_object(
      'leadId', lead_record.id,
      'phone', lead_record.phone,
      'name', lead_record.name,
      'attemptNumber', 1,
      'runNumber', next_run_number,
      'roundNumber', 1,
      'availableAt', available_at,
      'deadlineAt', deadline_at,
      'restartedByAllyson', true
    ),
    available_at
  );

  insert into public.crm_lead_activities (
    lead_id,
    stage,
    note,
    author_id,
    author_name
  ) values (
    lead_record.id,
    'Esteira reiniciada',
    'Allyson iniciou a execucao ' || next_run_number
      || ' da esteira, com ate duas rodadas e primeiro prazo de 15 minutos uteis.',
    auth.uid(),
    'crmallyson'
  );

  return coalesce(nullif(next_broker_name, ''), next_broker_email);
end;
$$;

commit;

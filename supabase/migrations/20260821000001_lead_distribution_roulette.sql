begin;

create table if not exists public.crm_property_lead_roulette (
  property_id text primary key,
  captador_round boolean not null default true,
  captador_leads_delivered int not null default 0,
  queue_leads_delivered int not null default 0
);

create or replace function public.get_next_property_lead_broker(
  p_property_id text,
  p_lead_type text
) returns table (broker_id uuid, full_name text, email text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_state public.crm_property_lead_roulette%rowtype;
  v_captadores uuid[];
  v_queue_size int;
  v_next_broker record;
  v_target_broker_id uuid;
begin
  if p_lead_type not in ('Venda', 'Aluguel') then
    raise exception 'Tipo de lead inválido.';
  end if;

  -- Obter fila de corretores ativos
  select count(*) into v_queue_size
  from public.lead_distribution_queue as queue
  join public.profiles as profile on profile.id = queue.broker_id
  where queue.lead_type = p_lead_type
    and profile.role = 'broker'
    and not coalesce(profile.lead_distribution_blocked, false)
    and (profile.lead_distribution_blocked_until is null or profile.lead_distribution_blocked_until <= now());

  -- Obter captadores do imóvel se aplicável
  if p_property_id is not null and trim(p_property_id) <> '' then
    select array_agg(c.broker_id order by c.created_at asc) into v_captadores
    from public.crm_property_capturer_assignments c
    where c.property_id = p_property_id;
  else
    v_captadores := array[]::uuid[];
  end if;

  if array_length(v_captadores, 1) is not null and v_queue_size > 0 then
    -- Lock state
    insert into public.crm_property_lead_roulette (property_id)
    values (p_property_id)
    on conflict do nothing;

    select * into v_state
    from public.crm_property_lead_roulette
    where property_id = p_property_id
    for update;

    if v_state.captador_round then
      -- Round do Captador (2 leads)
      if v_state.captador_leads_delivered = 0 then
        v_target_broker_id := v_captadores[1];
        update public.crm_property_lead_roulette
        set captador_leads_delivered = 1
        where property_id = p_property_id;
      else
        -- Segundo lead vai pro segundo captador (ou primeiro se só tiver 1)
        if array_length(v_captadores, 1) >= 2 then
          v_target_broker_id := v_captadores[2];
        else
          v_target_broker_id := v_captadores[1];
        end if;
        update public.crm_property_lead_roulette
        set captador_leads_delivered = 0, captador_round = false, queue_leads_delivered = 0
        where property_id = p_property_id;
      end if;
    else
      -- Round da Fila (v_queue_size leads)
      if v_state.queue_leads_delivered < v_queue_size - 1 then
        update public.crm_property_lead_roulette
        set queue_leads_delivered = queue_leads_delivered + 1
        where property_id = p_property_id;
      else
        update public.crm_property_lead_roulette
        set queue_leads_delivered = 0, captador_round = true, captador_leads_delivered = 0
        where property_id = p_property_id;
      end if;
      v_target_broker_id := null; -- null indica que deve ir pra fila normal
    end if;
  end if;

  if v_target_broker_id is not null then
    select p.id, p.full_name, p.email into v_next_broker
    from public.profiles p
    where p.id = v_target_broker_id;
    
    if v_next_broker.id is not null then
      return query select v_next_broker.id, v_next_broker.full_name, v_next_broker.email;
      return;
    end if;
  end if;

  select queue.broker_id, profile.full_name, profile.email
  into v_next_broker
  from public.lead_distribution_queue as queue
  join public.profiles as profile on profile.id = queue.broker_id
  where queue.lead_type = p_lead_type
    and profile.role = 'broker'
    and not coalesce(profile.lead_distribution_blocked, false)
    and (profile.lead_distribution_blocked_until is null or profile.lead_distribution_blocked_until <= now())
  order by queue.position
  limit 1
  for update of queue skip locked;

  if v_next_broker.broker_id is null then
    select p.id, p.full_name, p.email into v_next_broker
    from public.profiles p
    where p.role = 'admin' limit 1;
  else
    update public.lead_distribution_queue
    set position = coalesce((select max(position) from public.lead_distribution_queue where lead_type = p_lead_type), 0) + 1,
        updated_at = now()
    where lead_type = p_lead_type and broker_id = v_next_broker.broker_id;
  end if;

  return query select v_next_broker.broker_id, v_next_broker.full_name, v_next_broker.email;
end;
$$;

revoke all on function public.get_next_property_lead_broker(text, text) from public, anon;
grant execute on function public.get_next_property_lead_broker(text, text) to authenticated, service_role;

-- 1. Atualizar create_distributed_lead
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
set search_path = public
as $$
declare
  next_broker record;
  inserted_lead uuid;
  normalized_phone text;
begin
  if auth.uid() is null then
    raise exception 'Sessão não encontrada.';
  end if;
  if p_lead_type not in ('Venda', 'Aluguel') then
    raise exception 'Tipo de lead inválido.';
  end if;

  perform pg_advisory_xact_lock(hashtext('lead-distribution:' || p_lead_type));

  normalized_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if normalized_phone = '' then
    raise exception 'Telefone é obrigatório.';
  end if;
  perform pg_advisory_xact_lock(hashtext(normalized_phone));
  if exists (
    select 1
    from public.crm_leads
    where regexp_replace(coalesce(phone, ''), '\D', '', 'g') = normalized_phone
  ) then
    raise exception 'Já existe um lead cadastrado com este telefone.';
  end if;

  select * into next_broker from public.get_next_property_lead_broker(p_external_id, p_lead_type);

  if next_broker.broker_id is null then
    raise exception 'Não há corretores ativos na fila de %.', p_lead_type;
  end if;

  insert into public.crm_leads (
    name, phone, email, property_interest, stage, channel, budget, notes,
    owner_id, created_by, external_id, lead_type
  ) values (
    p_name, nullif(p_phone, ''), nullif(p_email, ''), nullif(p_property_interest, ''),
    p_stage, nullif(p_channel, ''), 0, nullif(p_notes, ''),
    next_broker.broker_id, auth.uid(), nullif(p_external_id, ''), p_lead_type
  ) returning id into inserted_lead;

  return query select
    inserted_lead,
    next_broker.broker_id,
    coalesce(nullif(next_broker.full_name, ''), next_broker.email);
end;
$$;


-- 2. Atualizar a base dos portais para usar a roleta
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
language plpgsql security definer set search_path = public
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
begin
  if p_portal not in ('wimoveis', 'dfimoveis', 'zap') then raise exception 'Portal não reconhecido.'; end if;
  if nullif(trim(p_origin_lead_id), '') is null then raise exception 'originLeadId é obrigatório.'; end if;

  perform pg_advisory_xact_lock(hashtext(p_provider || ':' || trim(p_origin_lead_id)));
  select receipt.lead_id, lead.owner_id, profile.full_name, profile.email
    into previous_receipt
  from public.crm_external_lead_receipts receipt
  join public.crm_leads lead on lead.id = receipt.lead_id
  join public.profiles profile on profile.id = lead.owner_id
  where receipt.provider = p_provider and receipt.origin_lead_id = trim(p_origin_lead_id);
  
  if previous_receipt.lead_id is not null then
    return query select previous_receipt.lead_id, previous_receipt.owner_id, coalesce(nullif(previous_receipt.full_name, ''), previous_receipt.email), true;
    return;
  end if;

  lead_type_value := case upper(trim(coalesce(p_transaction_type, '')))
    when 'RENT' then 'Aluguel' when 'SELL' then 'Venda' else null end;
    
  if lead_type_value is null then
     lead_type_value := case 
        when p_transaction_type ilike '%aluguel%' then 'Aluguel'
        when p_transaction_type ilike '%venda%' then 'Venda'
        else 'Venda'
     end;
  end if;

  perform pg_advisory_xact_lock(hashtext('lead-distribution:' || lead_type_value));

  selected_property_id := nullif(trim(p_client_listing_id), '');
  if selected_property_id is not null then
    select external_id, title, price, concat_ws(', ', nullif(trim(neighborhood), ''), nullif(trim(city), ''))
      into selected_property
    from public.crm_property_catalog where external_id = selected_property_id limit 1;
    if selected_property.external_id is not null then
      property_title_value := selected_property.title;
      desired_property_value := coalesce(selected_property.price, 0);
      desired_location_value := selected_property.concat_ws;
    end if;
  end if;

  select * into next_broker from public.get_next_property_lead_broker(selected_property_id, lead_type_value);

  if next_broker.broker_id is null then raise exception 'Não há corretores habilitados na fila de % para este lead.', lead_type_value; end if;

  normalized_phone := nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '');
  insert into public.crm_leads (name, phone, email, property_interest, stage, channel, budget, notes, owner_id, created_by, lead_type, desired_property_value, desired_location, external_id)
  values (coalesce(nullif(trim(p_name), ''), 'Lead sem nome'), normalized_phone, nullif(trim(p_email), ''), property_title_value,
    'Lead', p_channel, 0, nullif(trim(p_message), ''), next_broker.broker_id, next_broker.broker_id,
    lead_type_value, desired_property_value, desired_location_value, selected_property_id) returning id into inserted_lead;
    
  insert into public.crm_external_lead_receipts(provider, origin_lead_id, lead_id, payload)
    values (p_provider, trim(p_origin_lead_id), inserted_lead, coalesce(p_payload, '{}'::jsonb));
    
  return query select inserted_lead, next_broker.broker_id, coalesce(nullif(next_broker.full_name, ''), next_broker.email), false;
end;
$$;

commit;

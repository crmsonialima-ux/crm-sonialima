-- Recebimentos idempotentes de leads enviados pelo padrão VRSYNC/Grupo OLX.
create table if not exists public.crm_external_lead_receipts (
  provider text not null,
  origin_lead_id text not null,
  lead_id uuid not null references public.crm_leads(id) on delete cascade,
  received_at timestamptz not null default now(),
  payload jsonb not null default '{}'::jsonb,
  primary key (provider, origin_lead_id)
);

alter table public.crm_external_lead_receipts enable row level security;
grant select on public.crm_external_lead_receipts to authenticated;
create policy "Admins read external lead receipts"
  on public.crm_external_lead_receipts for select
  using (public.is_admin());

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
language plpgsql
security definer
set search_path = public
as $$
declare
  selected_property record;
  next_broker record;
  previous_receipt record;
  next_position integer;
  lead_type_value text;
  has_restricted_brokers boolean := false;
  inserted_lead uuid;
  normalized_phone text;
  property_title_value text;
  desired_location_value text;
  selected_property_id text;
  desired_property_value numeric := 0;
begin
  if nullif(trim(p_origin_lead_id), '') is null then
    raise exception 'originLeadId é obrigatório.';
  end if;

  perform pg_advisory_xact_lock(hashtext('zap-vrsync:' || trim(p_origin_lead_id)));
  select receipt.lead_id, lead.owner_id, profile.full_name, profile.email
  into previous_receipt
  from public.crm_external_lead_receipts receipt
  join public.crm_leads lead on lead.id = receipt.lead_id
  join public.profiles profile on profile.id = lead.owner_id
  where receipt.provider = 'grupo-olx'
    and receipt.origin_lead_id = trim(p_origin_lead_id);

  if previous_receipt.lead_id is not null then
    return query select previous_receipt.lead_id, previous_receipt.owner_id,
      coalesce(nullif(previous_receipt.full_name, ''), previous_receipt.email), true;
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
    select external_id, title, address, neighborhood, city, purpose, value
    into selected_property
    from public.crm_property_catalog
    where external_id = trim(p_client_listing_id);

    if selected_property.external_id is null then
      raise exception 'clientListingId não encontrado no catálogo do CRM: %', trim(p_client_listing_id);
    end if;
    selected_property_id := selected_property.external_id;
    property_title_value := selected_property.title;
    desired_property_value := coalesce(selected_property.value, 0);
    desired_location_value := nullif(concat_ws(', ', selected_property.neighborhood, selected_property.city, selected_property.address), '');
    has_restricted_brokers := exists (
      select 1 from public.crm_property_broker_access access
      where access.property_id = selected_property_id
    );
  elsif upper(trim(coalesce(p_lead_origin, ''))) = 'MCMV_OLX' then
    property_title_value := 'Simulação Minha Casa Minha Vida';
    desired_location_value := null;
  else
    raise exception 'clientListingId é obrigatório para leads de anúncio.';
  end if;

  perform pg_advisory_xact_lock(hashtext('lead-distribution:' || lead_type_value));
  select queue.broker_id, profile.full_name, profile.email
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
        where access.property_id = selected_property_id
          and access.broker_id = queue.broker_id
      )
    )
  order by queue.position
  limit 1
  for update of queue skip locked;

  if next_broker.broker_id is null then
    raise exception 'Não há corretores habilitados na fila de % para este lead.', lead_type_value;
  end if;

  select coalesce(max(position), 0) + 1 into next_position
  from public.lead_distribution_queue
  where lead_type = lead_type_value;
  update public.lead_distribution_queue
  set position = next_position, updated_at = now()
  where lead_type = lead_type_value and broker_id = next_broker.broker_id;

  normalized_phone := nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '');
  insert into public.crm_leads (
    name, phone, email, property_interest, stage, channel, budget, notes, owner_id, created_by,
    lead_type, desired_property_value, desired_location
  ) values (
    coalesce(nullif(trim(p_name), ''), 'Lead sem nome'), normalized_phone, nullif(trim(p_email), ''),
    property_title_value, 'Lead', 'Grupo OLX — W Imóveis', 0,
    nullif(trim(p_message), ''), next_broker.broker_id, next_broker.broker_id,
    lead_type_value, desired_property_value, desired_location_value
  ) returning id into inserted_lead;

  insert into public.crm_external_lead_receipts (provider, origin_lead_id, lead_id, payload)
  values ('grupo-olx', trim(p_origin_lead_id), inserted_lead, coalesce(p_payload, '{}'::jsonb));

  return query select inserted_lead, next_broker.broker_id,
    coalesce(nullif(next_broker.full_name, ''), next_broker.email), false;
end;
$$;

revoke all on function public.create_zap_vrsync_lead(text, text, text, text, text, text, text, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.create_zap_vrsync_lead(text, text, text, text, text, text, text, text, jsonb)
  to service_role;

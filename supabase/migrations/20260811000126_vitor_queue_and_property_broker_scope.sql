begin;

-- Every automatic distribution linked to a catalog property is restricted to
-- that property's explicit broker list. An empty list blocks distribution.
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
  next_position integer;
  inserted_lead uuid;
  normalized_phone text;
  selected_property_id text;
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
  where lower(catalog.title) = lower(trim(p_property_interest))
     or lower(coalesce(catalog.address, '')) = lower(trim(p_property_interest))
  order by catalog.updated_at desc
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

  select queue.broker_id, profile.full_name, profile.email
  into next_broker
  from public.lead_distribution_queue as queue
  join public.profiles as profile on profile.id = queue.broker_id
  where queue.lead_type = p_lead_type
    and profile.role = 'broker'
    and not coalesce(profile.lead_distribution_blocked, false)
    and (
      selected_property_id is null
      or exists (
        select 1
        from public.crm_property_broker_access as access
        where access.property_id = selected_property_id
          and access.broker_id = queue.broker_id
      )
    )
  order by queue.position
  limit 1
  for update of queue skip locked;

  if next_broker.broker_id is null then
    if selected_property_id is not null then
      raise exception 'Nenhum corretor selecionado neste imovel esta habilitado na fila de %.', p_lead_type;
    end if;
    raise exception 'Nao ha corretores habilitados na fila de %.', p_lead_type;
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

  insert into public.crm_leads (
    name,
    phone,
    email,
    property_interest,
    property_catalog_id,
    stage,
    channel,
    budget,
    notes,
    owner_id,
    created_by,
    external_id,
    lead_type,
    desired_property_value,
    desired_location
  ) values (
    trim(p_name),
    nullif(trim(p_phone), ''),
    nullif(trim(p_email), ''),
    nullif(trim(p_property_interest), ''),
    selected_property_id,
    p_stage,
    nullif(trim(p_channel), ''),
    0,
    nullif(trim(p_notes), ''),
    next_broker.broker_id,
    auth.uid(),
    nullif(trim(p_external_id), ''),
    p_lead_type,
    p_desired_property_value,
    trim(p_desired_location)
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

create or replace function public.create_vitor_distributed_lead_with_phones(
  p_name text,
  p_phone text,
  p_additional_phones text[],
  p_email text,
  p_property_interest text,
  p_stage text,
  p_channel text,
  p_notes text,
  p_lead_type text,
  p_desired_property_value numeric,
  p_desired_location text,
  p_visit_scheduled_at timestamptz default null
)
returns table (lead_id uuid, assigned_owner_id uuid, assigned_owner_name text)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  current_profile public.profiles%rowtype;
  created_lead record;
begin
  select profile.*
  into current_profile
  from public.profiles as profile
  where profile.id = auth.uid();

  if not found
     or current_profile.role <> 'broker'
     or lower(trim(current_profile.email)) <> 'unassigned-operator@example.invalid' then
    raise exception 'Somente o Vitor pode escolher esta distribuicao.';
  end if;
  if p_visit_scheduled_at is not null then
    raise exception 'Lead enviado a fila nao pode iniciar com visita agendada.';
  end if;

  select *
  into created_lead
  from public.create_distributed_lead(
    p_name,
    p_phone,
    p_email,
    p_property_interest,
    'Aguardando atendimento',
    p_channel,
    p_notes,
    '',
    p_lead_type,
    p_desired_property_value,
    p_desired_location
  );

  update public.crm_leads as lead
  set additional_phones = coalesce(p_additional_phones, '{}'::text[])
  where lead.id = created_lead.lead_id;

  return query
  select created_lead.lead_id,
         created_lead.assigned_owner_id,
         created_lead.assigned_owner_name;
end;
$$;

revoke all on function public.create_vitor_distributed_lead_with_phones(
  text, text, text[], text, text, text, text, text, text, numeric, text, timestamptz
) from public, anon;
grant execute on function public.create_vitor_distributed_lead_with_phones(
  text, text, text[], text, text, text, text, text, text, numeric, text, timestamptz
) to authenticated;

commit;

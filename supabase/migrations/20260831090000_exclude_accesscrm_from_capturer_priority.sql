begin;

-- AcessoCRM participates in the Venda queue as a regular broker even when it
-- is registered as a property capturer. Every other capturer keeps the 2:1
-- property roulette (two leads to the capturer, one to the normal queue).
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
  selected_broker_id uuid;
  selected_full_name text;
  selected_email text;
  next_position integer;
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
    from public.crm_property_capturer_assignments assignment
    join public.profiles profile on profile.id = assignment.broker_id
    join public.crm_property_broker_access access
      on access.broker_id = assignment.broker_id
     and access.property_id = assignment.property_id
    where assignment.property_id = normalized_property_id
      and profile.role = 'broker'
      and lower(trim(profile.email)) <> 'unassigned-institutional@example.invalid'
      and not coalesce(profile.lead_distribution_blocked, false)
      and (
        profile.lead_distribution_blocked_until is null
        or profile.lead_distribution_blocked_until <= now()
      )
    order by assignment.created_at, assignment.broker_id
    limit 1;
  end if;

  if primary_capturer_id is not null then
    insert into public.crm_property_lead_roulette(property_id)
    values (normalized_property_id)
    on conflict (property_id) do nothing;

    select state.*
    into roulette_state
    from public.crm_property_lead_roulette state
    where state.property_id = normalized_property_id
    for update;

    if roulette_state.captador_round then
      select profile.id, profile.full_name, profile.email
      into selected_broker_id, selected_full_name, selected_email
      from public.profiles profile
      where profile.id = primary_capturer_id;

      if selected_broker_id is null then
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
      select selected_broker_id, selected_full_name, selected_email;
      return;
    end if;

    select queue.broker_id, profile.full_name, profile.email
    into selected_broker_id, selected_full_name, selected_email
    from public.lead_distribution_queue queue
    join public.profiles profile on profile.id = queue.broker_id
    join public.crm_property_broker_access access
      on access.property_id = normalized_property_id
     and access.broker_id = queue.broker_id
    where queue.lead_type = p_lead_type
      and (
        profile.role = 'broker'
        or (
          p_lead_type = 'Venda'
          and lower(trim(profile.email)) = 'unassigned-institutional@example.invalid'
        )
      )
      and not coalesce(profile.lead_distribution_blocked, false)
      and (
        profile.lead_distribution_blocked_until is null
        or profile.lead_distribution_blocked_until <= now()
      )
      and queue.broker_id <> primary_capturer_id
    order by queue.position
    limit 1
    for update of queue skip locked;

    if selected_broker_id is null then
      raise exception 'Nao ha outro corretor elegivel na esteira deste imovel alem do captador.';
    end if;

    select coalesce(max(queue.position), 0) + 1
    into next_position
    from public.lead_distribution_queue queue
    where queue.lead_type = p_lead_type;

    update public.lead_distribution_queue queue
    set position = next_position,
        updated_at = now()
    where queue.lead_type = p_lead_type
      and queue.broker_id = selected_broker_id;

    update public.crm_property_lead_roulette
    set captador_round = true,
        captador_leads_delivered = 0,
        queue_leads_delivered = 0,
        updated_at = now()
    where property_id = normalized_property_id;

    return query
    select selected_broker_id, selected_full_name, selected_email;
    return;
  end if;

  if normalized_property_id is null then
    select queue.broker_id, profile.full_name, profile.email
    into selected_broker_id, selected_full_name, selected_email
    from public.lead_distribution_queue queue
    join public.profiles profile on profile.id = queue.broker_id
    where queue.lead_type = p_lead_type
      and (
        profile.role = 'broker'
        or (
          p_lead_type = 'Venda'
          and lower(trim(profile.email)) = 'unassigned-institutional@example.invalid'
        )
      )
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
    into selected_broker_id, selected_full_name, selected_email
    from public.lead_distribution_queue queue
    join public.profiles profile on profile.id = queue.broker_id
    join public.crm_property_broker_access access
      on access.property_id = normalized_property_id
     and access.broker_id = queue.broker_id
    where queue.lead_type = p_lead_type
      and (
        profile.role = 'broker'
        or (
          p_lead_type = 'Venda'
          and lower(trim(profile.email)) = 'unassigned-institutional@example.invalid'
        )
      )
      and not coalesce(profile.lead_distribution_blocked, false)
      and (
        profile.lead_distribution_blocked_until is null
        or profile.lead_distribution_blocked_until <= now()
      )
    order by queue.position
    limit 1
    for update of queue skip locked;
  end if;

  if selected_broker_id is null then return; end if;

  select coalesce(max(queue.position), 0) + 1
  into next_position
  from public.lead_distribution_queue queue
  where queue.lead_type = p_lead_type;

  update public.lead_distribution_queue queue
  set position = next_position,
      updated_at = now()
  where queue.lead_type = p_lead_type
    and queue.broker_id = selected_broker_id;

  return query
  select selected_broker_id, selected_full_name, selected_email;
end;
$$;

revoke all on function public.get_next_property_lead_broker(text, text)
  from public, anon;
grant execute on function public.get_next_property_lead_broker(text, text)
  to authenticated, service_role;

-- If AcessoCRM is the only capturer, leave a clean roulette state in case a
-- regular capturer is assigned to the property later.
update public.crm_property_lead_roulette roulette
set captador_round = true,
    captador_leads_delivered = 0,
    queue_leads_delivered = 0,
    updated_at = now()
where exists (
  select 1
  from public.crm_property_capturer_assignments assignment
  join public.profiles profile on profile.id = assignment.broker_id
  where assignment.property_id = roulette.property_id
    and lower(trim(profile.email)) = 'unassigned-institutional@example.invalid'
)
and not exists (
  select 1
  from public.crm_property_capturer_assignments assignment
  join public.profiles profile on profile.id = assignment.broker_id
  where assignment.property_id = roulette.property_id
    and lower(trim(profile.email)) <> 'unassigned-institutional@example.invalid'
);

commit;

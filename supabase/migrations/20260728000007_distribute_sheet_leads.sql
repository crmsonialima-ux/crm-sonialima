-- Distribui um lead novo originado na planilha usando a mesma fila contínua.
create or replace function public.import_sheet_lead_with_distribution(
  p_external_id text,
  p_name text,
  p_phone text,
  p_property_interest text,
  p_stage text,
  p_channel text,
  p_notes text,
  p_lead_type text
)
returns table (lead_id uuid, assigned_owner_name text)
language plpgsql
security definer
set search_path = public
as $$
declare
  next_broker record;
  next_position integer;
  inserted_lead uuid;
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores podem sincronizar leads da planilha.';
  end if;
  if nullif(p_external_id, '') is null then
    raise exception 'O identificador do lead da planilha é obrigatório.';
  end if;
  if p_lead_type not in ('Venda', 'Aluguel') then
    raise exception 'Tipo de lead inválido.';
  end if;

  select id into inserted_lead
  from public.crm_leads
  where external_id = p_external_id;
  if inserted_lead is not null then
    return query
      select lead.id, coalesce(profile.full_name, profile.email)
      from public.crm_leads as lead
      join public.profiles as profile on profile.id = lead.owner_id
      where lead.id = inserted_lead;
    return;
  end if;

  perform pg_advisory_xact_lock(hashtext('lead-distribution:' || p_lead_type));
  select queue.broker_id, profile.full_name, profile.email
  into next_broker
  from public.lead_distribution_queue as queue
  join public.profiles as profile on profile.id = queue.broker_id
  where queue.lead_type = p_lead_type and profile.role = 'broker'
  order by queue.position
  limit 1
  for update of queue skip locked;
  if next_broker.broker_id is null then
    raise exception 'Não há corretores ativos na fila de %.', p_lead_type;
  end if;

  select coalesce(max(position), 0) + 1 into next_position
  from public.lead_distribution_queue
  where lead_type = p_lead_type;
  update public.lead_distribution_queue
  set position = next_position, updated_at = now()
  where lead_type = p_lead_type and broker_id = next_broker.broker_id;

  insert into public.crm_leads (
    name, phone, property_interest, stage, channel, budget, notes,
    owner_id, created_by, external_id, lead_type
  ) values (
    p_name, nullif(p_phone, ''), nullif(p_property_interest, ''), p_stage,
    nullif(p_channel, ''), 0, nullif(p_notes, ''), next_broker.broker_id,
    auth.uid(), p_external_id, p_lead_type
  ) returning id into inserted_lead;

  return query select
    inserted_lead,
    coalesce(nullif(next_broker.full_name, ''), next_broker.email);
end;
$$;

grant execute on function public.import_sheet_lead_with_distribution(text, text, text, text, text, text, text, text)
  to authenticated;

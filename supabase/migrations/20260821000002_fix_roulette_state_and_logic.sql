begin;

-- Limpar a tabela para resetar o estado dos testes
drop table if exists public.crm_property_lead_roulette cascade;
create table public.crm_property_lead_roulette (
  property_id text primary key,
  captador_round boolean not null default true,
  captador_leads_delivered int not null default 0,
  queue_leads_delivered int not null default 0,
  updated_at timestamptz not null default now()
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

  -- Obter captador do imóvel
  if p_property_id is not null and trim(p_property_id) <> '' then
    select array_agg(c.broker_id order by c.created_at asc) into v_captadores
    from public.crm_property_capturer_assignments c
    where c.property_id = p_property_id;
  else
    v_captadores := array[]::uuid[];
  end if;

  -- Se tem captador e a fila está rodando
  if array_length(v_captadores, 1) is not null and v_queue_size > 0 then
    insert into public.crm_property_lead_roulette (property_id)
    values (p_property_id)
    on conflict do nothing;

    select * into v_state
    from public.crm_property_lead_roulette
    where property_id = p_property_id
    for update;

    if v_state.captador_round then
      -- Round do Captador (sempre o primeiro captador recebe 2 leads)
      v_target_broker_id := v_captadores[1];
      
      if v_state.captador_leads_delivered = 0 then
        update public.crm_property_lead_roulette
        set captador_leads_delivered = 1
        where property_id = p_property_id;
      else
        update public.crm_property_lead_roulette
        set captador_leads_delivered = 0, captador_round = false, queue_leads_delivered = 0
        where property_id = p_property_id;
      end if;
    else
      -- Round da Fila (rodar por todos os corretores da fila)
      if v_state.queue_leads_delivered < v_queue_size - 1 then
        update public.crm_property_lead_roulette
        set queue_leads_delivered = queue_leads_delivered + 1
        where property_id = p_property_id;
      else
        update public.crm_property_lead_roulette
        set queue_leads_delivered = 0, captador_round = true, captador_leads_delivered = 0
        where property_id = p_property_id;
      end if;
      v_target_broker_id := null;
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

commit;

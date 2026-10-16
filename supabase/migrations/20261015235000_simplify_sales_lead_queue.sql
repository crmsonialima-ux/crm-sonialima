begin;

-- A fila de Venda é única e não depende mais de captador, imóvel, rodadas,
-- prazo ou bloqueio automático. Somente a desativação manual feita por
-- crmallyson pode retirar alguém da fila.
update public.profiles
set lead_distribution_blocked = coalesce(lead_distribution_manually_disabled, false),
    lead_distribution_blocked_reason = case
      when coalesce(lead_distribution_manually_disabled, false)
        then 'Desativado manualmente da fila pelo crmallyson'
      else null
    end,
    lead_distribution_blocked_at = case
      when coalesce(lead_distribution_manually_disabled, false) then lead_distribution_blocked_at
      else null
    end,
    lead_distribution_blocked_until = null;

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
  next_broker record;
  next_position integer;
  crmallyson_id constant uuid := '37094db7-2457-48f2-8573-40c887e547e5';
begin
  -- p_property_id permanece na assinatura para compatibilidade, mas não é
  -- usado: todo lead distribuído segue a mesma fila geral de vendas.
  if p_lead_type <> 'Venda' then
    return;
  end if;

  perform pg_advisory_xact_lock(hashtext('lead-distribution:' || p_lead_type));

  select queue.broker_id, profile.full_name, profile.email
  into next_broker
  from public.lead_distribution_queue as queue
  join public.profiles as profile on profile.id = queue.broker_id
  where queue.lead_type = p_lead_type
    and (profile.role = 'broker' or profile.id = crmallyson_id)
    and not coalesce(profile.lead_distribution_manually_disabled, false)
  order by queue.position
  limit 1
  for update of queue skip locked;

  if next_broker.broker_id is null then
    return;
  end if;

  select coalesce(max(queue.position), 0) + 1
  into next_position
  from public.lead_distribution_queue as queue
  where queue.lead_type = p_lead_type;

  update public.lead_distribution_queue as queue
  set position = next_position, updated_at = now()
  where queue.lead_type = p_lead_type
    and queue.broker_id = next_broker.broker_id;

  return query
  select next_broker.broker_id::uuid, next_broker.full_name::text, next_broker.email::text;
end;
$$;

create or replace function public.set_broker_lead_queue_enabled(
  p_broker_id uuid,
  p_enabled boolean
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  crmallyson_id constant uuid := '37094db7-2457-48f2-8573-40c887e547e5';
begin
  if not public.is_allyson_admin() then
    raise exception 'Somente crmallyson pode alterar a participacao na fila.';
  end if;
  if not exists (
    select 1 from public.profiles as profile
    where profile.id = p_broker_id
      and (profile.role = 'broker' or profile.id = crmallyson_id)
  ) then
    raise exception 'Corretor nao encontrado.';
  end if;

  update public.profiles
  set lead_distribution_manually_disabled = not p_enabled,
      lead_distribution_blocked = not p_enabled,
      lead_distribution_blocked_reason = case
        when p_enabled then null else 'Desativado manualmente da fila pelo crmallyson'
      end,
      lead_distribution_blocked_at = case
        when p_enabled then null else now()
      end,
      lead_distribution_blocked_until = null,
      updated_at = now()
  where id = p_broker_id;
end;
$$;

revoke all on function public.get_next_property_lead_broker(text, text) from public, anon;
grant execute on function public.get_next_property_lead_broker(text, text) to authenticated, service_role;
revoke all on function public.set_broker_lead_queue_enabled(uuid, boolean) from public, anon;
grant execute on function public.set_broker_lead_queue_enabled(uuid, boolean) to authenticated, service_role;

commit;

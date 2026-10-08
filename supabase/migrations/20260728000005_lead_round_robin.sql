-- Duas filas independentes: Venda e Aluguel.
alter table public.crm_leads
  add column if not exists lead_type text not null default 'Venda'
  check (lead_type in ('Venda', 'Aluguel'));

create table if not exists public.lead_distribution_queue (
  id uuid primary key default gen_random_uuid(),
  lead_type text not null check (lead_type in ('Venda', 'Aluguel')),
  broker_id uuid not null references public.profiles(id) on delete cascade,
  position integer not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (lead_type, broker_id),
  unique (lead_type, position)
);

create index if not exists lead_distribution_queue_type_position_idx
  on public.lead_distribution_queue(lead_type, position);

insert into public.lead_distribution_queue (lead_type, broker_id, position)
select
  types.lead_type,
  profiles.id,
  row_number() over (partition by types.lead_type order by profiles.created_at, profiles.id)::integer
from public.profiles
cross join (values ('Venda'::text), ('Aluguel'::text)) as types(lead_type)
where profiles.role = 'broker'
on conflict (lead_type, broker_id) do nothing;

alter table public.lead_distribution_queue enable row level security;
grant select on public.lead_distribution_queue to authenticated;

create policy "Authenticated users read lead distribution"
  on public.lead_distribution_queue for select
  using (auth.uid() is not null);

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
  next_position integer;
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

  select queue.broker_id, profile.full_name, profile.email
  into next_broker
  from public.lead_distribution_queue as queue
  join public.profiles as profile on profile.id = queue.broker_id
  where queue.lead_type = p_lead_type
    and profile.role = 'broker'
  order by queue.position
  limit 1
  for update of queue skip locked;

  if next_broker.broker_id is null then
    raise exception 'Não há corretores ativos na fila de %.', p_lead_type;
  end if;

  select coalesce(max(position), 0) + 1
  into next_position
  from public.lead_distribution_queue
  where lead_type = p_lead_type;

  update public.lead_distribution_queue
  set position = next_position, updated_at = now()
  where lead_type = p_lead_type and broker_id = next_broker.broker_id;

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

grant execute on function public.create_distributed_lead(text, text, text, text, text, text, text, text, text)
  to authenticated;

create or replace function public.link_distributed_lead_external(p_lead_id uuid, p_external_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.crm_leads
  set external_id = nullif(p_external_id, '')
  where id = p_lead_id and created_by = auth.uid();
  if not found then
    raise exception 'Lead não encontrado para vincular à planilha.';
  end if;
end;
$$;

grant execute on function public.link_distributed_lead_external(uuid, text) to authenticated;

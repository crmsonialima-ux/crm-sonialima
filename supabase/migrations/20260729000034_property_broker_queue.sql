-- Lista de corretores habilitados pelo administrador para cada imóvel.
create table if not exists public.crm_property_broker_access (
  property_id text not null,
  broker_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (property_id, broker_id)
);

alter table public.crm_property_broker_access enable row level security;
grant select on public.crm_property_broker_access to authenticated;
create policy "Authenticated users read property broker access"
  on public.crm_property_broker_access for select
  using (auth.uid() is not null);

create or replace function public.sync_property_broker_access(
  p_property_id text,
  p_broker_names text[]
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores podem definir os corretores habilitados do imóvel.';
  end if;

  delete from public.crm_property_broker_access
  where property_id = p_property_id;

  insert into public.crm_property_broker_access (property_id, broker_id)
  select distinct p_property_id, profiles.id
  from public.profiles
  where profiles.role = 'broker'
    and profiles.full_name = any(p_broker_names);

  if cardinality(coalesce(p_broker_names, array[]::text[])) > 0
     and not exists (select 1 from public.crm_property_broker_access where property_id = p_property_id) then
    raise exception 'Nenhum corretor selecionado foi encontrado no Supabase.';
  end if;
end;
$$;

grant execute on function public.sync_property_broker_access(text, text[]) to authenticated;

-- Quando o imóvel possuir corretores habilitados, a fila de Venda ou Aluguel
-- considera exclusivamente esses corretores.
create or replace function public.create_distributed_lead(
  p_name text, p_phone text, p_email text, p_property_interest text, p_stage text,
  p_channel text, p_notes text, p_external_id text, p_lead_type text,
  p_desired_property_value numeric, p_desired_location text
)
returns table (lead_id uuid, assigned_owner_id uuid, assigned_owner_name text)
language plpgsql security definer set search_path = public as $$
declare
  next_broker record;
  next_position integer;
  inserted_lead uuid;
  normalized_phone text;
  selected_property_id text;
  has_restricted_brokers boolean := false;
begin
  if auth.uid() is null then raise exception 'Sessão não encontrada.'; end if;
  if p_lead_type not in ('Venda', 'Aluguel') then raise exception 'Tipo de lead inválido.'; end if;
  if coalesce(p_desired_property_value, 0) <= 0 then raise exception 'Informe o valor médio do imóvel desejado.'; end if;
  if nullif(trim(p_desired_location), '') is null then raise exception 'Informe a localização desejada.'; end if;

  select external_id into selected_property_id
  from public.crm_property_catalog
  where lower(title) = lower(trim(p_property_interest))
     or lower(coalesce(address, '')) = lower(trim(p_property_interest))
  order by updated_at desc
  limit 1;

  has_restricted_brokers := selected_property_id is not null
    and exists (
      select 1 from public.crm_property_broker_access
      where property_id = selected_property_id
    );

  perform pg_advisory_xact_lock(hashtext('lead-distribution:' || p_lead_type));
  normalized_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if normalized_phone = '' then raise exception 'Telefone é obrigatório.'; end if;
  perform pg_advisory_xact_lock(hashtext(normalized_phone));
  if exists (select 1 from public.crm_leads where regexp_replace(coalesce(phone, ''), '\D', '', 'g') = normalized_phone) then
    raise exception 'Já existe um lead cadastrado com este telefone.';
  end if;

  select q.broker_id, p.full_name, p.email into next_broker
  from public.lead_distribution_queue q
  join public.profiles p on p.id = q.broker_id
  where q.lead_type = p_lead_type
    and p.role = 'broker'
    and not coalesce(p.lead_distribution_blocked, false)
    and (
      not has_restricted_brokers
      or exists (
        select 1 from public.crm_property_broker_access access
        where access.property_id = selected_property_id and access.broker_id = q.broker_id
      )
    )
  order by q.position
  limit 1 for update of q skip locked;

  if next_broker.broker_id is null then
    raise exception 'Não há corretores habilitados para este imóvel na fila de %.', p_lead_type;
  end if;

  select coalesce(max(position), 0) + 1 into next_position
  from public.lead_distribution_queue where lead_type = p_lead_type;
  update public.lead_distribution_queue set position = next_position, updated_at = now()
  where lead_type = p_lead_type and broker_id = next_broker.broker_id;

  insert into public.crm_leads (
    name, phone, email, property_interest, stage, channel, budget, notes, owner_id, created_by,
    external_id, lead_type, desired_property_value, desired_location
  ) values (
    p_name, nullif(p_phone, ''), nullif(p_email, ''), nullif(p_property_interest, ''), p_stage,
    nullif(p_channel, ''), 0, nullif(p_notes, ''), next_broker.broker_id, auth.uid(),
    nullif(p_external_id, ''), p_lead_type, p_desired_property_value, trim(p_desired_location)
  ) returning id into inserted_lead;

  return query select inserted_lead, next_broker.broker_id,
    coalesce(nullif(next_broker.full_name, ''), next_broker.email);
end;
$$;

grant execute on function public.create_distributed_lead(
  text, text, text, text, text, text, text, text, text, numeric, text
) to authenticated;

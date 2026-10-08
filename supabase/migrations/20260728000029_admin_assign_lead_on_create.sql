-- Permite que apenas o administrador escolha diretamente o corretor de um novo lead.
-- A fila nao e movimentada neste caso; a opcao automatica continua usando create_distributed_lead.
create or replace function public.create_admin_assigned_lead(
  p_name text,
  p_phone text,
  p_email text,
  p_property_interest text,
  p_stage text,
  p_channel text,
  p_notes text,
  p_lead_type text,
  p_desired_property_value numeric,
  p_desired_location text,
  p_owner_id uuid
)
returns table (lead_id uuid, assigned_owner_id uuid, assigned_owner_name text)
language plpgsql
security definer
set search_path = public
as $$
declare
  selected_broker record;
  inserted_lead uuid;
  normalized_phone text;
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores podem definir o corretor responsavel.';
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

  normalized_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if normalized_phone = '' then
    raise exception 'Telefone e obrigatorio.';
  end if;
  perform pg_advisory_xact_lock(hashtext(normalized_phone));
  if exists (
    select 1
    from public.crm_leads
    where regexp_replace(coalesce(phone, ''), '\D', '', 'g') = normalized_phone
  ) then
    raise exception 'Ja existe um lead cadastrado com este telefone.';
  end if;

  select id, full_name, email
  into selected_broker
  from public.profiles
  where id = p_owner_id
    and role = 'broker'
    and not coalesce(lead_distribution_blocked, false);

  if selected_broker.id is null then
    raise exception 'Corretor indisponivel ou nao encontrado.';
  end if;

  insert into public.crm_leads (
    name, phone, email, property_interest, stage, channel, budget, notes,
    owner_id, created_by, lead_type, desired_property_value, desired_location
  ) values (
    trim(p_name), nullif(trim(p_phone), ''), nullif(trim(p_email), ''),
    nullif(trim(p_property_interest), ''), p_stage, nullif(trim(p_channel), ''), 0,
    nullif(p_notes, ''), selected_broker.id, auth.uid(), p_lead_type,
    p_desired_property_value, trim(p_desired_location)
  ) returning id into inserted_lead;

  return query select
    inserted_lead,
    selected_broker.id,
    coalesce(nullif(selected_broker.full_name, ''), selected_broker.email);
end;
$$;

grant execute on function public.create_admin_assigned_lead(
  text, text, text, text, text, text, text, text, numeric, text, uuid
) to authenticated;

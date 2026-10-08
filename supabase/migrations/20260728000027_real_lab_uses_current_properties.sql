-- O teste real usa um imovel existente do catalogo atual, sem alterar o cadastro do imovel.
create or replace function public.start_real_assignment_test(p_lead_type text default 'Venda')
returns table (lead_id uuid, assigned_email text, queue_emails text[], deadline_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  next_broker record;
  next_position integer;
  created_lead_id uuid;
  fake_phone text;
  snapshot_emails text[];
  test_property record;
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores podem iniciar o Laboratorio.';
  end if;
  if p_lead_type not in ('Venda', 'Aluguel') then
    raise exception 'Esteira de teste invalida.';
  end if;

  select external_id, title, address, neighborhood, city, purpose, value
  into test_property
  from public.crm_property_catalog
  where lower(coalesce(purpose, '')) = lower(p_lead_type)
  order by updated_at desc
  limit 1;
  if test_property.external_id is null then
    select external_id, title, address, neighborhood, city, purpose, value
    into test_property
    from public.crm_property_catalog
    order by updated_at desc
    limit 1;
  end if;
  if test_property.external_id is null then
    raise exception 'Nao ha imovel no catalogo para executar o teste.';
  end if;

  perform pg_advisory_xact_lock(hashtext('lead-distribution:' || p_lead_type));
  select q.broker_id, p.email
  into next_broker
  from public.lead_distribution_queue q
  join public.profiles p on p.id = q.broker_id
  where q.lead_type = p_lead_type
    and p.role = 'broker'
    and not coalesce(p.lead_distribution_blocked, false)
  order by q.position
  limit 1
  for update of q skip locked;
  if next_broker.broker_id is null then
    raise exception 'Nao ha corretor disponivel na fila de %.', p_lead_type;
  end if;

  select array_agg(p.email order by q.position)
  into snapshot_emails
  from public.lead_distribution_queue q
  join public.profiles p on p.id = q.broker_id
  where q.lead_type = p_lead_type
    and p.role = 'broker'
    and not coalesce(p.lead_distribution_blocked, false);

  select coalesce(max(position), 0) + 1
  into next_position
  from public.lead_distribution_queue
  where lead_type = p_lead_type;
  update public.lead_distribution_queue
  set position = next_position, updated_at = now()
  where lead_type = p_lead_type and broker_id = next_broker.broker_id;

  fake_phone := '619' || lpad((floor(random() * 100000000))::bigint::text, 8, '0');
  insert into public.crm_leads (
    name, phone, email, property_interest, stage, channel, budget, notes,
    owner_id, created_by, lead_type, desired_property_value, desired_location, is_test
  ) values (
    'TESTE - Esteira ' || p_lead_type || ' - ' || to_char(now(), 'YYYYMMDDHH24MISS'),
    fake_phone,
    'teste-' || extract(epoch from clock_timestamp())::bigint || '@teste.sonialima.local',
    test_property.title,
    'Aguardando atendimento',
    'Laboratorio',
    0,
    'Registro de teste real usando o imovel ' || test_property.title || '.',
    next_broker.broker_id,
    auth.uid(),
    p_lead_type,
    coalesce(test_property.value, 500000),
    coalesce(nullif(test_property.neighborhood, ''), nullif(test_property.city, ''), nullif(test_property.address, ''), test_property.title),
    true
  ) returning id into created_lead_id;

  update public.crm_notification_outbox
  set payload = payload || jsonb_build_object('test', true)
  where kind = 'lead_assignment' and payload ->> 'leadId' = created_lead_id::text;

  return query
  select
    created_lead_id,
    next_broker.email,
    snapshot_emails,
    (select assignment_deadline_at from public.crm_leads where id = created_lead_id);
end;
$$;

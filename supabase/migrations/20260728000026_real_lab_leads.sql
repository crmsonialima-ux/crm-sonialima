-- O Laboratório pode criar leads reais identificados como TESTE para validar a operação completa.
alter table public.crm_leads
  add column if not exists is_test boolean not null default false;

create index if not exists crm_leads_test_idx
  on public.crm_leads (created_at desc)
  where is_test = true;

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
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores podem iniciar o Laboratorio.';
  end if;
  if p_lead_type not in ('Venda', 'Aluguel') then
    raise exception 'Esteira de teste invalida.';
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

  -- Esta e a mesma rotacao usada ao cadastrar um lead real.
  update public.lead_distribution_queue
  set position = next_position, updated_at = now()
  where lead_type = p_lead_type and broker_id = next_broker.broker_id;

  fake_phone := '619' || lpad((floor(random() * 100000000))::bigint::text, 8, '0');
  insert into public.crm_leads (
    name, phone, email, property_interest, stage, channel, budget, notes,
    owner_id, created_by, lead_type, is_test
  ) values (
    'TESTE - Esteira ' || p_lead_type || ' - ' || to_char(now(), 'YYYYMMDDHH24MISS'),
    fake_phone,
    'teste-' || extract(epoch from clock_timestamp())::bigint || '@teste.sonialima.local',
    'IMOVEL TESTE - ' || p_lead_type,
    'Aguardando atendimento',
    'Laboratorio',
    0,
    'Registro criado pelo Laboratorio para testar distribuicao, prazos e notificacoes.',
    next_broker.broker_id,
    auth.uid(),
    p_lead_type,
    true
  ) returning id into created_lead_id;

  -- O trigger start_lead_assignment ja criou a notificacao real. Apenas marca o payload como teste.
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

create or replace function public.clear_real_lab_leads()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare deleted_count integer;
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores podem limpar os testes.';
  end if;
  delete from public.crm_notification_outbox where coalesce((payload ->> 'test')::boolean, false);
  delete from public.crm_leads where is_test = true;
  get diagnostics deleted_count = row_count;
  return deleted_count;
end;
$$;

grant execute on function public.start_real_assignment_test(text) to authenticated;
grant execute on function public.clear_real_lab_leads() to authenticated;

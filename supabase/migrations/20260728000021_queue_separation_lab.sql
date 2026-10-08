-- Teste seguro para validar que Venda e Aluguel usam filas independentes.
create or replace function public.start_queue_separation_test()
returns table (
  sale_broker_email text,
  rental_broker_email text,
  sale_brokers_count integer,
  rental_brokers_count integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  sale_broker record;
  rental_broker record;
  sale_count integer;
  rental_count integer;
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores podem iniciar o teste de filas.';
  end if;

  select q.broker_id, p.email
  into sale_broker
  from public.lead_distribution_queue q
  join public.profiles p on p.id = q.broker_id
  where q.lead_type = 'Venda'
    and p.role = 'broker'
    and not coalesce(p.lead_distribution_blocked, false)
  order by q.position
  limit 1;

  select q.broker_id, p.email
  into rental_broker
  from public.lead_distribution_queue q
  join public.profiles p on p.id = q.broker_id
  where q.lead_type = 'Aluguel'
    and p.role = 'broker'
    and not coalesce(p.lead_distribution_blocked, false)
  order by q.position
  limit 1;

  if sale_broker.broker_id is null then
    raise exception 'Não há corretor disponível na fila de Venda.';
  end if;
  if rental_broker.broker_id is null then
    raise exception 'Não há corretor disponível na fila de Aluguel.';
  end if;

  select count(*)::integer
  into sale_count
  from public.lead_distribution_queue q
  join public.profiles p on p.id = q.broker_id
  where q.lead_type = 'Venda'
    and p.role = 'broker'
    and not coalesce(p.lead_distribution_blocked, false);

  select count(*)::integer
  into rental_count
  from public.lead_distribution_queue q
  join public.profiles p on p.id = q.broker_id
  where q.lead_type = 'Aluguel'
    and p.role = 'broker'
    and not coalesce(p.lead_distribution_blocked, false);

  insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
  values
    (
      sale_broker.broker_id,
      'assignment_queue_separation_test',
      'Teste de fila: Venda',
      'Você é o próximo corretor da fila de Venda. Nenhum lead real foi criado.',
      '/laboratorio',
      jsonb_build_object('queue', 'Venda', 'test', true)
    ),
    (
      rental_broker.broker_id,
      'assignment_queue_separation_test',
      'Teste de fila: Aluguel',
      'Você é o próximo corretor da fila de Aluguel. Nenhum lead real foi criado.',
      '/laboratorio',
      jsonb_build_object('queue', 'Aluguel', 'test', true)
    );

  return query
  select sale_broker.email, rental_broker.email, sale_count, rental_count;
end;
$$;

grant execute on function public.start_queue_separation_test() to authenticated;

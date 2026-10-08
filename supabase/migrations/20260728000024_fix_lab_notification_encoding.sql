-- Usa chr() nas mensagens para evitar mojibake entre editor SQL e notificações.
create or replace function public.start_assignment_notification_test()
returns table (run_id uuid, broker_emails text[], first_deadline_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare queue_ids uuid[]; queue_emails text[]; created_run uuid; notification_id uuid;
begin
  if not public.is_admin() then raise exception 'Apenas administradores podem iniciar o laboratorio.'; end if;
  if exists (select 1 from public.crm_assignment_test_runs where status = 'running') then
    raise exception 'Ja existe um teste de esteira em andamento.';
  end if;
  select array_agg(q.broker_id order by q.position), array_agg(p.email order by q.position)
  into queue_ids, queue_emails
  from public.lead_distribution_queue q
  join public.profiles p on p.id = q.broker_id
  where q.lead_type = 'Venda' and p.role = 'broker' and not coalesce(p.lead_distribution_blocked, false);
  if coalesce(array_length(queue_ids, 1), 0) = 0 then raise exception 'Nao ha corretores disponiveis na fila de Venda.'; end if;

  insert into public.crm_assignment_test_runs (broker_ids, broker_emails, next_deadline_at, created_by)
  values (queue_ids, queue_emails, now() + interval '15 minutes', auth.uid())
  returning id into created_run;
  insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
  values (
    queue_ids[1], 'assignment_lab',
    'Teste de esteira: voc' || chr(234) || ' ' || chr(233) || ' o primeiro',
    'Teste real: voc' || chr(234) || ' tem 15 minutos. Nenhum lead real ser' || chr(225) || ' alterado.',
    '/laboratorio', jsonb_build_object('runId', created_run, 'position', 1, 'windowMinutes', 15)
  ) returning id into notification_id;
  insert into public.crm_assignment_test_attempts (run_id, broker_id, position, deadline_at, notification_id)
  values (created_run, queue_ids[1], 1, now() + interval '15 minutes', notification_id);
  return query select created_run, queue_emails, now() + interval '15 minutes';
end;
$$;

create or replace function public.process_assignment_notification_tests()
returns void language plpgsql security definer set search_path = public as $$
declare run_row record; next_index integer; notification_id uuid;
begin
  for run_row in
    select * from public.crm_assignment_test_runs
    where status = 'running' and next_deadline_at <= now()
    for update skip locked
  loop
    next_index := run_row.current_index + 2;
    if next_index <= array_length(run_row.broker_ids, 1) then
      update public.crm_assignment_test_runs
      set current_index = next_index - 1, next_deadline_at = now() + interval '4 minutes'
      where id = run_row.id;
      insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
      values (
        run_row.broker_ids[next_index], 'assignment_lab', 'Teste de esteira: sua vez',
        'Teste real: voc' || chr(234) || ' tem 4 minutos. Nenhum lead real ser' || chr(225) || ' alterado.',
        '/laboratorio', jsonb_build_object('runId', run_row.id, 'position', next_index, 'windowMinutes', 4)
      ) returning id into notification_id;
      insert into public.crm_assignment_test_attempts (run_id, broker_id, position, deadline_at, notification_id)
      values (run_row.id, run_row.broker_ids[next_index], next_index, now() + interval '4 minutes', notification_id);
    else
      update public.crm_assignment_test_runs set status = 'completed', completed_at = now() where id = run_row.id;
      insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
      select id, 'assignment_lab_complete',
        'Teste de esteira conclu' || chr(237) || 'do',
        'Todos os corretores receberam a sequ' || chr(234) || 'ncia 15 min + 4 min. Nenhum lead real foi alterado.',
        '/laboratorio', jsonb_build_object('runId', run_row.id)
      from public.profiles where role = 'admin';
    end if;
  end loop;
end;
$$;

update public.crm_notification_outbox
set
  title = 'Teste de esteira: voc' || chr(234) || ' ' || chr(233) || ' o primeiro',
  body = 'Teste real: voc' || chr(234) || ' tem 15 minutos. Nenhum lead real ser' || chr(225) || ' alterado.'
where kind = 'assignment_lab' and payload ->> 'position' = '1';

update public.crm_notification_outbox
set
  title = 'Teste de esteira conclu' || chr(237) || 'do',
  body = 'Todos os corretores receberam a sequ' || chr(234) || 'ncia 15 min + 4 min. Nenhum lead real foi alterado.'
where kind = 'assignment_lab_complete';

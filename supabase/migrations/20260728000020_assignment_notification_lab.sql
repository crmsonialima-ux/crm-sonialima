-- Laboratório seguro: testa a sequência de notificações sem criar ou mover leads reais.
create table if not exists public.crm_assignment_test_runs (
  id uuid primary key default gen_random_uuid(),
  broker_ids uuid[] not null,
  broker_emails text[] not null,
  current_index integer not null default 0,
  status text not null default 'running' check (status in ('running', 'completed', 'cancelled')),
  next_deadline_at timestamptz not null,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

create table if not exists public.crm_assignment_test_attempts (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.crm_assignment_test_runs(id) on delete cascade,
  broker_id uuid not null references public.profiles(id),
  position integer not null,
  deadline_at timestamptz not null,
  notification_id uuid references public.crm_notification_outbox(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (run_id, position)
);

alter table public.crm_assignment_test_runs enable row level security;
alter table public.crm_assignment_test_attempts enable row level security;
grant select on public.crm_assignment_test_runs, public.crm_assignment_test_attempts to authenticated;
create policy "Admins read assignment lab runs" on public.crm_assignment_test_runs for select using (public.is_admin());
create policy "Admins read assignment lab attempts" on public.crm_assignment_test_attempts for select using (public.is_admin());

create or replace function public.start_assignment_notification_test()
returns table (run_id uuid, broker_emails text[], first_deadline_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare queue_ids uuid[]; queue_emails text[]; created_run uuid; notification_id uuid;
begin
  if not public.is_admin() then raise exception 'Apenas administradores podem iniciar o laboratório.'; end if;
  if exists (select 1 from public.crm_assignment_test_runs where status = 'running') then
    raise exception 'Já existe um teste de esteira em andamento.';
  end if;
  select array_agg(q.broker_id order by q.position), array_agg(p.email order by q.position)
  into queue_ids, queue_emails
  from public.lead_distribution_queue q
  join public.profiles p on p.id = q.broker_id
  where q.lead_type = 'Venda' and p.role = 'broker' and not coalesce(p.lead_distribution_blocked, false);
  if coalesce(array_length(queue_ids, 1), 0) = 0 then raise exception 'Não há corretores disponíveis na fila de Venda.'; end if;

  insert into public.crm_assignment_test_runs (broker_ids, broker_emails, next_deadline_at, created_by)
  values (queue_ids, queue_emails, now() + interval '15 minutes', auth.uid())
  returning id into created_run;

  insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
  values (
    queue_ids[1], 'assignment_lab', 'Teste de esteira: você é o primeiro',
    'Teste real: você tem 15 minutos. Nenhum lead real será alterado.', '/laboratorio',
    jsonb_build_object('runId', created_run, 'position', 1, 'windowMinutes', 15)
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
        'Teste real: você tem 4 minutos. Nenhum lead real será alterado.', '/laboratorio',
        jsonb_build_object('runId', run_row.id, 'position', next_index, 'windowMinutes', 4)
      ) returning id into notification_id;
      insert into public.crm_assignment_test_attempts (run_id, broker_id, position, deadline_at, notification_id)
      values (run_row.id, run_row.broker_ids[next_index], next_index, now() + interval '4 minutes', notification_id);
    else
      update public.crm_assignment_test_runs set status = 'completed', completed_at = now() where id = run_row.id;
      insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
      select id, 'assignment_lab_complete', 'Teste de esteira concluído',
        'Todos os corretores receberam a sequência 15 min + 4 min. Nenhum lead real foi alterado.',
        '/laboratorio', jsonb_build_object('runId', run_row.id)
      from public.profiles where role = 'admin';
    end if;
  end loop;
end;
$$;

grant execute on function public.start_assignment_notification_test() to authenticated;
grant execute on function public.process_assignment_notification_tests() to service_role;

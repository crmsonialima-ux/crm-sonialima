-- Lembretes centralizados do financiamento, uma ocorrencia por pendencia/usuario/dia util.

create table if not exists public.crm_financing_reminder_dispatches (
  id uuid primary key default gen_random_uuid(),
  process_id uuid not null references public.crm_financing_processes(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  reminder_kind text not null check (reminder_kind in (
    'checklist_pending','documentation_pending','conformity_restart','registry_details'
  )),
  cycle_key text not null default 'main',
  local_date date not null,
  notification_id uuid references public.crm_notification_outbox(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(process_id, recipient_id, reminder_kind, cycle_key, local_date)
);

create index if not exists crm_financing_reminders_process_idx
  on public.crm_financing_reminder_dispatches(process_id, created_at desc);

alter table public.crm_financing_reminder_dispatches enable row level security;
revoke all on public.crm_financing_reminder_dispatches from public, anon, authenticated;
grant select on public.crm_financing_reminder_dispatches to authenticated;

create policy "Financing reminder history follows process visibility"
  on public.crm_financing_reminder_dispatches for select
  using (public.can_view_financing(process_id));

insert into public.crm_notification_delivery_policies(kind, delivery_mode, rationale)
values
  ('financing_new', 'immediate', 'Novo financiamento precisa chegar imediatamente ao operador.'),
  ('financing_checklist_pending', 'immediate', 'O job central ja limita o lembrete a dias uteis as 09:00.'),
  ('financing_documentation_pending', 'immediate', 'O job central ja limita o lembrete a dias uteis as 09:00.'),
  ('financing_conformity_restart', 'immediate', 'O job central ja limita o lembrete a dias uteis as 09:00.'),
  ('financing_registry_details', 'immediate', 'O job central ja limita o lembrete a dias uteis as 09:00.')
on conflict (kind) do update
set delivery_mode=excluded.delivery_mode,
    rationale=excluded.rationale,
    updated_at=now();

create or replace function public.crm_financing_dispatch_reminder(
  p_process_id uuid,
  p_recipient_id uuid,
  p_reminder_kind text,
  p_cycle_key text,
  p_local_date date,
  p_title text,
  p_body text,
  p_notification_kind text
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  dispatch_id uuid;
  notification_id_value uuid;
  process_lead_id uuid;
begin
  insert into public.crm_financing_reminder_dispatches(
    process_id,recipient_id,reminder_kind,cycle_key,local_date
  ) values (
    p_process_id,p_recipient_id,p_reminder_kind,p_cycle_key,p_local_date
  ) on conflict do nothing returning id into dispatch_id;
  if dispatch_id is null then return false; end if;

  select lead_id into process_lead_id
  from public.crm_financing_processes where id=p_process_id;
  insert into public.crm_notification_outbox(recipient_id,kind,title,body,url,payload,available_at)
  values(
    p_recipient_id,p_notification_kind,p_title,p_body,
    '/financiamento?process='||p_process_id,
    jsonb_build_object('processId',p_process_id,'leadId',process_lead_id,'reminderKind',p_reminder_kind),
    now()
  ) returning id into notification_id_value;
  update public.crm_financing_reminder_dispatches
  set notification_id=notification_id_value where id=dispatch_id;
  return true;
end;
$$;

revoke all on function public.crm_financing_dispatch_reminder(uuid,uuid,text,text,date,text,text,text)
  from public, anon, authenticated;

create or replace function public.process_financing_reminders()
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  local_now timestamp := clock_timestamp() at time zone 'America/Sao_Paulo';
  local_day date := (clock_timestamp() at time zone 'America/Sao_Paulo')::date;
  process_record record;
  operator_record record;
  active_attempt record;
  sent_count integer := 0;
  sent boolean;
begin
  if extract(isodow from local_now) not between 1 and 5 or local_now::time < time '09:00' then
    return 0;
  end if;

  for process_record in
    select process.*, lead.name as lead_name
    from public.crm_financing_processes process
    join public.crm_leads lead on lead.id=process.lead_id
    where process.completed_at is null
  loop
    for operator_record in
      select id from public.profiles where is_financing_operator
    loop
      if not process_record.checklist_sent then
        sent := public.crm_financing_dispatch_reminder(
          process_record.id,operator_record.id,'checklist_pending','main',local_day,
          'Checklist de financiamento pendente',
          'Confirme o envio do checklist para '||process_record.lead_name||'.',
          'financing_checklist_pending'
        );
        if sent then sent_count:=sent_count+1; end if;
      end if;

      if process_record.checklist_sent and not process_record.documentation_complete then
        sent := public.crm_financing_dispatch_reminder(
          process_record.id,operator_record.id,'documentation_pending','main',local_day,
          'Documentacao de financiamento pendente',
          'Ainda ha documentos pendentes para '||process_record.lead_name||'.',
          'financing_documentation_pending'
        );
        if sent then sent_count:=sent_count+1; end if;
      end if;

      select attempt.* into active_attempt
      from public.crm_financing_conformity_attempts attempt
      where attempt.process_id=process_record.id and attempt.active
      order by attempt.attempt_number desc limit 1;
      if found and active_attempt.result='nonconform' then
        sent := public.crm_financing_dispatch_reminder(
          process_record.id,operator_record.id,'conformity_restart',
          'attempt-'||active_attempt.attempt_number,local_day,
          'Conformidade aguarda reinicio',
          'Reinicie a conformidade de '||process_record.lead_name||' para abrir uma nova tentativa.',
          'financing_conformity_restart'
        );
        if sent then sent_count:=sent_count+1; end if;
      end if;

      if process_record.registry_opened_at is not null
         and process_record.registry_opened_at <= now()-interval '24 hours'
         and (nullif(btrim(process_record.registry_protocol),'') is null
              or process_record.registry_expected_delivery is null) then
        sent := public.crm_financing_dispatch_reminder(
          process_record.id,operator_record.id,'registry_details','main',local_day,
          'Registro de Imoveis sem protocolo',
          'Preencha protocolo e previsao de entrega de '||process_record.lead_name||'.',
          'financing_registry_details'
        );
        if sent then sent_count:=sent_count+1; end if;
      end if;
    end loop;
  end loop;
  return sent_count;
end;
$$;

revoke all on function public.process_financing_reminders() from public, anon, authenticated;
grant execute on function public.process_financing_reminders() to service_role;

do $$
declare existing_job record;
begin
  for existing_job in select jobid from cron.job where jobname='financing-weekday-reminders' loop
    perform cron.unschedule(existing_job.jobid);
  end loop;
end $$;

-- 12:00 UTC corresponde a 09:00 em America/Sao_Paulo.
select cron.schedule(
  'financing-weekday-reminders',
  '0 12 * * 1-5',
  $$select public.process_financing_reminders();$$
);

comment on table public.crm_financing_reminder_dispatches is
  'Dedupe e auditoria de lembretes diarios do financiamento.';

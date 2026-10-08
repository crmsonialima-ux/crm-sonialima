alter table public.crm_agenda_entries
  add column if not exists protocol_entry_date date,
  add column if not exists protocol_expected_date date,
  add column if not exists protocol_pickup_reminder_sent_at timestamptz;

create or replace function public.attach_agenda_cartorio_protocol(
  p_id uuid,
  p_protocol_path text,
  p_entry_date date,
  p_expected_date date
)
returns void language plpgsql security definer set search_path = public as $$
declare derley uuid;
begin
  select id into derley from public.profiles where lower(email) = 'unassigned-agenda@example.invalid' limit 1;
  if auth.uid() <> derley then raise exception 'Somente Derley pode anexar o protocolo.'; end if;
  if nullif(trim(p_protocol_path), '') is null then raise exception 'Envie a foto do protocolo.'; end if;
  if p_entry_date is null or p_expected_date is null then
    raise exception 'Informe a data de entrada e a data prevista para buscar.';
  end if;
  if p_expected_date < p_entry_date then raise exception 'A data prevista não pode ser anterior à data de entrada.'; end if;
  update public.crm_agenda_entries
  set protocol_path = trim(p_protocol_path), protocol_uploaded_at = now(),
      protocol_entry_date = p_entry_date, protocol_expected_date = p_expected_date, updated_at = now()
  where id = p_id and category = 'cartorio' and target_user_id = derley;
  if not found then raise exception 'Demanda de Cartório não encontrada.'; end if;
end;
$$;

create or replace function public.process_agenda_protocol_pickup_reminders()
returns void language plpgsql security definer set search_path = public as $$
declare e record; derley uuid; local_today date;
begin
  select id into derley from public.profiles where lower(email) = 'unassigned-agenda@example.invalid' limit 1;
  local_today := (now() at time zone 'America/Sao_Paulo')::date;
  for e in select * from public.crm_agenda_entries
    where category = 'cartorio' and target_user_id = derley and protocol_path is not null
      and protocol_expected_date = local_today + 1 and protocol_pickup_reminder_sent_at is null
  loop
    insert into public.crm_notification_outbox(recipient_id, kind, title, body, url, payload)
    values (
      derley, 'agenda_pickup_reminder', 'Buscar protocolo amanhã',
      'O protocolo de ' || coalesce(e.cartorio_client_name, 'cliente não informado') ||
        ' está previsto para ' || to_char(e.protocol_expected_date, 'DD/MM/YYYY') || '. Lembre-se de buscar.',
      '/agenda', jsonb_build_object('agendaId', e.id)
    );
    update public.crm_agenda_entries set protocol_pickup_reminder_sent_at = now() where id = e.id;
  end loop;
end;
$$;

grant execute on function public.attach_agenda_cartorio_protocol(uuid,text,date,date), public.process_agenda_protocol_pickup_reminders() to authenticated;
revoke execute on function public.attach_agenda_cartorio_protocol(uuid,text) from authenticated;

-- 12:00 UTC é 09:00 em Brasília. O alerta é enviado na manhã anterior à data prevista.
select cron.schedule(
  'agenda-cartorio-pickup-reminder-9am',
  '0 12 * * *',
  $$select public.process_agenda_protocol_pickup_reminders();$$
);

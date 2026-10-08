-- Dados estruturados e comprovante de protocolo para demandas de Cartório.
alter table public.crm_agenda_entries
  add column if not exists cartorio_client_name text,
  add column if not exists cartorio_property_address text,
  add column if not exists cartorio_name text,
  add column if not exists cartorio_service text,
  add column if not exists protocol_path text,
  add column if not exists protocol_uploaded_at timestamptz,
  add column if not exists protocol_reminder_sent_at timestamptz,
  add column if not exists protocol_vitor_notified_at timestamptz;

insert into storage.buckets (id, name, public)
values ('agenda-protocols', 'agenda-protocols', false)
on conflict (id) do nothing;

drop policy if exists "Authenticated users read agenda protocols" on storage.objects;
create policy "Authenticated users read agenda protocols"
on storage.objects for select to authenticated
using (bucket_id = 'agenda-protocols');

drop policy if exists "Authenticated users upload agenda protocols" on storage.objects;
create policy "Authenticated users upload agenda protocols"
on storage.objects for insert to authenticated
with check (bucket_id = 'agenda-protocols');

create or replace function public.create_cartorio_agenda_entry(
  p_scheduled_at timestamptz,
  p_client_name text,
  p_property_address text,
  p_cartorio_name text,
  p_service text,
  p_target_user_id uuid
)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  derley uuid;
  entry_id uuid;
  summary text;
begin
  if auth.uid() is null then raise exception 'Sessão não encontrada.'; end if;
  select id into derley from public.profiles where lower(email) = 'unassigned-agenda@example.invalid' limit 1;
  if derley is null then raise exception 'Perfil do Derley não encontrado.'; end if;
  if p_target_user_id <> derley then raise exception 'Demandas de Cartório devem ser direcionadas ao Derley.'; end if;
  if p_scheduled_at is null
    or nullif(trim(p_client_name), '') is null
    or nullif(trim(p_property_address), '') is null
    or nullif(trim(p_cartorio_name), '') is null
    or nullif(trim(p_service), '') is null then
    raise exception 'Informe data, hora, cliente, endereço do imóvel, cartório e serviço.';
  end if;

  summary := 'Cliente: ' || trim(p_client_name) || E'\nImóvel: ' || trim(p_property_address) || E'\nCartório: ' || trim(p_cartorio_name) || E'\nServiço: ' || trim(p_service);
  insert into public.crm_agenda_entries (
    category, scheduled_at, observation, target_user_id, created_by,
    cartorio_client_name, cartorio_property_address, cartorio_name, cartorio_service
  ) values (
    'cartorio', p_scheduled_at, summary, p_target_user_id, auth.uid(),
    trim(p_client_name), trim(p_property_address), trim(p_cartorio_name), trim(p_service)
  ) returning id into entry_id;

  if p_target_user_id <> auth.uid() then
    insert into public.crm_notification_outbox(recipient_id, kind, title, body, url, payload)
    values (
      p_target_user_id, 'agenda_new_demand', 'Nova demanda de Cartório', summary,
      '/agenda', jsonb_build_object('agendaId', entry_id)
    );
  end if;
  return entry_id;
end;
$$;

create or replace function public.attach_agenda_cartorio_protocol(p_id uuid, p_protocol_path text)
returns void language plpgsql security definer set search_path = public as $$
declare derley uuid;
begin
  select id into derley from public.profiles where lower(email) = 'unassigned-agenda@example.invalid' limit 1;
  if auth.uid() <> derley then raise exception 'Somente Derley pode anexar o protocolo.'; end if;
  if nullif(trim(p_protocol_path), '') is null then raise exception 'Envie a foto do protocolo.'; end if;
  update public.crm_agenda_entries
  set protocol_path = trim(p_protocol_path), protocol_uploaded_at = now(), updated_at = now()
  where id = p_id and category = 'cartorio' and target_user_id = derley;
  if not found then raise exception 'Demanda de Cartório não encontrada.'; end if;
end;
$$;

-- Mantém os avisos existentes e acrescenta o controle do protocolo do Cartório.
create or replace function public.process_agenda_notifications()
returns void language plpgsql security definer set search_path = public as $$
declare e record; derley uuid; vitor uuid;
begin
  select id into derley from public.profiles where lower(email)='unassigned-agenda@example.invalid' limit 1;
  select id into vitor from public.profiles where lower(email)='unassigned-operator@example.invalid' limit 1;

  for e in select * from public.crm_agenda_entries where reminder_sent_at is null and scheduled_at between now() and now()+interval '30 minutes' loop
    insert into public.crm_notification_outbox(recipient_id,kind,title,body,url,payload)
    values(e.target_user_id,'agenda_reminder','Compromisso em 30 minutos',e.observation,'/agenda',jsonb_build_object('agendaId',e.id));
    update public.crm_agenda_entries set reminder_sent_at=now() where id=e.id;
  end loop;

  for e in select * from public.crm_agenda_entries where category in ('neo_energia','caesb') and target_user_id=derley and feedback_at is null and scheduled_at+interval '3 hours'<=now() and vitor_notified_at is null loop
    if vitor is not null then
      insert into public.crm_notification_outbox(recipient_id,kind,title,body,url,payload)
      values(vitor,'agenda_escalation','Demanda sem retorno de Derley',e.observation,'/agenda',jsonb_build_object('agendaId',e.id));
    end if;
    update public.crm_agenda_entries set vitor_notified_at=now() where id=e.id;
  end loop;

  for e in select * from public.crm_agenda_entries where category in ('neo_energia','caesb') and target_user_id=derley and feedback_at is null and scheduled_at+interval '5 hours'<=now() and admin_notified_at is null loop
    insert into public.crm_notification_outbox(recipient_id,kind,title,body,url,payload)
    select id,'agenda_escalation','Demanda sem retorno','Derley e Vitor ainda não registraram retorno: '||e.observation,'/agenda',jsonb_build_object('agendaId',e.id)
    from public.profiles where role='admin';
    update public.crm_agenda_entries set admin_notified_at=now() where id=e.id;
  end loop;

  -- A partir de 3 horas do compromisso, Derley recebe lembrete a cada 15 minutos até anexar a foto.
  for e in select * from public.crm_agenda_entries
    where category = 'cartorio' and target_user_id = derley and protocol_path is null
      and scheduled_at + interval '3 hours' <= now()
      and (protocol_reminder_sent_at is null or protocol_reminder_sent_at <= now() - interval '15 minutes')
  loop
    insert into public.crm_notification_outbox(recipient_id,kind,title,body,url,payload)
    values(derley,'agenda_protocol_reminder','Anexe o protocolo do Cartório',e.observation,'/agenda',jsonb_build_object('agendaId',e.id));
    update public.crm_agenda_entries set protocol_reminder_sent_at = now() where id = e.id;
  end loop;

  -- Em 24 horas sem comprovante, Vitor é avisado uma única vez.
  for e in select * from public.crm_agenda_entries
    where category = 'cartorio' and target_user_id = derley and protocol_path is null
      and scheduled_at + interval '24 hours' <= now() and protocol_vitor_notified_at is null
  loop
    if vitor is not null then
      insert into public.crm_notification_outbox(recipient_id,kind,title,body,url,payload)
      values(vitor,'agenda_escalation','Protocolo de Cartório pendente há 24 horas',e.observation,'/agenda',jsonb_build_object('agendaId',e.id));
    end if;
    update public.crm_agenda_entries set protocol_vitor_notified_at = now() where id = e.id;
  end loop;
end;
$$;

grant execute on function public.create_cartorio_agenda_entry(timestamptz,text,text,text,text,uuid), public.attach_agenda_cartorio_protocol(uuid,text) to authenticated;

-- Gera os lembretes de protocolo mesmo quando ninguém está com a Agenda aberta.
select cron.schedule(
  'agenda-cartorio-protocol-reminders',
  '*/15 * * * *',
  $$select public.process_agenda_notifications();$$
);

-- Notifica exclusivamente o solicitante sobre o andamento das demandas
-- encaminhadas ao Derley. Cada evento possui uma chave unica para impedir
-- notificacoes duplicadas mesmo com processadores concorrentes.

create table if not exists public.crm_agenda_requester_notification_events (
  agenda_id uuid not null references public.crm_agenda_entries(id) on delete cascade,
  event_key text not null,
  created_at timestamptz not null default now(),
  primary key (agenda_id, event_key)
);

alter table public.crm_agenda_requester_notification_events enable row level security;
revoke all on public.crm_agenda_requester_notification_events from public, anon, authenticated;

create or replace function public.enqueue_agenda_requester_notification(
  p_agenda_id uuid,
  p_event_key text,
  p_kind text,
  p_title text,
  p_body text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  entry record;
  derley_id uuid;
  inserted_count integer := 0;
begin
  select id into derley_id
  from public.profiles
  where lower(email) = 'unassigned-agenda@example.invalid'
  limit 1;

  select * into entry
  from public.crm_agenda_entries
  where id = p_agenda_id;

  if entry.id is null
     or derley_id is null
     or entry.target_user_id <> derley_id
     or entry.created_by is null
     or entry.created_by = derley_id
     or entry.source_kind = 'lead_visit' then
    return false;
  end if;

  insert into public.crm_agenda_requester_notification_events (agenda_id, event_key)
  values (entry.id, p_event_key)
  on conflict do nothing;

  get diagnostics inserted_count = row_count;
  if inserted_count = 0 then
    return false;
  end if;

  insert into public.crm_notification_outbox (
    recipient_id,
    kind,
    title,
    body,
    url,
    payload
  ) values (
    entry.created_by,
    p_kind,
    p_title,
    p_body,
    '/agenda',
    jsonb_build_object(
      'agendaId', entry.id,
      'eventKey', p_event_key,
      'responsibleId', derley_id,
      'requesterEmail', entry.created_by_email
    )
  );

  return true;
end;
$$;

revoke all on function public.enqueue_agenda_requester_notification(
  uuid, text, text, text, text
) from public, anon, authenticated;

create or replace function public.notify_agenda_requester_on_derley_progress()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  revision_number integer;
  demand_summary text;
begin
  demand_summary := coalesce(
    nullif(trim(new.demand_service), ''),
    nullif(trim(new.cartorio_service), ''),
    nullif(trim(new.observation), ''),
    'Demanda da Agenda'
  );
  revision_number := greatest(coalesce(new.cartorio_protocol_revision_count, 0), 1);

  if old.feedback_at is null and new.feedback_at is not null then
    if new.category in ('neo_energia', 'caesb', 'observacao') then
      perform public.enqueue_agenda_requester_notification(
        new.id,
        'feedback_completed',
        'agenda_request_completed',
        'Derley concluiu a demanda',
        'Derley registrou o retorno final: ' || demand_summary
      );
    else
      perform public.enqueue_agenda_requester_notification(
        new.id,
        'feedback_registered',
        'agenda_request_progress',
        'Derley registrou um retorno',
        'Derley registrou um retorno na demanda: ' || demand_summary
      );
    end if;
  end if;

  if coalesce(new.cartorio_protocol_revision_count, 0)
     > coalesce(old.cartorio_protocol_revision_count, 0) then
    perform public.enqueue_agenda_requester_notification(
      new.id,
      'protocol_saved_v' || revision_number,
      'agenda_request_progress',
      case
        when revision_number = 1 then 'Derley salvou o protocolo'
        else 'Derley corrigiu o protocolo'
      end,
      case
        when revision_number = 1 then 'Derley preencheu as datas e anexou o protocolo: '
        else 'Derley salvou a correção dos dados e anexos: '
      end || demand_summary
    );
  end if;

  if old.cartorio_received_at is null and new.cartorio_received_at is not null then
    perform public.enqueue_agenda_requester_notification(
      new.id,
      'cartorio_received_v' || revision_number,
      'agenda_request_progress',
      'Documento recebido no Cartório',
      'Derley registrou o recebimento do documento no Cartório: ' || demand_summary
    );
  end if;

  if old.cartorio_delivered_to_vitor_at is null
     and new.cartorio_delivered_to_vitor_at is not null then
    perform public.enqueue_agenda_requester_notification(
      new.id,
      'delivered_to_vitor_v' || revision_number,
      'agenda_request_completed',
      'Derley finalizou a demanda',
      'Derley concluiu os passos e entregou o documento ao Vitor: ' || demand_summary
    );
  end if;

  return new;
end;
$$;

drop trigger if exists crm_agenda_notify_requester_on_derley_progress
  on public.crm_agenda_entries;

create trigger crm_agenda_notify_requester_on_derley_progress
after update of feedback_at, cartorio_protocol_revision_count,
  cartorio_received_at, cartorio_delivered_to_vitor_at
on public.crm_agenda_entries
for each row
execute procedure public.notify_agenda_requester_on_derley_progress();

-- Visitas criadas pela aba Leads pertencem ao fluxo normal da agenda do
-- corretor responsavel e nunca devem ser tratadas como demandas ao Derley.
delete from public.crm_agenda_requester_notification_events as sent_event
using public.crm_agenda_entries as agenda
where agenda.id = sent_event.agenda_id
  and agenda.source_kind = 'lead_visit'
  and sent_event.event_key in ('pre_30m', 'post_1h');

-- Evita disparar agora o acompanhamento de 1 hora para demandas antigas.
insert into public.crm_agenda_requester_notification_events (agenda_id, event_key)
select agenda.id, 'post_1h'
from public.crm_agenda_entries as agenda
join public.profiles as derley
  on derley.id = agenda.target_user_id
 and lower(derley.email) = 'unassigned-agenda@example.invalid'
where agenda.created_by <> agenda.target_user_id
  and agenda.source_kind is distinct from 'lead_visit'
  and agenda.scheduled_at + interval '1 hour' <= now()
on conflict do nothing;

-- Redireciona os lembretes de demandas externas do Derley ao solicitante,
-- adiciona o acompanhamento de 1 hora e preserva todos os escalonamentos.
create or replace function public.process_agenda_notifications()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  entry record;
  derley_id uuid;
  vitor_id uuid;
begin
  select id into derley_id
  from public.profiles
  where lower(email) = 'unassigned-agenda@example.invalid'
  limit 1;

  select id into vitor_id
  from public.profiles
  where lower(email) = 'unassigned-operator@example.invalid'
  limit 1;

  for entry in
    select agenda.*
    from public.crm_agenda_entries as agenda
    where agenda.reminder_sent_at is null
      and agenda.scheduled_at between now() and now() + interval '30 minutes'
    for update of agenda skip locked
  loop
    if entry.target_user_id = derley_id
       and entry.created_by is distinct from derley_id
       and entry.source_kind is distinct from 'lead_visit' then
      perform public.enqueue_agenda_requester_notification(
        entry.id,
        'pre_30m',
        'agenda_requester_reminder',
        'Demanda do Derley em 30 minutos',
        'A demanda que você cadastrou para o Derley começa em 30 minutos: '
          || entry.observation
      );
    else
      insert into public.crm_notification_outbox (
        recipient_id, kind, title, body, url, payload
      ) values (
        entry.target_user_id,
        'agenda_reminder',
        'Compromisso em 30 minutos',
        entry.observation,
        '/agenda',
        jsonb_build_object('agendaId', entry.id)
      );
    end if;

    update public.crm_agenda_entries
    set reminder_sent_at = now()
    where id = entry.id;
  end loop;

  for entry in
    select agenda.*
    from public.crm_agenda_entries as agenda
    where agenda.target_user_id = derley_id
      and agenda.created_by is distinct from derley_id
      and agenda.source_kind is distinct from 'lead_visit'
      and agenda.scheduled_at + interval '1 hour' <= now()
      and not exists (
        select 1
        from public.crm_agenda_requester_notification_events as sent_event
        where sent_event.agenda_id = agenda.id
          and sent_event.event_key = 'post_1h'
      )
    for update of agenda skip locked
  loop
    perform public.enqueue_agenda_requester_notification(
      entry.id,
      'post_1h',
      'agenda_requester_followup',
      'Acompanhe a demanda enviada ao Derley',
      'Já passou 1 hora do horário marcado. Consulte o andamento da demanda: '
        || entry.observation
    );
  end loop;

  for entry in
    select agenda.*
    from public.crm_agenda_entries as agenda
    where agenda.category in ('neo_energia', 'caesb')
      and agenda.target_user_id = derley_id
      and agenda.feedback_at is null
      and agenda.scheduled_at + interval '3 hours' <= now()
      and agenda.vitor_notified_at is null
    for update of agenda skip locked
  loop
    if vitor_id is not null then
      insert into public.crm_notification_outbox (
        recipient_id, kind, title, body, url, payload
      ) values (
        vitor_id,
        'agenda_escalation',
        'Demanda sem retorno de Derley',
        entry.observation,
        '/agenda',
        jsonb_build_object('agendaId', entry.id)
      );
    end if;

    update public.crm_agenda_entries
    set vitor_notified_at = now()
    where id = entry.id;
  end loop;

  for entry in
    select agenda.*
    from public.crm_agenda_entries as agenda
    where agenda.category in ('neo_energia', 'caesb')
      and agenda.target_user_id = derley_id
      and agenda.feedback_at is null
      and agenda.scheduled_at + interval '5 hours' <= now()
      and agenda.admin_notified_at is null
    for update of agenda skip locked
  loop
    insert into public.crm_notification_outbox (
      recipient_id, kind, title, body, url, payload
    )
    select
      profile.id,
      'agenda_escalation',
      'Demanda sem retorno',
      'Derley e Vitor ainda nao registraram retorno: ' || entry.observation,
      '/agenda',
      jsonb_build_object('agendaId', entry.id)
    from public.profiles as profile
    where profile.role = 'admin';

    update public.crm_agenda_entries
    set admin_notified_at = now()
    where id = entry.id;
  end loop;

  -- Apos 3 horas, Derley continua recebendo a cobranca operacional do
  -- protocolo a cada 15 minutos ate anexar. Isso nao e aviso de andamento.
  for entry in
    select agenda.*
    from public.crm_agenda_entries as agenda
    where agenda.category = 'cartorio'
      and agenda.target_user_id = derley_id
      and agenda.protocol_path is null
      and agenda.scheduled_at + interval '3 hours' <= now()
      and (
        agenda.protocol_reminder_sent_at is null
        or agenda.protocol_reminder_sent_at <= now() - interval '15 minutes'
      )
    for update of agenda skip locked
  loop
    insert into public.crm_notification_outbox (
      recipient_id, kind, title, body, url, payload
    ) values (
      derley_id,
      'agenda_protocol_reminder',
      'Anexe o protocolo do Cartorio',
      entry.observation,
      '/agenda',
      jsonb_build_object('agendaId', entry.id)
    );

    update public.crm_agenda_entries
    set protocol_reminder_sent_at = now()
    where id = entry.id;
  end loop;

  -- Em 24 horas sem protocolo, Vitor continua sendo avisado uma unica vez.
  for entry in
    select agenda.*
    from public.crm_agenda_entries as agenda
    where agenda.category = 'cartorio'
      and agenda.target_user_id = derley_id
      and agenda.protocol_path is null
      and agenda.scheduled_at + interval '24 hours' <= now()
      and agenda.protocol_vitor_notified_at is null
    for update of agenda skip locked
  loop
    if vitor_id is not null then
      insert into public.crm_notification_outbox (
        recipient_id, kind, title, body, url, payload
      ) values (
        vitor_id,
        'agenda_escalation',
        'Protocolo de Cartorio pendente ha 24 horas',
        entry.observation,
        '/agenda',
        jsonb_build_object('agendaId', entry.id)
      );
    end if;

    update public.crm_agenda_entries
    set protocol_vitor_notified_at = now()
    where id = entry.id;
  end loop;
end;
$$;

grant execute on function public.process_agenda_notifications() to authenticated;

-- A Agenda possui seu proprio processador a cada minuto. Assim, os avisos
-- nao dependem do tempo de resposta da Edge Function que cuida dos leads.
do $$
declare
  scheduled_job record;
begin
  for scheduled_job in
    select jobid
    from cron.job
    where jobname in (
      'agenda-cartorio-protocol-reminders',
      'agenda-notifications-every-minute'
    )
  loop
    perform cron.unschedule(scheduled_job.jobid);
  end loop;
end;
$$;

select cron.schedule(
  'agenda-notifications-every-minute',
  '* * * * *',
  $$select public.process_agenda_notifications();$$
);

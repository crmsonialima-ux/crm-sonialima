begin;

-- A browser can retain a push subscription while the operator changes CRM
-- accounts. Register through this narrowly scoped RPC so the current signed-in
-- user can refresh that device without an RLS conflict.
create or replace function public.register_push_subscription(
  p_endpoint text,
  p_p256dh text,
  p_auth text
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  subscription_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Sessao nao encontrada.';
  end if;
  if nullif(trim(coalesce(p_endpoint, '')), '') is null
     or nullif(trim(coalesce(p_p256dh, '')), '') is null
     or nullif(trim(coalesce(p_auth, '')), '') is null then
    raise exception 'Dados da notificacao do dispositivo incompletos.';
  end if;

  insert into public.push_subscriptions(user_id, endpoint, p256dh, auth, updated_at)
  values (auth.uid(), p_endpoint, p_p256dh, p_auth, now())
  on conflict (endpoint) do update
    set user_id = excluded.user_id,
        p256dh = excluded.p256dh,
        auth = excluded.auth,
        updated_at = now()
  returning id into subscription_id;

  return subscription_id;
end;
$$;

revoke all on function public.register_push_subscription(text,text,text) from public, anon;
grant execute on function public.register_push_subscription(text,text,text) to authenticated;

-- Service workers can deliver their local click/close event after the offer was
-- cancelled. The event is obsolete, not an application failure.
create or replace function public.record_notification_client_event(
  p_notification_id uuid,
  p_event_type text,
  p_details jsonb default '{}'::jsonb
)
returns bigint
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  notification_record public.crm_notification_outbox;
  event_time timestamptz := now();
  reported_time timestamptz;
  client_event_id text;
  event_id bigint;
begin
  if p_event_type not in (
    'browser_presented', 'push_clicked', 'push_closed',
    'inbox_opened', 'notification_client_error'
  ) then
    raise exception 'Evento de notificacao invalido.';
  end if;

  select * into notification_record
  from public.crm_notification_outbox
  where id = p_notification_id
    and recipient_id = auth.uid();
  if not found then
    return null;
  end if;

  begin
    reported_time := nullif(p_details ->> 'happenedAt', '')::timestamptz;
  exception when others then
    reported_time := null;
  end;
  if reported_time between now() - interval '30 days' and now() + interval '5 minutes' then
    event_time := reported_time;
  end if;

  if p_event_type in ('push_clicked', 'inbox_opened') then
    update public.crm_notification_outbox
    set read_at = coalesce(read_at, event_time)
    where id = notification_record.id;
  end if;

  client_event_id := nullif(coalesce(p_details ->> 'clientEventId', ''), '');
  event_id := public.append_crm_audit_event(
    notification_record.recipient_id,
    auth.uid(),
    'notification',
    p_event_type,
    case when p_event_type = 'notification_client_error' then 'error' else 'recorded' end,
    'notification',
    notification_record.id,
    notification_record.id,
    event_time,
    notification_record.title,
    coalesce(p_details, '{}'::jsonb),
    case when p_event_type = 'notification_client_error'
      then left(coalesce(p_details ->> 'message', 'Erro do cliente sem mensagem.'), 4000)
      else null end,
    case when client_event_id is null then null
      else 'notification:' || notification_record.id || ':client:' || client_event_id end
  );
  return event_id;
end;
$$;

revoke all on function public.record_notification_client_event(uuid,text,jsonb) from public, anon;
grant execute on function public.record_notification_client_event(uuid,text,jsonb) to authenticated;

-- Legacy records whose workflow had already advanced must not remain marked as
-- a pending offer. They have no active deadline and are not candidates for the
-- automatic queue.
update public.crm_leads
set assignment_status = 'accepted',
    assignment_available_at = null,
    assignment_deadline_at = null,
    assignment_reminder_sent_at = null,
    updated_at = now()
where assignment_status = 'pending'
  and assignment_deadline_at is null
  and stage <> 'Aguardando atendimento';

commit;

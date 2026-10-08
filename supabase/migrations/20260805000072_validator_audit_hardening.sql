-- Endurecimento final da auditoria de validacao.
-- Corrige o trigger da esteira, reativa notificacoes quando um aparelho e
-- cadastrado e registra quando a caixa de notificacoes foi apresentada.

create or replace function public.audit_lead_assignment_attempt()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    perform public.append_crm_audit_event(
      new.broker_id, auth.uid(), 'lead', 'lead_assignment_attempt_created',
      'pending', 'lead', new.lead_id, null, new.notified_at,
      'Lead encaminhado ao corretor',
      jsonb_build_object(
        'attemptId', new.id,
        'attemptNumber', new.attempt_number,
        'deadlineAt', new.deadline_at
      ), null, 'assignment-attempt:' || new.id || ':created'
    );
  elsif tg_op = 'UPDATE' then
    if old.accepted_at is null and new.accepted_at is not null then
      perform public.append_crm_audit_event(
        new.broker_id, auth.uid(), 'lead', 'lead_assignment_accepted',
        'completed', 'lead', new.lead_id, null, new.accepted_at,
        'Corretor assumiu o lead',
        jsonb_build_object('attemptId', new.id, 'attemptNumber', new.attempt_number),
        null, 'assignment-attempt:' || new.id || ':accepted'
      );
    end if;
    if old.expired_at is null and new.expired_at is not null then
      perform public.append_crm_audit_event(
        new.broker_id, auth.uid(), 'lead', 'lead_assignment_expired',
        'expired', 'lead', new.lead_id, null, new.expired_at,
        'Prazo do corretor expirou',
        jsonb_build_object('attemptId', new.id, 'attemptNumber', new.attempt_number),
        null, 'assignment-attempt:' || new.id || ':expired'
      );
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.audit_lead_assignment_attempt()
  from public, anon, authenticated;

create or replace function public.audit_push_subscription()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    -- Um aviso que ficou sem dispositivo volta para a fila assim que o usuario
    -- habilita um aparelho. A janela de expediente continua sendo respeitada.
    update public.crm_notification_outbox
    set delivery_status = 'queued',
        last_delivery_error = null,
        last_delivery_http_status = null,
        delivery_updated_at = now()
    where recipient_id = new.user_id
      and delivered_at is null
      and delivery_status in ('no_subscription', 'invalid_subscription');

    perform public.append_crm_audit_event(
      new.user_id, auth.uid(), 'notification', 'push_subscription_created',
      'active', 'push_subscription', new.id, null, new.created_at,
      'Dispositivo habilitado para notificacoes', '{}'::jsonb, null,
      'push-subscription:' || new.id || ':created'
    );
    return new;
  elsif tg_op = 'DELETE' then
    perform public.append_crm_audit_event(
      old.user_id, auth.uid(), 'notification', 'push_subscription_removed',
      'removed', 'push_subscription', old.id, null, now(),
      'Dispositivo removido das notificacoes', '{}'::jsonb, null, null
    );
    return old;
  end if;
  return new;
end;
$$;

revoke all on function public.audit_push_subscription()
  from public, anon, authenticated;

create or replace function public.record_notification_client_event(
  p_notification_id uuid,
  p_event_type text,
  p_details jsonb default '{}'::jsonb
)
returns bigint
language plpgsql
security definer
set search_path = public
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
    'inbox_presented', 'inbox_opened', 'notification_client_error'
  ) then
    raise exception 'Evento de notificacao invalido.';
  end if;

  select * into notification_record
  from public.crm_notification_outbox
  where id = p_notification_id
    and recipient_id = auth.uid();
  if not found then raise exception 'Notificacao nao encontrada para este usuario.'; end if;

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
    case
      when p_event_type = 'notification_client_error' then 'error'
      else 'recorded'
    end,
    'notification',
    notification_record.id,
    notification_record.id,
    event_time,
    notification_record.title,
    coalesce(p_details, '{}'::jsonb),
    case
      when p_event_type = 'notification_client_error'
        then left(coalesce(p_details ->> 'message', 'Erro do cliente sem mensagem.'), 4000)
      else null
    end,
    case
      when client_event_id is null then null
      else 'notification:' || notification_record.id || ':client:' || client_event_id
    end
  );
  return event_id;
end;
$$;

revoke all on function public.record_notification_client_event(uuid,text,jsonb)
  from public, anon;
grant execute on function public.record_notification_client_event(uuid,text,jsonb)
  to authenticated;

-- Valor zero passa a significar historico completo para a conta de validacao.
-- A transformacao preserva a funcao central criada na migration 70 sem manter
-- duas copias extensas da mesma consulta.
do $$
declare
  function_definition text;
begin
  select pg_get_functiondef('public.get_validation_audit(uuid,integer)'::regprocedure::oid)
  into function_definition;

  if position(
    'least(greatest(coalesce(p_limit, 500), 1), 1000)'
    in function_definition
  ) > 0 then
    function_definition := replace(
      function_definition,
      'least(greatest(coalesce(p_limit, 500), 1), 1000)',
      'case when p_limit is null or p_limit <= 0 then null else p_limit end'
    );
    execute function_definition;
  end if;
end;
$$;

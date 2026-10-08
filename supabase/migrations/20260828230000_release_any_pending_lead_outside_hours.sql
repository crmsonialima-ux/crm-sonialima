begin;

-- Allyson can wake up any pending lead outside queue hours, even when a stale
-- client left the lead without assignment_available_at. A fresh outbox entry
-- is created so a notification that was previously processed cannot suppress
-- the new audible alert.
create or replace function public.allyson_release_scheduled_lead(p_lead_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  lead_row public.crm_leads%rowtype;
  target_deadline timestamptz := now() + interval '20 minutes';
  actor_name text;
  current_attempt_number integer;
  current_round_number smallint;
begin
  if not public.is_allyson_admin() then
    raise exception 'Apenas Allyson pode liberar leads fora do horario.';
  end if;

  select lead.*
  into lead_row
  from public.crm_leads lead
  where lead.id = p_lead_id
  for update;

  if not found then
    raise exception 'Lead nao encontrado.';
  end if;

  if lead_row.assignment_status <> 'pending' then
    raise exception 'Somente leads aguardando atendimento podem ser liberados.';
  end if;

  if public.crm_is_lead_queue_hours(now())
     and not (
       lead_row.assignment_available_at is not null
       and lead_row.assignment_available_at > now()
     ) then
    raise exception 'O lead ja esta liberado dentro do horario da fila.';
  end if;

  select
    attempt.attempt_number,
    attempt.round_number
  into current_attempt_number, current_round_number
  from public.lead_assignment_attempts attempt
  where attempt.lead_id = p_lead_id
    and attempt.broker_id = lead_row.owner_id
    and attempt.run_number = lead_row.assignment_run_number
    and attempt.accepted_at is null
  order by attempt.attempt_number desc
  limit 1;

  if current_attempt_number is null then
    select coalesce(max(attempt.attempt_number), 0) + 1
    into current_attempt_number
    from public.lead_assignment_attempts attempt
    where attempt.lead_id = p_lead_id
      and attempt.run_number = lead_row.assignment_run_number;

    current_round_number := 1;

    insert into public.lead_assignment_attempts (
      lead_id,
      broker_id,
      attempt_number,
      notified_at,
      deadline_at,
      accepted_at,
      expired_at,
      run_number,
      round_number
    ) values (
      p_lead_id,
      lead_row.owner_id,
      current_attempt_number,
      now(),
      target_deadline,
      null,
      null,
      lead_row.assignment_run_number,
      current_round_number
    );
  else
    update public.lead_assignment_attempts attempt
    set notified_at = now(),
        deadline_at = target_deadline,
        expired_at = null
    where attempt.lead_id = p_lead_id
      and attempt.broker_id = lead_row.owner_id
      and attempt.run_number = lead_row.assignment_run_number
      and attempt.attempt_number = current_attempt_number;
  end if;

  update public.crm_leads
  set assignment_available_at = now(),
      assignment_deadline_at = target_deadline,
      assignment_reminder_sent_at = null,
      updated_at = now()
  where id = p_lead_id;

  select coalesce(nullif(profile.full_name, ''), profile.email)
  into actor_name
  from public.profiles profile
  where profile.id = auth.uid();

  insert into public.crm_lead_activities (
    lead_id,
    stage,
    note,
    author_id,
    author_name
  ) values (
    p_lead_id,
    lead_row.stage,
    'Liberou o lead imediatamente fora do horario da fila.',
    auth.uid(),
    coalesce(actor_name, 'Allyson')
  );

  update public.crm_notification_outbox notification
  set dismissed_at = coalesce(notification.dismissed_at, now()),
      read_at = coalesce(notification.read_at, now())
  where notification.kind = 'lead_assignment'
    and notification.recipient_id = lead_row.owner_id
    and notification.payload ->> 'leadId' = p_lead_id::text;

  insert into public.crm_notification_outbox (
    recipient_id,
    kind,
    title,
    body,
    url,
    payload,
    available_at
  ) values (
    lead_row.owner_id,
    'lead_assignment',
    'Novo lead aguardando atendimento',
    'Voce tem 20 minutos para aceitar o lead ' || lead_row.name || '.',
    '/leads?focusLeadId=' || lead_row.id::text,
    jsonb_build_object(
      'leadId', lead_row.id,
      'phone', lead_row.phone,
      'name', lead_row.name,
      'attemptNumber', current_attempt_number,
      'runNumber', lead_row.assignment_run_number,
      'roundNumber', current_round_number,
      'availableAt', now(),
      'deadlineAt', target_deadline,
      'manualRelease', true
    ),
    now()
  );
end;
$$;

revoke all on function public.allyson_release_scheduled_lead(uuid)
  from public, anon, authenticated;
grant execute on function public.allyson_release_scheduled_lead(uuid)
  to authenticated;

commit;

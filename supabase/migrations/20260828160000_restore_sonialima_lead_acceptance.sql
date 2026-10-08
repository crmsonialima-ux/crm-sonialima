begin;

-- Reabre somente o lead direto mais recente do SoniaLima, criado pelo Allyson
-- nas ultimas 24 horas e ainda sem tentativa/notificacao de aceite.
do $$
declare
  target_lead public.crm_leads%rowtype;
  available_at timestamptz;
  deadline_at timestamptz;
begin
  select lead.* into target_lead
  from public.crm_leads as lead
  join public.profiles as owner on owner.id = lead.owner_id
  join public.profiles as creator on creator.id = lead.created_by
  where lower(trim(owner.email)) = 'unassigned-institutional@example.invalid'
    and lower(trim(creator.email)) = 'crmsoniaallyson@gmail.com'
    and lead.lead_type = 'Venda'
    and lead.assignment_status = 'accepted'
    and lead.created_at >= now() - interval '24 hours'
    and not exists (
      select 1 from public.lead_assignment_attempts attempt
      where attempt.lead_id = lead.id
    )
  order by lead.created_at desc
  limit 1
  for update of lead;

  if target_lead.id is null then
    return;
  end if;

  available_at := public.crm_next_lead_queue_moment(now());
  deadline_at := public.crm_add_lead_queue_minutes(available_at, 15);

  update public.crm_leads
  set assignment_status = 'pending',
      assignment_available_at = available_at,
      assignment_deadline_at = deadline_at,
      assignment_run_number = greatest(coalesce(assignment_run_number, 1), 1),
      assignment_reminder_sent_at = null,
      stage = 'Aguardando atendimento',
      updated_at = now()
  where id = target_lead.id;

  insert into public.lead_assignment_attempts (
    lead_id, broker_id, attempt_number, run_number, round_number,
    notified_at, deadline_at
  ) values (
    target_lead.id, target_lead.owner_id, 1,
    greatest(coalesce(target_lead.assignment_run_number, 1), 1), 1,
    available_at, deadline_at
  );

  delete from public.crm_notification_outbox notification
  where notification.recipient_id = target_lead.owner_id
    and notification.payload ->> 'leadId' = target_lead.id::text
    and notification.kind in ('lead_assignment', 'lead_direct_assignment');

  insert into public.crm_notification_outbox (
    recipient_id, kind, title, body, url, payload, available_at
  ) values (
    target_lead.owner_id,
    'lead_assignment',
    'Novo lead aguardando atendimento',
    'Voce tem 15 minutos uteis para iniciar o atendimento de ' || target_lead.name || '.',
    '/leads',
    jsonb_build_object(
      'leadId', target_lead.id,
      'phone', target_lead.phone,
      'name', target_lead.name,
      'attemptNumber', 1,
      'runNumber', greatest(coalesce(target_lead.assignment_run_number, 1), 1),
      'roundNumber', 1,
      'availableAt', available_at,
      'deadlineAt', deadline_at
    ),
    available_at
  );
end;
$$;

commit;

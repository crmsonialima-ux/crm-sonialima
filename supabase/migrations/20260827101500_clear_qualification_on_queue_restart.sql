begin;

-- A new manual run is a fresh acceptance attempt. The expired qualification
-- remains in the audit history, but it must not replace the queue countdown.
create or replace function public.restart_exhausted_lead_queue(p_lead_id uuid)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  lead_record public.crm_leads%rowtype;
  next_broker_id uuid;
  next_broker_name text;
  next_broker_email text;
  next_position integer;
  next_run_number integer;
  available_at timestamptz;
  deadline_at timestamptz;
begin
  if not public.is_allyson_admin() then
    raise exception 'Somente Allyson pode girar novamente um lead na esteira.';
  end if;

  select lead.* into lead_record
  from public.crm_leads as lead
  where lead.id = p_lead_id
  for update;

  if not found then raise exception 'Lead nao encontrado.'; end if;
  if lead_record.assignment_status is distinct from 'exhausted' then
    raise exception 'Este lead nao esta com a esteira esgotada.';
  end if;

  perform pg_advisory_xact_lock(hashtext('lead-distribution:' || lead_record.lead_type));

  select queue.broker_id, profile.full_name, profile.email
  into next_broker_id, next_broker_name, next_broker_email
  from public.lead_distribution_queue as queue
  join public.profiles as profile on profile.id = queue.broker_id
  where queue.lead_type = lead_record.lead_type
    and profile.role = 'broker'
    and not coalesce(profile.lead_distribution_blocked, false)
    and (
      not coalesce(lead_record.property_roulette_queue_lead, false)
      or lead_record.property_roulette_excluded_capturer_id is null
      or queue.broker_id <> lead_record.property_roulette_excluded_capturer_id
    )
    and (
      lead_record.property_catalog_id is null
      or exists (
        select 1 from public.crm_property_broker_access as access
        where access.property_id = lead_record.property_catalog_id
          and access.broker_id = queue.broker_id
      )
    )
  order by queue.position
  limit 1
  for update of queue skip locked;

  if next_broker_id is null then
    raise exception 'Nao ha corretor elegivel na fila deste lead.';
  end if;

  select coalesce(max(queue.position), 0) + 1 into next_position
  from public.lead_distribution_queue as queue
  where queue.lead_type = lead_record.lead_type;

  update public.lead_distribution_queue as queue
  set position = next_position, updated_at = now()
  where queue.lead_type = lead_record.lead_type and queue.broker_id = next_broker_id;

  next_run_number := greatest(coalesce(lead_record.assignment_run_number, 1), 1) + 1;
  available_at := public.crm_next_lead_queue_moment(now());
  deadline_at := public.crm_add_lead_queue_minutes(available_at, 15);

  update public.crm_leads as lead
  set owner_id = next_broker_id,
      assignment_status = 'pending',
      assignment_available_at = available_at,
      assignment_deadline_at = deadline_at,
      assignment_run_number = next_run_number,
      assignment_reminder_sent_at = null,
      stage = 'Aguardando atendimento',
      post_acceptance_qualification_deadline_at = null,
      post_acceptance_qualification_completed_at = null,
      updated_at = now()
  where lead.id = lead_record.id;

  insert into public.lead_assignment_attempts (
    lead_id, broker_id, attempt_number, run_number, round_number, notified_at, deadline_at
  ) values (lead_record.id, next_broker_id, 1, next_run_number, 1, available_at, deadline_at);

  insert into public.crm_notification_outbox (
    recipient_id, kind, title, body, url, payload, available_at
  ) values (
    next_broker_id,
    'lead_assignment',
    'Lead reiniciado na esteira',
    'Voce tem 15 minutos uteis para iniciar o atendimento de ' || lead_record.name || '.',
    '/leads',
    jsonb_build_object(
      'leadId', lead_record.id,
      'phone', lead_record.phone,
      'name', lead_record.name,
      'attemptNumber', 1,
      'runNumber', next_run_number,
      'roundNumber', 1,
      'availableAt', available_at,
      'deadlineAt', deadline_at,
      'restartedByAllyson', true
    ),
    available_at
  );

  insert into public.crm_lead_activities (lead_id, stage, note, author_id, author_name)
  values (
    lead_record.id,
    'Esteira reiniciada',
    'Allyson iniciou a execucao ' || next_run_number
      || ' da esteira, com ate duas rodadas e primeiro prazo de 15 minutos uteis.',
    auth.uid(),
    'crmallyson'
  );

  return coalesce(nullif(next_broker_name, ''), next_broker_email);
end;
$$;

revoke all on function public.restart_exhausted_lead_queue(uuid) from public, anon;
grant execute on function public.restart_exhausted_lead_queue(uuid) to authenticated;

commit;

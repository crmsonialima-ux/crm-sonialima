begin;

-- Garante no servidor que uma selecao direta do SoniaLima pelo Allyson sempre
-- resulte em aceite pela fila, inclusive quando o navegador ainda usa bundle antigo.
do $$
declare
  definition text;
  patched text;
  marker text := 'if created_lead.lead_id is null then';
  enforcement text := $body$
  if p_visit_scheduled_at is null and exists (
    select 1 from public.profiles profile
    where profile.id = p_owner_id
      and lower(trim(profile.email)) = 'unassigned-institutional@example.invalid'
  ) then
    declare
      queue_available_at timestamptz := public.crm_next_lead_queue_moment(now());
      queue_deadline_at timestamptz;
    begin
      queue_deadline_at := public.crm_add_lead_queue_minutes(queue_available_at, 15);

      update public.crm_leads
      set assignment_status = 'pending',
          assignment_available_at = queue_available_at,
          assignment_deadline_at = queue_deadline_at,
          assignment_run_number = 1,
          assignment_reminder_sent_at = null,
          stage = 'Aguardando atendimento',
          updated_at = now()
      where id = created_lead.lead_id;

      delete from public.lead_assignment_attempts
      where lead_id = created_lead.lead_id;

      insert into public.lead_assignment_attempts (
        lead_id, broker_id, attempt_number, run_number, round_number,
        notified_at, deadline_at
      ) values (
        created_lead.lead_id, p_owner_id, 1, 1, 1,
        queue_available_at, queue_deadline_at
      );

      delete from public.crm_notification_outbox
      where payload ->> 'leadId' = created_lead.lead_id::text
        and kind in ('lead_assignment', 'lead_direct_assignment');

      insert into public.crm_notification_outbox (
        recipient_id, kind, title, body, url, payload, available_at
      ) values (
        p_owner_id,
        'lead_assignment',
        'Novo lead aguardando atendimento',
        'Voce tem 15 minutos uteis para iniciar o atendimento de ' || trim(p_name) || '.',
        '/leads',
        jsonb_build_object(
          'leadId', created_lead.lead_id,
          'phone', nullif(trim(p_phone), ''),
          'name', trim(p_name),
          'attemptNumber', 1,
          'runNumber', 1,
          'roundNumber', 1,
          'availableAt', queue_available_at,
          'deadlineAt', queue_deadline_at
        ),
        queue_available_at
      );
    end;
  end if;

$body$;
begin
  select pg_get_functiondef(
    'public.create_allyson_assigned_lead_with_phones(text,text,text[],text,text,text,text,text,text,numeric,text,uuid,timestamptz)'::regprocedure
  ) into definition;

  if position(marker in definition) = 0 then
    raise exception 'Ponto de aplicacao da regra SoniaLima nao encontrado.';
  end if;

  patched := replace(definition, marker, enforcement || marker);
  execute patched;
end;
$$;

-- Repara o envio mais recente feito antes desta garantia server-side.
do $$
declare
  target_lead public.crm_leads%rowtype;
  available_at timestamptz;
  deadline_at timestamptz;
begin
  select lead.* into target_lead
  from public.crm_leads lead
  join public.profiles owner on owner.id = lead.owner_id
  join public.profiles creator on creator.id = lead.created_by
  where lower(trim(owner.email)) = 'unassigned-institutional@example.invalid'
    and lower(trim(creator.email)) = 'crmsoniaallyson@gmail.com'
    and lead.lead_type = 'Venda'
    and lead.assignment_status = 'accepted'
    and lead.created_at >= now() - interval '24 hours'
  order by lead.created_at desc
  limit 1
  for update of lead;

  if target_lead.id is null then return; end if;

  available_at := public.crm_next_lead_queue_moment(now());
  deadline_at := public.crm_add_lead_queue_minutes(available_at, 15);

  update public.crm_leads
  set assignment_status = 'pending', assignment_available_at = available_at,
      assignment_deadline_at = deadline_at, assignment_run_number = 1,
      assignment_reminder_sent_at = null, stage = 'Aguardando atendimento',
      updated_at = now()
  where id = target_lead.id;

  delete from public.lead_assignment_attempts where lead_id = target_lead.id;
  insert into public.lead_assignment_attempts (
    lead_id, broker_id, attempt_number, run_number, round_number, notified_at, deadline_at
  ) values (target_lead.id, target_lead.owner_id, 1, 1, 1, available_at, deadline_at);

  delete from public.crm_notification_outbox
  where payload ->> 'leadId' = target_lead.id::text
    and kind in ('lead_assignment', 'lead_direct_assignment');
  insert into public.crm_notification_outbox (
    recipient_id, kind, title, body, url, payload, available_at
  ) values (
    target_lead.owner_id, 'lead_assignment', 'Novo lead aguardando atendimento',
    'Voce tem 15 minutos uteis para iniciar o atendimento de ' || target_lead.name || '.',
    '/leads', jsonb_build_object(
      'leadId', target_lead.id, 'phone', target_lead.phone, 'name', target_lead.name,
      'attemptNumber', 1, 'runNumber', 1, 'roundNumber', 1,
      'availableAt', available_at, 'deadlineAt', deadline_at
    ), available_at
  );
end;
$$;

commit;

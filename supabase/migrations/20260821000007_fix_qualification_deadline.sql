begin;

drop function if exists public.accept_lead_assignment(uuid);

create or replace function public.accept_lead_assignment(p_lead_id uuid)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  current_profile record;
  accepted_run_number integer;
  new_qualification_deadline timestamptz;
begin
  new_qualification_deadline := public.crm_add_lead_queue_minutes(now(), 120);

  update public.crm_leads as lead
  set assignment_status = 'accepted',
      assignment_available_at = null,
      assignment_deadline_at = now() + interval '24 hours', -- Overwritten on qualification complete, but acts as fallback if something goes wrong
      assignment_reminder_sent_at = null,
      stage = 'Em atendimento',
      post_acceptance_qualification_deadline_at = new_qualification_deadline,
      post_acceptance_call_made = null, post_acceptance_call_result = null, post_acceptance_interaction = null,
      post_acceptance_whatsapp_contacted = null, post_acceptance_whatsapp_print_path = null, post_acceptance_whatsapp_has_whatsapp = null,
      post_acceptance_qualification_completed_at = null, post_acceptance_qualification_expired_at = null
  where lead.id = p_lead_id
    and lead.owner_id = auth.uid()
    and lead.assignment_status = 'pending'
    and lead.assignment_available_at <= now()
    and lead.assignment_deadline_at > now()
    and public.crm_is_lead_queue_hours(now())
    and (
      lead.property_catalog_id is null
      or exists (
          select 1
          from public.crm_property_broker_access as access
          join public.lead_distribution_queue as queue
            on queue.broker_id = access.broker_id
           and queue.lead_type = lead.lead_type
          join public.profiles as profile
            on profile.id = access.broker_id
          where access.property_id = lead.property_catalog_id
            and access.broker_id = auth.uid()
            and profile.role = 'broker'
            and not coalesce(profile.lead_distribution_blocked, false)
            and (profile.lead_distribution_blocked_until is null or profile.lead_distribution_blocked_until <= now())
        )
    )
  returning lead.assignment_run_number into accepted_run_number;

  if not found then
    raise exception 'Este lead nao esta disponivel para aceite neste horario, seu prazo/acesso foi alterado, ou voce esta temporariamente bloqueado.';
  end if;

  update public.lead_assignment_attempts as attempt
  set accepted_at = now()
  where attempt.lead_id = p_lead_id
    and attempt.broker_id = auth.uid()
    and attempt.run_number = accepted_run_number
    and attempt.notified_at <= now()
    and attempt.accepted_at is null
    and attempt.expired_at is null;

  select profile.full_name, profile.email
  into current_profile
  from public.profiles as profile
  where profile.id = auth.uid();

  insert into public.crm_lead_activities (
    lead_id,
    stage,
    note,
    author_id,
    author_name
  ) values (
    p_lead_id,
    'Lead aceito',
    'Atendimento iniciado; qualificacao obrigatoria ate ' || to_char(new_qualification_deadline at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || '.',
    auth.uid(),
    coalesce(nullif(current_profile.full_name, ''), current_profile.email)
  );

  -- Insert scheduled notifications
  insert into public.crm_notification_outbox(recipient_id,kind,title,body,url,payload,available_at) values
    (auth.uid(),'qualification_reminder','Lead assumido — qualificação obrigatória','Você assumiu este lead. Conclua a qualificação obrigatória dentro de 2 horas úteis. O prazo de acompanhamento de 24 horas começará após a conclusão correta da qualificação.','/leads',jsonb_build_object('leadId',p_lead_id),now()),
    (auth.uid(),'qualification_reminder','Qualificação pendente','Restam aproximadamente 1h30 de horário comercial para concluir o atendimento obrigatório deste lead.','/leads',jsonb_build_object('leadId',p_lead_id),public.crm_add_lead_queue_minutes(now(), 30)),
    (auth.uid(),'qualification_reminder','Qualificação pendente','Resta aproximadamente 1 hora comercial para concluir.','/leads',jsonb_build_object('leadId',p_lead_id),public.crm_add_lead_queue_minutes(now(), 60)),
    (auth.uid(),'qualification_reminder','Qualificação pendente','Atenção: faltam aproximadamente 30 minutos de horário comercial para o prazo da qualificação.','/leads',jsonb_build_object('leadId',p_lead_id),public.crm_add_lead_queue_minutes(now(), 90));

  return 'Lead aceito com sucesso.';
end;
$$;

commit;

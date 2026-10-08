begin;

create or replace function public.transfer_lead_directly(
  p_lead_id uuid,
  p_owner_id uuid
)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  lead_record public.crm_leads%rowtype;
  broker_record record;
begin
  if not public.is_allyson_admin() then
    raise exception 'Somente Allyson pode transferir um lead diretamente.';
  end if;

  select lead.*
  into lead_record
  from public.crm_leads as lead
  where lead.id = p_lead_id
  for update;
  if not found then
    raise exception 'Lead nao encontrado.';
  end if;

  select profile.id, profile.full_name, profile.email
  into broker_record
  from public.profiles as profile
  where profile.id = p_owner_id
    and profile.role = 'broker'
    and not coalesce(profile.lead_distribution_blocked, false);
  if not found then
    raise exception 'Corretor indisponivel ou nao encontrado.';
  end if;

  update public.crm_leads as lead
  set owner_id = broker_record.id,
      assignment_status = 'accepted',
      assignment_available_at = null,
      assignment_deadline_at = case
        when lead.stage = 'Em atendimento'
          then public.crm_add_weekday_hours(now(), 24)
        else null
      end,
      assignment_reminder_sent_at = null,
      post_acceptance_qualification_deadline_at = null,
      post_acceptance_qualification_completed_at = null,
      post_acceptance_qualification_expired_at = null,
      post_acceptance_call_made = null,
      post_acceptance_call_result = null,
      post_acceptance_interaction = null,
      post_acceptance_whatsapp_contacted = null,
      post_acceptance_whatsapp_print_path = null,
      post_acceptance_whatsapp_has_whatsapp = null,
      updated_at = now()
  where lead.id = lead_record.id;

  update public.lead_assignment_attempts as attempt
  set expired_at = coalesce(attempt.expired_at, now())
  where attempt.lead_id = lead_record.id
    and attempt.accepted_at is null
    and attempt.expired_at is null;

  delete from public.crm_notification_outbox as notification
  where notification.kind = 'lead_assignment'
    and notification.delivered_at is null
    and notification.payload ->> 'leadId' = lead_record.id::text;

  -- Remove notification for post acceptance
  delete from public.crm_notification_outbox as notification
  where notification.kind = 'qualification_reminder'
    and notification.delivered_at is null
    and notification.payload ->> 'leadId' = lead_record.id::text;

  insert into public.crm_notification_outbox (
    recipient_id,
    kind,
    title,
    body,
    url,
    payload
  ) values (
    broker_record.id,
    'lead_assignment',
    'Novo lead transferido diretamente',
    'Um lead foi transferido diretamente para você pela gestão. Acompanhe o atendimento.',
    '/leads?focusLeadId=' || lead_record.id,
    jsonb_build_object('leadId', lead_record.id)
  );

  insert into public.crm_lead_activities (
    lead_id,
    stage,
    note,
    author_id,
    author_name
  ) values (
    lead_record.id,
    'Transferencia direta',
    'Lead transferido diretamente para ' || coalesce(broker_record.full_name, broker_record.email) || '. O lead segue direto para o acompanhamento normal, sem bloqueio de qualificacao.',
    auth.uid(),
    'Sistema (Gestão)'
  );

  return coalesce(broker_record.full_name, broker_record.email);
end;
$$;

commit;

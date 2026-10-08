begin;

-- A direct management transfer supersedes every previous offer. Keep the
-- notification audit trail, but cancel it for the prior recipient whether or
-- not it was already delivered to the browser.
create or replace function public.transfer_lead_directly(p_lead_id uuid, p_owner_id uuid)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  lead_record public.crm_leads%rowtype;
  broker_record record;
  qualification_deadline timestamptz;
  target_is_accesscrm boolean := public.is_accesscrm_profile(p_owner_id);
begin
  if not public.is_allyson_admin() then
    raise exception 'Somente Administrador pode transferir um lead diretamente.';
  end if;

  select lead.* into lead_record
  from public.crm_leads lead where lead.id = p_lead_id for update;
  if not found then raise exception 'Lead nao encontrado.'; end if;

  select profile.id, profile.full_name, profile.email
  into broker_record
  from public.profiles profile
  where profile.id = p_owner_id
    and (profile.role = 'broker' or public.is_accesscrm_profile(profile.id));
  if not found then raise exception 'Corretor cadastrado nao encontrado.'; end if;

  update public.lead_assignment_attempts attempt
  set expired_at = coalesce(attempt.expired_at, now())
  where attempt.lead_id = lead_record.id
    and attempt.accepted_at is null and attempt.expired_at is null;
  -- Preserve the record for audit, but cancel every prior offer immediately.
  -- A delivered browser notification must never remain actionable after a
  -- management transfer changes the lead owner.
  update public.crm_notification_outbox notification
  set dismissed_at = coalesce(notification.dismissed_at, now()),
      delivery_status = 'cancelled'
  where notification.dismissed_at is null
    and notification.payload ->> 'leadId' = lead_record.id::text
    and notification.kind in (
      'lead_assignment', 'lead_direct_assignment', 'qualification_reminder');

  qualification_deadline := case when target_is_accesscrm then null
    else public.crm_add_lead_queue_minutes(now(), 120) end;
  perform set_config('crm.allyson_direct_transfer_lead_id', lead_record.id::text, true);
  perform set_config('crm.allyson_direct_transfer_owner_id', broker_record.id::text, true);

  update public.crm_leads lead
  set owner_id = broker_record.id,
      assignment_status = 'accepted',
      assignment_available_at = null,
      assignment_deadline_at = case when target_is_accesscrm then null
        else now() + interval '24 hours' end,
      assignment_reminder_sent_at = null,
      stage = case when target_is_accesscrm then lead_record.stage else 'Em atendimento' end,
      commercial_qualification_required = case when target_is_accesscrm then false
        else lead.commercial_qualification_required end,
      post_acceptance_qualification_deadline_at = qualification_deadline,
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

  perform set_config('crm.allyson_direct_transfer_lead_id', '', true);
  perform set_config('crm.allyson_direct_transfer_owner_id', '', true);

  insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
  values (
    broker_record.id,
    'lead_direct_assignment',
    'Novo lead atribuido diretamente',
    case when target_is_accesscrm
      then 'Um lead foi atribuido definitivamente ao SoniaLima, sem prazo ou qualificacao.'
      else 'Um lead foi atribuido diretamente a voce. Responda agora a qualificacao obrigatoria.'
    end,
    '/leads?focusLeadId=' || lead_record.id,
    jsonb_build_object('leadId', lead_record.id, 'assignedDirectly', true)
  );

  insert into public.crm_lead_activities (lead_id, stage, note, author_id, author_name)
  values (
    lead_record.id,
    'Transferencia direta',
    case when target_is_accesscrm
      then 'Lead transferido definitivamente para SoniaLima, sem prazo, qualificacao ou penalidade.'
      else 'Lead transferido diretamente para ' ||
        coalesce(broker_record.full_name, broker_record.email) ||
        '. A qualificacao obrigatoria de 2 horas uteis foi iniciada.'
    end,
    auth.uid(),
    'Sistema (Gestao)'
  );

  return coalesce(broker_record.full_name, broker_record.email);
end;
$$;

revoke all on function public.transfer_lead_directly(uuid, uuid) from public, anon;
grant execute on function public.transfer_lead_directly(uuid, uuid) to authenticated;

commit;

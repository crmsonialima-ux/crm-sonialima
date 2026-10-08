begin;

-- 1. Remover o bloqueio de "Resultado da Visita" ao trocar de etapa
create or replace function public.enforce_lead_commercial_qualification()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  old_stage text := public.crm_normalize_property_match_text(old.stage);
  new_stage text := public.crm_normalize_property_match_text(new.stage);
  is_initial_visit_creation boolean := coalesce(
    current_setting('crm.initial_visit_lead_id', true),
    ''
  ) = new.id::text;
  is_direct_user_change boolean := auth.uid() is not null
    and pg_trigger_depth() = 1
    and not is_initial_visit_creation;
begin
  -- Somente leads novos carregam commercial_qualification_required=true.
  -- Exige qualificacao comercial ANTES de sair de Em atendimento
  if is_direct_user_change
     and new.commercial_qualification_required
     and old_stage = 'em atendimento'
     and new_stage <> 'em atendimento' then
    if new.has_property_to_sell is null
       or new.needs_financing is null
       or new.will_use_fgts is null
       or new.banking_correspondent_presented is null then
      raise exception 'Responda todas as perguntas da qualificacao comercial antes de sair de Em atendimento.';
    end if;
    if new.has_property_to_sell and (
      nullif(trim(new.property_to_sell_location), '') is null
      or new.property_to_sell_value is null
      or new.property_to_sell_value <= 0
    ) then
      raise exception 'Informe a localizacao e o valor do imovel que o lead pretende vender.';
    end if;
  end if;

  return new;
end;
$$;

-- 2. Atualizar a transferência direta do Allyson para resetar a qualificação de 2h
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
      post_acceptance_qualification_deadline_at = now() + interval '2 hours',
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
    'Allyson transferiu um lead diretamente para voce. Voce tem 2 horas para fazer a qualificacao (ligar e chamar no WhatsApp).',
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
    'Lead transferido diretamente para ' || coalesce(broker_record.full_name, broker_record.email) || '. O corretor tem 2 horas para qualificar o atendimento.',
    auth.uid(),
    'Sistema (Allyson)'
  );

  return 'Lead transferido diretamente com sucesso. A qualificação de 2h foi reiniciada.';
end;
$$;

-- 3. Trigger para cancelar ofertas similares caso a etapa vá para inativos
create or replace function public.clear_inactive_matches_on_stage_change()
returns trigger
language plpgsql
security definer
as $$
declare
  norm_new text := public.crm_normalize_property_match_text(new.stage);
begin
  if norm_new in ('comprou', 'telefone nao existe', 'telefone não existe') then
    update public.crm_property_match_notifications
    set dismissed_at = now()
    where lead_id = new.id and dismissed_at is null and offer_started_at is null;
  end if;
  return new;
end;
$$;

drop trigger if exists lead_inactive_matches_clear on public.crm_leads;
create trigger lead_inactive_matches_clear
after update of stage
on public.crm_leads
for each row
when (old.stage is distinct from new.stage)
execute function public.clear_inactive_matches_on_stage_change();

commit;

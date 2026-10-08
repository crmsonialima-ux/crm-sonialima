begin;

-- The INSERT default is "accepted" for historical reasons. It is not an
-- actual acceptance: the assignment trigger changes normal queue leads to
-- pending immediately afterwards. Keep permanent ownership in a separate,
-- explicit flag so the INSERT default cannot bypass the queue.
alter table public.crm_leads
  add column if not exists accesscrm_permanent_owner boolean not null default false;

create or replace function public.enforce_accesscrm_premium_lead_rules()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  new_owner_is_accesscrm boolean := public.is_accesscrm_profile(new.owner_id);
  old_owner_is_accesscrm boolean := false;
  direct_transfer_owner_id text := nullif(
    current_setting('crm.allyson_direct_transfer_owner_id', true),
    ''
  );
begin
  if tg_op = 'UPDATE' then
    old_owner_is_accesscrm := public.is_accesscrm_profile(old.owner_id);

    if old_owner_is_accesscrm
       and old.accesscrm_permanent_owner
       and new.owner_id is distinct from old.owner_id then
      raise exception 'Lead aceito pelo SoniaLima pertence permanentemente ao AcessoCRM.';
    end if;

    if old_owner_is_accesscrm and old.accesscrm_permanent_owner then
      new.assignment_status := 'accepted';
      new.accesscrm_permanent_owner := true;
    end if;
  end if;

  if not new_owner_is_accesscrm then
    new.accesscrm_permanent_owner := false;
    return new;
  end if;

  if direct_transfer_owner_id = new.owner_id::text then
    new.accesscrm_permanent_owner := true;
  end if;

  new.commercial_qualification_required := false;
  new.post_acceptance_qualification_deadline_at := null;
  new.post_acceptance_qualification_completed_at := null;
  new.post_acceptance_qualification_expired_at := null;
  new.post_acceptance_call_made := null;
  new.post_acceptance_call_result := null;
  new.post_acceptance_interaction := null;
  new.post_acceptance_whatsapp_contacted := null;
  new.post_acceptance_whatsapp_print_path := null;
  new.post_acceptance_whatsapp_has_whatsapp := null;

  if new.assignment_status = 'accepted' and new.accesscrm_permanent_owner then
    new.assignment_available_at := null;
    new.assignment_deadline_at := null;
    new.assignment_reminder_sent_at := null;

    if tg_op = 'INSERT'
       or old.accesscrm_permanent_owner is distinct from true
       or new.owner_id is distinct from old.owner_id then
      new.stage := '';
    end if;
  end if;

  return new;
end;
$$;

-- Capture offers that the old premium guard incorrectly froze as accepted.
create temporary table repaired_accesscrm_offers on commit drop as
select lead.id
from public.crm_leads lead
join public.profiles owner on owner.id = lead.owner_id
where lower(trim(owner.email)) = 'unassigned-institutional@example.invalid'
  and lead.assignment_status = 'accepted'
  and lead.stage = 'Aguardando atendimento'
  and exists (
    select 1
    from public.lead_assignment_attempts attempt
    where attempt.lead_id = lead.id
      and attempt.broker_id = lead.owner_id
      and attempt.accepted_at is null
  );

update public.crm_leads lead
set assignment_status = 'pending',
    assignment_available_at = public.crm_next_lead_queue_moment(now()),
    assignment_deadline_at = public.crm_add_lead_queue_minutes(
      public.crm_next_lead_queue_moment(now()),
      20
    ),
    assignment_reminder_sent_at = null,
    accesscrm_permanent_owner = false,
    updated_at = now()
from repaired_accesscrm_offers repaired
where repaired.id = lead.id;

update public.lead_assignment_attempts attempt
set notified_at = lead.assignment_available_at,
    deadline_at = lead.assignment_deadline_at,
    accepted_at = null,
    expired_at = null
from public.crm_leads lead
join repaired_accesscrm_offers repaired on repaired.id = lead.id
where attempt.lead_id = lead.id
  and attempt.broker_id = lead.owner_id
  and attempt.run_number = lead.assignment_run_number;

update public.crm_notification_outbox notification
set dismissed_at = coalesce(notification.dismissed_at, now()),
    read_at = coalesce(notification.read_at, now()),
    delivery_status = case
      when notification.delivered_at is null then 'cancelled'
      else notification.delivery_status
    end
where notification.kind = 'lead_assignment'
  and exists (
    select 1
    from repaired_accesscrm_offers repaired
    where notification.payload ->> 'leadId' = repaired.id::text
  );

insert into public.crm_notification_outbox (
  recipient_id,
  kind,
  title,
  body,
  url,
  payload,
  available_at
)
select
  lead.owner_id,
  'lead_assignment',
  'Novo lead para aceitar',
  'Voce tem 20 minutos para aceitar o lead ' || lead.name || '.',
  '/leads?focusLeadId=' || lead.id::text,
  jsonb_build_object(
    'leadId', lead.id,
    'phone', lead.phone,
    'name', lead.name,
    'attemptNumber', attempt.attempt_number,
    'runNumber', attempt.run_number,
    'roundNumber', attempt.round_number,
    'availableAt', lead.assignment_available_at,
    'deadlineAt', lead.assignment_deadline_at
  ),
  lead.assignment_available_at
from public.crm_leads lead
join repaired_accesscrm_offers repaired on repaired.id = lead.id
join lateral (
  select current_attempt.attempt_number,
         current_attempt.run_number,
         current_attempt.round_number
  from public.lead_assignment_attempts current_attempt
  where current_attempt.lead_id = lead.id
    and current_attempt.broker_id = lead.owner_id
    and current_attempt.run_number = lead.assignment_run_number
  order by current_attempt.attempt_number desc
  limit 1
) attempt on true;

-- Every other accepted AcessoCRM lead is a real, permanent ownership.
update public.crm_leads lead
set accesscrm_permanent_owner = true,
    updated_at = now()
from public.profiles owner
where owner.id = lead.owner_id
  and lower(trim(owner.email)) = 'unassigned-institutional@example.invalid'
  and lead.assignment_status = 'accepted'
  and not lead.accesscrm_permanent_owner;

drop function if exists public.accept_lead_assignment(uuid);
create function public.accept_lead_assignment(p_lead_id uuid)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  current_profile record;
  accepted_run_number integer;
  qualification_deadline timestamptz;
  is_accesscrm boolean := public.is_accesscrm_profile(auth.uid());
  manual_release boolean := false;
begin
  select profile.full_name, profile.email
  into current_profile
  from public.profiles profile
  where profile.id = auth.uid();
  if not found then raise exception 'Perfil nao encontrado.'; end if;

  select exists (
    select 1 from public.crm_notification_outbox notification
    where notification.kind = 'lead_assignment'
      and notification.recipient_id = auth.uid()
      and notification.payload ->> 'leadId' = p_lead_id::text
      and coalesce((notification.payload ->> 'manualRelease')::boolean, false)
  ) into manual_release;

  qualification_deadline := case when is_accesscrm then null
    else public.crm_add_lead_queue_minutes(now(), 120) end;

  update public.crm_leads lead
  set assignment_status = 'accepted',
      accesscrm_permanent_owner = is_accesscrm,
      assignment_available_at = null,
      assignment_deadline_at = case when is_accesscrm then null
        else now() + interval '24 hours' end,
      assignment_reminder_sent_at = null,
      stage = case when is_accesscrm then lead.stage else 'Em atendimento' end,
      commercial_qualification_required = case when is_accesscrm then false
        else lead.commercial_qualification_required end,
      post_acceptance_qualification_deadline_at = qualification_deadline,
      post_acceptance_call_made = null,
      post_acceptance_call_result = null,
      post_acceptance_interaction = null,
      post_acceptance_whatsapp_contacted = null,
      post_acceptance_whatsapp_print_path = null,
      post_acceptance_whatsapp_has_whatsapp = null,
      post_acceptance_qualification_completed_at = null,
      post_acceptance_qualification_expired_at = null,
      updated_at = now()
  where lead.id = p_lead_id
    and lead.owner_id = auth.uid()
    and lead.assignment_status = 'pending'
    and lead.assignment_available_at <= now()
    and lead.assignment_deadline_at > now()
    and (public.crm_is_lead_queue_hours(now()) or manual_release)
    and (
      is_accesscrm
      or lead.property_catalog_id is null
      or exists (
        select 1
        from public.crm_property_broker_access access
        join public.lead_distribution_queue queue
          on queue.broker_id = access.broker_id
         and queue.lead_type = lead.lead_type
        join public.profiles profile on profile.id = access.broker_id
        where access.property_id = lead.property_catalog_id
          and access.broker_id = auth.uid()
          and profile.role = 'broker'
          and not coalesce(profile.lead_distribution_blocked, false)
          and (profile.lead_distribution_blocked_until is null
               or profile.lead_distribution_blocked_until <= now())
      )
    )
  returning lead.assignment_run_number into accepted_run_number;

  if not found then
    raise exception 'Este lead nao esta mais disponivel para aceite.';
  end if;

  update public.lead_assignment_attempts attempt
  set accepted_at = now()
  where attempt.lead_id = p_lead_id
    and attempt.broker_id = auth.uid()
    and attempt.run_number = accepted_run_number
    and attempt.notified_at <= now()
    and attempt.accepted_at is null
    and attempt.expired_at is null;

  insert into public.crm_lead_activities (lead_id, stage, note, author_id, author_name)
  values (
    p_lead_id,
    'Lead aceito',
    case when is_accesscrm
      then 'Lead aceito pelo SoniaLima sem prazo, qualificacao ou penalidade.'
      else 'Atendimento iniciado; qualificacao obrigatoria ate ' ||
        to_char(qualification_deadline at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || '.'
    end,
    auth.uid(),
    coalesce(nullif(current_profile.full_name, ''), current_profile.email)
  );

  delete from public.crm_notification_outbox notification
  where notification.kind = 'qualification_reminder'
    and notification.recipient_id = auth.uid()
    and notification.payload ->> 'leadId' = p_lead_id::text
    and notification.delivered_at is null;

  if not is_accesscrm then
    insert into public.crm_notification_outbox (
      recipient_id, kind, title, body, url, payload, available_at
    ) values
      (auth.uid(), 'qualification_reminder', 'Lead assumido - qualificacao obrigatoria',
       'Conclua todas as perguntas dentro de 2 horas uteis.', '/leads',
       jsonb_build_object('leadId', p_lead_id), now()),
      (auth.uid(), 'qualification_reminder', 'Qualificacao pendente',
       'Restam aproximadamente 1h30 para concluir.', '/leads',
       jsonb_build_object('leadId', p_lead_id), public.crm_add_lead_queue_minutes(now(), 30)),
      (auth.uid(), 'qualification_reminder', 'Qualificacao pendente',
       'Resta aproximadamente 1 hora para concluir.', '/leads',
       jsonb_build_object('leadId', p_lead_id), public.crm_add_lead_queue_minutes(now(), 60)),
      (auth.uid(), 'qualification_reminder', 'Qualificacao pendente',
       'Faltam aproximadamente 30 minutos para concluir.', '/leads',
       jsonb_build_object('leadId', p_lead_id), public.crm_add_lead_queue_minutes(now(), 90));
  end if;

  return case when is_accesscrm
    then 'Lead aceito definitivamente pelo SoniaLima.'
    else 'Lead aceito com sucesso.' end;
end;
$$;

revoke all on function public.accept_lead_assignment(uuid) from public, anon;
grant execute on function public.accept_lead_assignment(uuid) to authenticated;

comment on column public.crm_leads.accesscrm_permanent_owner is
  'True only after AcessoCRM explicitly accepts a queue offer or receives a direct transfer.';

commit;

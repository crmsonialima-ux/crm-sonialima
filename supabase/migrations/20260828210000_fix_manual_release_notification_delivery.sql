begin;

-- A liberacao manual do Allyson precisa vencer o adiamento global de
-- notificacoes antes que o normalizador especifico da esteira seja executado.
create or replace function public.crm_apply_notification_business_hours()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  event_moment timestamptz;
begin
  if new.kind = 'lead_assignment'
     and coalesce((new.payload ->> 'manualRelease')::boolean, false) then
    new.available_at := coalesce(new.available_at, now());
    return new;
  end if;

  if tg_op = 'UPDATE' then
    if new.kind is not distinct from old.kind
       and new.created_at is not distinct from old.created_at
       and new.available_at is not distinct from old.available_at then
      return new;
    end if;
  end if;

  event_moment := coalesce(new.created_at, now());
  new.available_at := public.crm_next_business_moment(
    greatest(coalesce(new.available_at, event_moment), event_moment)
  );

  return new;
end;
$$;

-- Alem de liberar uma notificacao existente, recria o aviso quando algum
-- fluxo anterior deixou o lead pendente sem uma linha no outbox.
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
begin
  if not public.is_allyson_admin() then
    raise exception 'Apenas Allyson pode antecipar leads programados.';
  end if;

  select lead.* into lead_row
  from public.crm_leads lead
  where lead.id = p_lead_id
  for update;

  if not found then raise exception 'Lead nao encontrado.'; end if;
  if lead_row.assignment_available_at is null
     or lead_row.assignment_available_at <= now() then
    raise exception 'O lead nao esta programado para o futuro.';
  end if;

  select coalesce(nullif(profile.full_name, ''), profile.email)
  into actor_name
  from public.profiles profile
  where profile.id = auth.uid();

  update public.crm_leads
  set assignment_available_at = now(),
      assignment_deadline_at = target_deadline,
      updated_at = now()
  where id = p_lead_id;

  insert into public.crm_lead_activities (
    lead_id, stage, note, author_id, author_name
  ) values (
    p_lead_id,
    lead_row.stage,
    'Liberou antecipadamente a distribuicao do lead programado.',
    auth.uid(),
    coalesce(actor_name, 'Allyson')
  );

  update public.lead_assignment_attempts
  set notified_at = now(), deadline_at = target_deadline
  where lead_id = p_lead_id
    and attempt_number = 1
    and run_number = lead_row.assignment_run_number;

  update public.crm_notification_outbox notification
  set available_at = now(),
      dismissed_at = null,
      read_at = null,
      payload = jsonb_set(
        jsonb_set(
          jsonb_set(coalesce(notification.payload, '{}'::jsonb),
            '{availableAt}', to_jsonb(now()::timestamptz), true),
          '{deadlineAt}', to_jsonb(target_deadline), true),
        '{manualRelease}', 'true'::jsonb, true)
  where notification.kind = 'lead_assignment'
    and notification.recipient_id = lead_row.owner_id
    and notification.payload ->> 'leadId' = p_lead_id::text;

  if not found then
    insert into public.crm_notification_outbox (
      recipient_id, kind, title, body, url, payload, available_at
    ) values (
      lead_row.owner_id,
      'lead_assignment',
      'Novo lead aguardando atendimento',
      'Voce tem 20 minutos para iniciar o atendimento de ' || lead_row.name || '.',
      '/leads',
      jsonb_build_object(
        'leadId', lead_row.id,
        'phone', lead_row.phone,
        'name', lead_row.name,
        'attemptNumber', 1,
        'runNumber', lead_row.assignment_run_number,
        'roundNumber', 1,
        'availableAt', now(),
        'deadlineAt', target_deadline,
        'manualRelease', true
      ),
      now()
    );
  end if;
end;
$$;

revoke all on function public.allyson_release_scheduled_lead(uuid)
  from public, anon, authenticated;
grant execute on function public.allyson_release_scheduled_lead(uuid)
  to authenticated;

-- Reabre o lead TESTE mostrado no diagnostico e garante seu aviso imediato.
with target as (
  update public.crm_leads lead
  set assignment_available_at = now(),
      assignment_deadline_at = now() + interval '20 minutes',
      assignment_reminder_sent_at = null,
      updated_at = now()
  where lead.id = '5c714d04-9823-451f-9692-c7e0a622a4aa'::uuid
    and lead.assignment_status = 'pending'
  returning lead.*
)
update public.lead_assignment_attempts attempt
set notified_at = now(),
    deadline_at = now() + interval '20 minutes',
    expired_at = null
from target
where attempt.lead_id = target.id
  and attempt.broker_id = target.owner_id
  and attempt.run_number = target.assignment_run_number;

with target as (
  select lead.*
  from public.crm_leads lead
  where lead.id = '5c714d04-9823-451f-9692-c7e0a622a4aa'::uuid
    and lead.assignment_status = 'pending'
)
update public.crm_notification_outbox notification
set available_at = now(),
    dismissed_at = null,
    read_at = null,
    payload = jsonb_set(
      jsonb_set(
        jsonb_set(coalesce(notification.payload, '{}'::jsonb),
          '{availableAt}', to_jsonb(now()::timestamptz), true),
        '{deadlineAt}', to_jsonb(target.assignment_deadline_at), true),
      '{manualRelease}', 'true'::jsonb, true)
from target
where notification.kind = 'lead_assignment'
  and notification.recipient_id = target.owner_id
  and notification.payload ->> 'leadId' = target.id::text;

insert into public.crm_notification_outbox (
  recipient_id, kind, title, body, url, payload, available_at
)
select
  lead.owner_id,
  'lead_assignment',
  'Novo lead aguardando atendimento',
  'Voce tem 20 minutos para iniciar o atendimento de ' || lead.name || '.',
  '/leads',
  jsonb_build_object(
    'leadId', lead.id,
    'phone', lead.phone,
    'name', lead.name,
    'attemptNumber', 1,
    'runNumber', lead.assignment_run_number,
    'roundNumber', 1,
    'availableAt', now(),
    'deadlineAt', lead.assignment_deadline_at,
    'manualRelease', true
  ),
  now()
from public.crm_leads lead
where lead.id = '5c714d04-9823-451f-9692-c7e0a622a4aa'::uuid
  and lead.assignment_status = 'pending'
  and not exists (
    select 1
    from public.crm_notification_outbox notification
    where notification.kind = 'lead_assignment'
      and notification.recipient_id = lead.owner_id
      and notification.payload ->> 'leadId' = lead.id::text
  );

commit;

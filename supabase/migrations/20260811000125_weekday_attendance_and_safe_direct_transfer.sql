begin;

-- The 24-hour attendance SLA counts continuous hours from Monday to Friday.
-- Saturday and Sunday are a full pause; the remaining time resumes on Monday.
create or replace function public.crm_add_weekday_hours(
  p_start timestamptz,
  p_hours integer
)
returns timestamptz
language plpgsql
stable
set search_path = pg_catalog, public
as $$
declare
  local_cursor timestamp;
  weekday_number integer;
  weekend_start timestamp;
  available_interval interval;
  remaining_interval interval;
begin
  if p_start is null then
    return null;
  end if;
  if p_hours is null or p_hours < 0 or p_hours > 8760 then
    raise exception 'Informe uma duracao entre 0 e 8760 horas.';
  end if;

  local_cursor := p_start at time zone 'America/Sao_Paulo';
  weekday_number := extract(isodow from local_cursor)::integer;

  if weekday_number = 6 then
    local_cursor := local_cursor + interval '2 days';
  elsif weekday_number = 7 then
    local_cursor := local_cursor + interval '1 day';
  end if;

  remaining_interval := make_interval(hours => p_hours);
  while remaining_interval > interval '0' loop
    weekday_number := extract(isodow from local_cursor)::integer;
    weekend_start := local_cursor::date + (6 - weekday_number) + time '00:00';
    available_interval := greatest(weekend_start - local_cursor, interval '0');

    if remaining_interval < available_interval then
      local_cursor := local_cursor + remaining_interval;
      remaining_interval := interval '0';
    else
      remaining_interval := remaining_interval - available_interval;
      local_cursor := weekend_start + interval '2 days';
    end if;
  end loop;

  return local_cursor at time zone 'America/Sao_Paulo';
end;
$$;

create or replace function public.enforce_attendance_deadline()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if new.stage = 'Em atendimento'
    and (
      tg_op = 'INSERT'
      or old.stage is distinct from 'Em atendimento'
      or new.assignment_status is distinct from 'accepted'
      or new.assignment_deadline_at is null
    )
  then
    new.assignment_status := 'accepted';
    new.assignment_deadline_at := public.crm_add_weekday_hours(now(), 24);
  end if;

  return new;
end;
$$;

create or replace function public.extend_lead_attendance(
  p_lead_id uuid,
  p_note text
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  current_profile record;
begin
  if nullif(trim(p_note), '') is null then
    raise exception 'Informe o motivo para manter o lead em atendimento.';
  end if;

  update public.crm_leads as lead
  set assignment_status = 'accepted',
      assignment_deadline_at = public.crm_add_weekday_hours(now(), 24),
      assignment_reminder_sent_at = null
  where lead.id = p_lead_id
    and (lead.owner_id = auth.uid() or public.is_admin())
    and lead.stage = 'Em atendimento';

  if not found then
    raise exception 'Este lead nao esta disponivel para renovacao de atendimento.';
  end if;

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
    'Ainda em atendimento',
    trim(p_note),
    auth.uid(),
    coalesce(nullif(current_profile.full_name, ''), current_profile.email)
  );
end;
$$;

-- Keep the direct-update guard aligned with the weekend-aware deadline derived
-- by enforce_attendance_deadline().
create or replace function public.protect_lead_assignment_system_fields()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  trusted_backend boolean := current_user in (
    'postgres',
    'service_role',
    'supabase_admin'
  );
  allowed_progress_deadline_clear boolean;
  allowed_attendance_deadline_start boolean;
begin
  if trusted_backend then
    return new;
  end if;

  if old.assignment_status = 'pending'
     and new.stage is distinct from old.stage then
    raise exception 'Aceite o lead pela acao Estou em atendimento antes de alterar sua etapa.';
  elsif old.assignment_status = 'exhausted'
        and new.stage is distinct from old.stage then
    raise exception 'Somente Allyson pode reiniciar e alterar um lead com a esteira esgotada.';
  end if;

  allowed_progress_deadline_clear :=
    old.assignment_status = 'accepted'
    and old.stage = 'Em atendimento'
    and new.stage is distinct from old.stage
    and new.stage <> 'Em atendimento'
    and new.assignment_deadline_at is null;

  allowed_attendance_deadline_start :=
    old.assignment_status = 'accepted'
    and old.stage <> 'Em atendimento'
    and new.stage = 'Em atendimento'
    and new.assignment_status = 'accepted'
    and new.assignment_deadline_at = public.crm_add_weekday_hours(now(), 24);

  if new.assignment_status is distinct from old.assignment_status
     or new.assignment_available_at is distinct from old.assignment_available_at
     or new.assignment_run_number is distinct from old.assignment_run_number
     or new.assignment_reminder_sent_at is distinct from old.assignment_reminder_sent_at
     or (
       new.assignment_deadline_at is distinct from old.assignment_deadline_at
       and not allowed_progress_deadline_clear
       and not allowed_attendance_deadline_start
     ) then
    raise exception 'Os controles da esteira so podem ser alterados pelas acoes seguras do CRM.';
  end if;

  return new;
end;
$$;

-- Transfers initiated by Allyson are direct ownership changes, not new queue
-- attempts. This also repairs the same pending-state mismatch for existing leads.
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

  insert into public.crm_notification_outbox (
    recipient_id,
    kind,
    title,
    body,
    url,
    payload
  ) values (
    broker_record.id,
    'lead_direct_assignment',
    'Lead transferido por Allyson',
    lead_record.name || ' foi transferido diretamente para voce e nao esta na fila automatica.',
    '/leads',
    jsonb_build_object(
      'leadId', lead_record.id,
      'name', lead_record.name,
      'phone', lead_record.phone,
      'assignedDirectly', true
    )
  );

  insert into public.crm_lead_activities (
    lead_id,
    stage,
    note,
    author_id,
    author_name
  ) values (
    lead_record.id,
    'Lead transferido diretamente',
    'Allyson transferiu o lead para '
      || coalesce(nullif(broker_record.full_name, ''), broker_record.email)
      || ' sem iniciar a fila automatica.',
    auth.uid(),
    'crmallyson'
  );

  return coalesce(nullif(broker_record.full_name, ''), broker_record.email);
end;
$$;

-- Old direct assignments could retain assignment_status=pending even after a
-- broker had already progressed the lead. A genuine queue item always stays in
-- "Aguardando atendimento", so other stages are safe to normalize.
create temporary table crm_repaired_direct_leads on commit drop as
select lead.id
from public.crm_leads as lead
where lead.assignment_status = 'pending'
  and lead.stage <> 'Aguardando atendimento';

update public.crm_leads as lead
set assignment_status = 'accepted',
    assignment_available_at = null,
    assignment_deadline_at = case
      when lead.stage = 'Em atendimento'
        then public.crm_add_weekday_hours(now(), 24)
      else null
    end,
    assignment_reminder_sent_at = null,
    updated_at = now()
where lead.id in (select repaired.id from crm_repaired_direct_leads as repaired);

update public.lead_assignment_attempts as attempt
set expired_at = coalesce(attempt.expired_at, now())
where attempt.lead_id in (select repaired.id from crm_repaired_direct_leads as repaired)
  and attempt.accepted_at is null
  and attempt.expired_at is null;

delete from public.crm_notification_outbox as notification
where notification.kind = 'lead_assignment'
  and notification.delivered_at is null
  and notification.payload ->> 'leadId' in (
    select repaired.id::text from crm_repaired_direct_leads as repaired
  );

-- Recalculate only active attendance deadlines; already-expired rows stay
-- untouched for the processor instead of being resurrected by this migration.
update public.crm_leads as lead
set assignment_deadline_at = public.crm_add_weekday_hours(
      lead.assignment_deadline_at - interval '24 hours',
      24
    )
where lead.assignment_status = 'accepted'
  and lead.stage = 'Em atendimento'
  and lead.assignment_deadline_at > now()
  and lead.id not in (select repaired.id from crm_repaired_direct_leads as repaired);

revoke all on function public.crm_add_weekday_hours(timestamptz, integer)
  from public, anon, authenticated;
grant execute on function public.crm_add_weekday_hours(timestamptz, integer)
  to authenticated, service_role;

revoke all on function public.enforce_attendance_deadline()
  from public, anon, authenticated;
revoke all on function public.extend_lead_attendance(uuid, text)
  from public, anon;
grant execute on function public.extend_lead_attendance(uuid, text)
  to authenticated;

revoke all on function public.transfer_lead_directly(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.transfer_lead_directly(uuid, uuid)
  to authenticated;

comment on function public.crm_add_weekday_hours(timestamptz, integer) is
  'Soma horas corridas de segunda a sexta e pausa integralmente aos sabados e domingos.';

commit;

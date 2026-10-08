begin;

-- Allyson's account was anchored to this immutable auth UUID by migration 70.
-- Keep the role and normalized e-mail checks as defense in depth, but do not
-- let another administrator impersonate Allyson by editing a mutable profile.
create or replace function public.is_allyson_admin()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1
    from public.profiles as profile
    where profile.id = auth.uid()
      and profile.id = '37094db7-2457-48f2-8573-40c887e547e5'::uuid
      and profile.role = 'admin'
      and lower(trim(profile.email)) = 'crmsoniaallyson@gmail.com'
  );
$$;

revoke all on function public.is_allyson_admin() from public, anon;
grant execute on function public.is_allyson_admin() to authenticated, service_role;

-- Operational switches are kept in one server-owned row. Application users
-- can only reach it through the Allyson-only RPCs below.
create table if not exists public.crm_operational_settings (
  singleton boolean primary key default true check (singleton),
  property_document_notifications_enabled boolean not null default true,
  defer_new_leads_to_next_day_nine boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id) on delete set null
);

insert into public.crm_operational_settings (
  singleton,
  property_document_notifications_enabled,
  defer_new_leads_to_next_day_nine
)
values (true, true, false)
on conflict (singleton) do nothing;

alter table public.crm_operational_settings enable row level security;
revoke all privileges on table public.crm_operational_settings
  from public, anon, authenticated;

create or replace function public.get_allyson_operational_settings()
returns public.crm_operational_settings
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  result public.crm_operational_settings;
begin
  if not public.is_allyson_admin() then
    raise exception 'Somente Allyson pode consultar os controles operacionais.';
  end if;

  select settings.*
  into result
  from public.crm_operational_settings as settings
  where settings.singleton;

  return result;
end;
$$;

create or replace function public.set_property_document_notifications_enabled(
  p_enabled boolean
)
returns public.crm_operational_settings
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  result public.crm_operational_settings;
begin
  if not public.is_allyson_admin() then
    raise exception 'Somente Allyson pode alterar as notificacoes de documentos dos imoveis.';
  end if;
  if p_enabled is null then
    raise exception 'Informe se as notificacoes de documentos devem ficar ativas.';
  end if;

  update public.crm_operational_settings as settings
  set property_document_notifications_enabled = p_enabled,
      updated_at = now(),
      updated_by = auth.uid()
  where settings.singleton
  returning settings.* into result;

  if not found then
    raise exception 'Configuracao operacional nao encontrada.';
  end if;

  if not p_enabled then
    delete from public.crm_notification_outbox as notification
    where notification.kind = 'property_document_reminder'
      and notification.delivered_at is null;
  end if;

  return result;
end;
$$;

create or replace function public.set_defer_new_leads_to_next_day_nine(
  p_enabled boolean
)
returns public.crm_operational_settings
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  result public.crm_operational_settings;
begin
  if not public.is_allyson_admin() then
    raise exception 'Somente Allyson pode alterar o horario de liberacao dos novos leads.';
  end if;
  if p_enabled is null then
    raise exception 'Informe se os novos leads devem aguardar ate as 09:00 do dia seguinte.';
  end if;

  update public.crm_operational_settings as settings
  set defer_new_leads_to_next_day_nine = p_enabled,
      updated_at = now(),
      updated_by = auth.uid()
  where settings.singleton
  returning settings.* into result;

  if not found then
    raise exception 'Configuracao operacional nao encontrada.';
  end if;

  return result;
end;
$$;

revoke all on function public.get_allyson_operational_settings()
  from public, anon, authenticated;
revoke all on function public.set_property_document_notifications_enabled(boolean)
  from public, anon, authenticated;
revoke all on function public.set_defer_new_leads_to_next_day_nine(boolean)
  from public, anon, authenticated;
grant execute on function public.get_allyson_operational_settings() to authenticated;
grant execute on function public.set_property_document_notifications_enabled(boolean)
  to authenticated;
grant execute on function public.set_defer_new_leads_to_next_day_nine(boolean)
  to authenticated;

-- Returning null from a BEFORE INSERT trigger suppresses only the reminder row;
-- document uploads, other notifications and already delivered history remain intact.
create or replace function public.suppress_disabled_property_document_reminder()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  notifications_enabled boolean := true;
begin
  if new.kind is distinct from 'property_document_reminder' then
    return new;
  end if;

  -- The shared row lock closes the race with the disabling RPC: an insertion
  -- either finishes before the setter (and is deleted there) or observes the
  -- committed disabled state and is suppressed here.
  select settings.property_document_notifications_enabled
  into notifications_enabled
  from public.crm_operational_settings as settings
  where settings.singleton
  for share;

  if not coalesce(notifications_enabled, true) then
    return null;
  end if;

  return new;
end;
$$;

revoke all on function public.suppress_disabled_property_document_reminder()
  from public, anon, authenticated;

drop trigger if exists aa_suppress_disabled_property_document_reminder
  on public.crm_notification_outbox;
create trigger aa_suppress_disabled_property_document_reminder
before insert on public.crm_notification_outbox
for each row execute function public.suppress_disabled_property_document_reminder();

-- A run is one complete execution of the conveyor. Every run has at most two
-- rounds through the brokers currently eligible for that lead.
alter table public.crm_leads
  add column if not exists assignment_available_at timestamptz,
  add column if not exists assignment_run_number integer not null default 1;

alter table public.crm_leads
  drop constraint if exists crm_leads_assignment_run_number_check;
alter table public.crm_leads
  add constraint crm_leads_assignment_run_number_check
  check (assignment_run_number > 0);

alter table public.lead_assignment_attempts
  add column if not exists run_number integer not null default 1,
  add column if not exists round_number smallint not null default 1;

alter table public.lead_assignment_attempts
  drop constraint if exists lead_assignment_attempts_run_number_check;
alter table public.lead_assignment_attempts
  add constraint lead_assignment_attempts_run_number_check
  check (run_number > 0);

alter table public.lead_assignment_attempts
  drop constraint if exists lead_assignment_attempts_round_number_check;
alter table public.lead_assignment_attempts
  add constraint lead_assignment_attempts_round_number_check
  check (round_number between 1 and 2);

-- The original uniqueness prevented a broker from receiving the same lead in
-- the second round. Uniqueness is now scoped by run and round while the attempt
-- sequence remains unique inside each run.
alter table public.lead_assignment_attempts
  drop constraint if exists lead_assignment_attempts_lead_id_broker_id_key;
alter table public.lead_assignment_attempts
  drop constraint if exists lead_assignment_attempts_lead_run_round_broker_key;
alter table public.lead_assignment_attempts
  add constraint lead_assignment_attempts_lead_run_round_broker_key
  unique (lead_id, run_number, round_number, broker_id);
alter table public.lead_assignment_attempts
  drop constraint if exists lead_assignment_attempts_lead_run_attempt_key;
alter table public.lead_assignment_attempts
  add constraint lead_assignment_attempts_lead_run_attempt_key
  unique (lead_id, run_number, attempt_number);

create index if not exists crm_leads_pending_availability_idx
  on public.crm_leads (assignment_available_at, assignment_deadline_at, id)
  where assignment_status = 'pending';

create index if not exists lead_assignment_attempts_run_round_idx
  on public.lead_assignment_attempts (
    lead_id,
    run_number,
    round_number,
    attempt_number
  );

-- Lead-assignment time is independent from the wider notification schedule.
-- The conveyor runs every calendar day from 09:00 (inclusive) to 18:00
-- (exclusive), always in Brasilia time.
create or replace function public.crm_is_lead_queue_hours(
  p_moment timestamptz default now()
)
returns boolean
language sql
stable
set search_path = pg_catalog, public
as $$
  select (p_moment at time zone 'America/Sao_Paulo')::time >= time '09:00'
     and (p_moment at time zone 'America/Sao_Paulo')::time < time '18:00';
$$;

create or replace function public.crm_next_lead_queue_moment(
  p_moment timestamptz default now()
)
returns timestamptz
language plpgsql
stable
set search_path = pg_catalog, public
as $$
declare
  local_moment timestamp := p_moment at time zone 'America/Sao_Paulo';
  next_local timestamp;
begin
  if local_moment::time < time '09:00' then
    next_local := local_moment::date + time '09:00';
  elsif local_moment::time >= time '18:00' then
    next_local := (local_moment::date + 1) + time '09:00';
  else
    return p_moment;
  end if;

  return next_local at time zone 'America/Sao_Paulo';
end;
$$;

create or replace function public.crm_next_calendar_day_nine(
  p_moment timestamptz default now()
)
returns timestamptz
language sql
stable
set search_path = pg_catalog, public
as $$
  select (
    ((p_moment at time zone 'America/Sao_Paulo')::date + 1) + time '09:00'
  ) at time zone 'America/Sao_Paulo';
$$;

create or replace function public.crm_add_lead_queue_minutes(
  p_start timestamptz,
  p_minutes integer
)
returns timestamptz
language plpgsql
stable
set search_path = pg_catalog, public
as $$
declare
  local_cursor timestamp;
  local_close timestamp;
  available_interval interval;
  remaining_interval interval;
begin
  if p_start is null then
    return null;
  end if;
  if p_minutes is null or p_minutes < 0 or p_minutes > 1440 then
    raise exception 'Informe uma duracao entre 0 e 1440 minutos.';
  end if;

  remaining_interval := make_interval(mins => p_minutes);

  local_cursor := public.crm_next_lead_queue_moment(p_start)
    at time zone 'America/Sao_Paulo';

  while remaining_interval > interval '0' loop
    local_close := local_cursor::date + time '18:00';
    available_interval := greatest(
      local_close - local_cursor,
      interval '0'
    );

    if remaining_interval <= available_interval then
      local_cursor := local_cursor + remaining_interval;
      remaining_interval := interval '0';
    else
      remaining_interval := remaining_interval - available_interval;
      local_cursor := (local_cursor::date + 1) + time '09:00';
    end if;
  end loop;

  return local_cursor at time zone 'America/Sao_Paulo';
end;
$$;

-- Migration 88 made the generic outbox window 08:30-20:00. Lead assignment
-- has the narrower, explicit override above; record that exception in the
-- administrative policy catalog so its documentation does not go stale.
update public.crm_notification_delivery_policies as policy
set rationale = case policy.kind
      when 'lead_assignment'
        then 'Liberada pela esteira somente entre 09:00 e 18:00 de Brasilia.'
      when 'lead_assignment_expired'
        then 'Gerada pelo processador da esteira somente entre 09:00 e 18:00 de Brasilia.'
      when 'lead_unanswered'
        then 'Gerada apos duas rodadas, somente entre 09:00 e 18:00 de Brasilia.'
    end,
    updated_at = now()
where policy.kind in (
  'lead_assignment',
  'lead_assignment_expired',
  'lead_unanswered'
);

comment on table public.crm_notification_delivery_policies is
  'Janela geral 08:30-20:00 America/Sao_Paulo; eventos da esteira de leads usam o override 09:00-18:00.';

create or replace function public.normalize_lead_assignment_attempt_schedule()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  duration_minutes integer := case when new.attempt_number = 1 then 20 else 10 end;
begin
  new.notified_at := public.crm_next_lead_queue_moment(
    coalesce(new.notified_at, now())
  );
  new.deadline_at := public.crm_add_lead_queue_minutes(
    new.notified_at,
    duration_minutes
  );
  return new;
end;
$$;

create or replace function public.sync_lead_assignment_deadline_from_attempt()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  update public.crm_leads as lead
  set assignment_available_at = new.notified_at,
      assignment_deadline_at = new.deadline_at,
      assignment_run_number = new.run_number
  where lead.id = new.lead_id
    and lead.assignment_status = 'pending';

  return new;
end;
$$;

drop trigger if exists normalize_lead_assignment_attempt_schedule
  on public.lead_assignment_attempts;
create trigger normalize_lead_assignment_attempt_schedule
before insert on public.lead_assignment_attempts
for each row execute function public.normalize_lead_assignment_attempt_schedule();

drop trigger if exists sync_lead_assignment_deadline_from_attempt
  on public.lead_assignment_attempts;
create trigger sync_lead_assignment_deadline_from_attempt
after insert on public.lead_assignment_attempts
for each row execute function public.sync_lead_assignment_deadline_from_attempt();

-- Pending work already in flight is moved onto the new clock as part of the
-- deployment. This prevents an old 08:30 notification or 15/4-minute deadline
-- from leaking through after the 09:00 and 20/10-minute rules become active.
with active_attempt_schedule as (
  select
    attempt.id,
    public.crm_next_lead_queue_moment(attempt.notified_at) as notified_at,
    case when attempt.attempt_number = 1 then 20 else 10 end as duration_minutes
  from public.lead_assignment_attempts as attempt
  join public.crm_leads as lead on lead.id = attempt.lead_id
  where lead.assignment_status = 'pending'
    and attempt.accepted_at is null
    and attempt.expired_at is null
)
update public.lead_assignment_attempts as attempt
set notified_at = schedule.notified_at,
    deadline_at = public.crm_add_lead_queue_minutes(
      schedule.notified_at,
      schedule.duration_minutes
    )
from active_attempt_schedule as schedule
where attempt.id = schedule.id;

with pending_schedule as (
  select
    lead.id,
    coalesce(
      active_attempt.notified_at,
      public.crm_next_lead_queue_moment(now())
    ) as available_at,
    coalesce(
      active_attempt.deadline_at,
      public.crm_add_lead_queue_minutes(
        public.crm_next_lead_queue_moment(now()),
        20
      )
    ) as deadline_at
  from public.crm_leads as lead
  left join lateral (
    select attempt.notified_at, attempt.deadline_at
    from public.lead_assignment_attempts as attempt
    where attempt.lead_id = lead.id
      and attempt.accepted_at is null
      and attempt.expired_at is null
    order by attempt.run_number desc, attempt.attempt_number desc
    limit 1
  ) as active_attempt on true
  where lead.assignment_status = 'pending'
)
update public.crm_leads as lead
set assignment_available_at = schedule.available_at,
    assignment_deadline_at = schedule.deadline_at,
    stage = 'Aguardando atendimento'
from pending_schedule as schedule
where lead.id = schedule.id;

-- Keep a still-pending delivery aligned with the migrated lead. The existing
-- notification triggers continue to apply their normal invariants as well.
update public.crm_notification_outbox as notification
set available_at = lead.assignment_available_at,
    payload = jsonb_set(
      jsonb_set(
        jsonb_set(
          coalesce(notification.payload, '{}'::jsonb),
          '{availableAt}',
          to_jsonb(lead.assignment_available_at),
          true
        ),
        '{deadlineAt}',
        to_jsonb(lead.assignment_deadline_at),
        true
      ),
      '{runNumber}',
      to_jsonb(lead.assignment_run_number),
      true
    )
from public.crm_leads as lead
where notification.kind = 'lead_assignment'
  and notification.delivered_at is null
  and notification.recipient_id = lead.owner_id
  and notification.payload ->> 'leadId' = lead.id::text
  and lead.assignment_status = 'pending';

create or replace function public.normalize_lead_assignment_notification_schedule()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  linked_lead_id uuid;
  lead_available_at timestamptz;
  lead_deadline_at timestamptz;
  lead_run_number integer;
begin
  if new.kind is distinct from 'lead_assignment' then
    return new;
  end if;

  begin
    linked_lead_id := (new.payload ->> 'leadId')::uuid;
  exception
    when invalid_text_representation then
      return new;
  end;

  select
    lead.assignment_available_at,
    lead.assignment_deadline_at,
    lead.assignment_run_number
  into lead_available_at, lead_deadline_at, lead_run_number
  from public.crm_leads as lead
  where lead.id = linked_lead_id;

  new.available_at := public.crm_next_lead_queue_moment(
    coalesce(lead_available_at, new.available_at, now())
  );

  if lead_deadline_at is not null then
    new.payload := jsonb_set(
      coalesce(new.payload, '{}'::jsonb),
      '{availableAt}',
      to_jsonb(new.available_at),
      true
    );
    new.payload := jsonb_set(
      new.payload,
      '{deadlineAt}',
      to_jsonb(lead_deadline_at),
      true
    );
    new.payload := jsonb_set(
      new.payload,
      '{runNumber}',
      to_jsonb(lead_run_number),
      true
    );
  end if;

  return new;
end;
$$;

drop trigger if exists zz_normalize_lead_assignment_notification_schedule
  on public.crm_notification_outbox;
create trigger zz_normalize_lead_assignment_notification_schedule
before insert or update of kind, available_at, payload
on public.crm_notification_outbox
for each row execute function public.normalize_lead_assignment_notification_schedule();

create or replace function public.start_lead_assignment()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  defer_until_tomorrow boolean := false;
  target_available_at timestamptz;
  target_deadline_at timestamptz;
begin
  select settings.defer_new_leads_to_next_day_nine
  into defer_until_tomorrow
  from public.crm_operational_settings as settings
  where settings.singleton;

  target_available_at := case
    when coalesce(defer_until_tomorrow, false)
      then public.crm_next_calendar_day_nine(now())
    else public.crm_next_lead_queue_moment(now())
  end;
  target_deadline_at := public.crm_add_lead_queue_minutes(
    target_available_at,
    20
  );

  update public.crm_leads as lead
  set assignment_status = 'pending',
      assignment_available_at = target_available_at,
      assignment_deadline_at = target_deadline_at,
      assignment_run_number = 1,
      assignment_reminder_sent_at = null,
      stage = 'Aguardando atendimento'
  where lead.id = new.id;

  insert into public.lead_assignment_attempts (
    lead_id,
    broker_id,
    attempt_number,
    run_number,
    round_number,
    notified_at,
    deadline_at
  ) values (
    new.id,
    new.owner_id,
    1,
    1,
    1,
    target_available_at,
    target_deadline_at
  );

  insert into public.crm_notification_outbox (
    recipient_id,
    kind,
    title,
    body,
    url,
    payload,
    available_at
  ) values (
    new.owner_id,
    'lead_assignment',
    'Novo lead aguardando atendimento',
    'Voce tem 20 minutos uteis para iniciar o atendimento de ' || new.name || '.',
    '/leads',
    jsonb_build_object(
      'leadId', new.id,
      'phone', new.phone,
      'name', new.name,
      'attemptNumber', 1,
      'runNumber', 1,
      'roundNumber', 1,
      'availableAt', target_available_at,
      'deadlineAt', target_deadline_at,
      'deferredToNextDayNine', coalesce(defer_until_tomorrow, false)
    ),
    target_available_at
  );

  return new;
end;
$$;

create or replace function public.accept_lead_assignment(p_lead_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  current_profile record;
  accepted_run_number integer;
begin
  update public.crm_leads as lead
  set assignment_status = 'accepted',
      assignment_available_at = null,
      assignment_deadline_at = now() + interval '24 hours',
      assignment_reminder_sent_at = null,
      stage = 'Em atendimento'
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
        )
    )
  returning lead.assignment_run_number into accepted_run_number;

  if not found then
    raise exception 'Este lead nao esta disponivel para aceite neste horario ou seu prazo/acesso foi alterado.';
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
    'Em atendimento',
    'Atendimento iniciado em '
      || to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'),
    auth.uid(),
    coalesce(nullif(current_profile.full_name, ''), current_profile.email)
  );
end;
$$;

-- Brokers must cross the acceptance RPC so the release time, deadline and
-- operating window cannot be bypassed with a direct table update. Trigger
-- order is intentional: the zz prefix lets the older attendance trigger apply
-- its derived changes first, and this guard then rejects the whole statement.
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

  -- Returning an already accepted lead from Standby/another progress stage to
  -- attendance is also legitimate. The older enforcement trigger, which runs
  -- first, derives this exact new 24-hour deadline.
  allowed_attendance_deadline_start :=
    old.assignment_status = 'accepted'
    and old.stage <> 'Em atendimento'
    and new.stage = 'Em atendimento'
    and new.assignment_status = 'accepted'
    and new.assignment_deadline_at = now() + interval '24 hours';

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

revoke all on function public.protect_lead_assignment_system_fields()
  from public, anon, authenticated;

drop trigger if exists zz_crm_leads_protect_assignment_system_fields
  on public.crm_leads;
create trigger zz_crm_leads_protect_assignment_system_fields
before update of
  stage,
  assignment_status,
  assignment_available_at,
  assignment_deadline_at,
  assignment_run_number,
  assignment_reminder_sent_at
on public.crm_leads
for each row execute function public.protect_lead_assignment_system_fields();

-- Replace the public processor directly; the obsolete one-round function
-- left by migration 120 is removed after the replacement is installed.
create or replace function public.process_expired_lead_assignments()
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  lead_row record;
  next_broker_id uuid;
  next_broker_name text;
  next_broker_email text;
  next_position integer;
  current_run integer;
  current_round smallint;
  attempt_count integer;
  next_attempt_number integer;
  next_duration_minutes integer;
  next_available_at timestamptz;
  next_deadline_at timestamptz;
  timeout_message text;
  source_label text;
begin
  if not public.crm_is_lead_queue_hours(now()) then
    return;
  end if;

  for lead_row in
    select lead.*
    from public.crm_leads as lead
    where lead.assignment_deadline_at <= now()
      and (
        lead.assignment_status = 'pending'
        or (
          lead.assignment_status = 'accepted'
          and lead.stage = 'Em atendimento'
        )
      )
    order by lead.assignment_deadline_at, lead.id
    for update skip locked
  loop
    current_run := greatest(coalesce(lead_row.assignment_run_number, 1), 1);

    update public.lead_assignment_attempts as attempt
    set expired_at = now()
    where attempt.lead_id = lead_row.id
      and attempt.run_number = current_run
      and attempt.expired_at is null
      and (
        (
          lead_row.assignment_status = 'pending'
          and attempt.accepted_at is null
        )
        or (
          lead_row.assignment_status = 'accepted'
          and attempt.accepted_at is not null
        )
      );

    if lead_row.assignment_status = 'pending' then
      insert into public.crm_notification_outbox (
        recipient_id,
        kind,
        title,
        body,
        url,
        payload
      ) values (
        lead_row.owner_id,
        'lead_assignment_expired',
        'Prazo para aceitar o lead expirou',
        'O prazo para assumir o atendimento de ' || lead_row.name || ' terminou.',
        '/leads',
        jsonb_build_object(
          'leadId', lead_row.id,
          'name', lead_row.name,
          'runNumber', current_run,
          'sourcePortal', lead_row.source_portal,
          'externalCode', lead_row.source_listing_id
        )
      );
    end if;

    insert into public.crm_lead_activities (
      lead_id,
      stage,
      note,
      author_id,
      author_name
    ) values (
      lead_row.id,
      case
        when lead_row.assignment_status = 'pending' then 'Prazo de aceite expirado'
        else 'Prazo de atendimento expirado'
      end,
      case
        when lead_row.assignment_status = 'pending'
          then 'O prazo de aceite do corretor responsavel terminou automaticamente.'
        else 'O prazo de 24 horas em atendimento terminou automaticamente.'
      end,
      null,
      'Sistema'
    );

    select
      count(*)::integer,
      greatest(coalesce(max(attempt.round_number), 1), 1)::smallint
    into attempt_count, current_round
    from public.lead_assignment_attempts as attempt
    where attempt.lead_id = lead_row.id
      and attempt.run_number = current_run;

    perform pg_advisory_xact_lock(
      hashtext('lead-distribution:' || lead_row.lead_type)
    );

    next_broker_id := null;
    next_broker_name := null;
    next_broker_email := null;

    select queue.broker_id, profile.full_name, profile.email
    into next_broker_id, next_broker_name, next_broker_email
    from public.lead_distribution_queue as queue
    join public.profiles as profile
      on profile.id = queue.broker_id
    where queue.lead_type = lead_row.lead_type
      and profile.role = 'broker'
      and not coalesce(profile.lead_distribution_blocked, false)
      and not exists (
        select 1
        from public.lead_assignment_attempts as previous_attempt
        where previous_attempt.lead_id = lead_row.id
          and previous_attempt.run_number = current_run
          and previous_attempt.round_number = current_round
          and previous_attempt.broker_id = queue.broker_id
      )
      and (
        lead_row.property_catalog_id is null
        or exists (
            select 1
            from public.crm_property_broker_access as access
            where access.property_id = lead_row.property_catalog_id
              and access.broker_id = queue.broker_id
          )
      )
    order by queue.position
    limit 1
    for update of queue skip locked;

    if next_broker_id is null and current_round = 1 then
      current_round := 2;

      select queue.broker_id, profile.full_name, profile.email
      into next_broker_id, next_broker_name, next_broker_email
      from public.lead_distribution_queue as queue
      join public.profiles as profile
        on profile.id = queue.broker_id
      where queue.lead_type = lead_row.lead_type
        and profile.role = 'broker'
        and not coalesce(profile.lead_distribution_blocked, false)
        and not exists (
          select 1
          from public.lead_assignment_attempts as previous_attempt
          where previous_attempt.lead_id = lead_row.id
            and previous_attempt.run_number = current_run
            and previous_attempt.round_number = 2
            and previous_attempt.broker_id = queue.broker_id
        )
        and (
          lead_row.property_catalog_id is null
          or exists (
              select 1
              from public.crm_property_broker_access as access
              where access.property_id = lead_row.property_catalog_id
                and access.broker_id = queue.broker_id
            )
        )
      order by queue.position
      limit 1
      for update of queue skip locked;
    end if;

    if next_broker_id is null then
      update public.crm_leads as lead
      set assignment_status = 'exhausted',
          assignment_available_at = null,
          assignment_deadline_at = null,
          assignment_reminder_sent_at = null,
          stage = 'Aguardando atendimento',
          updated_at = now()
      where lead.id = lead_row.id;

      source_label := case lead_row.source_portal
        when 'dfimoveis' then 'DF Imoveis'
        when 'wimoveis' then 'W Imoveis'
        else coalesce(lead_row.channel, 'Nao informada')
      end;

      timeout_message := case
        when lead_row.source_portal is not null then
          'Origem: ' || source_label
          || '. Imovel: ' || coalesce(lead_row.property_interest, 'nao informado')
          || '. Codigo: ' || coalesce(lead_row.source_listing_id, 'nao informado')
          || '. Finalidade: ' || coalesce(lead_row.lead_type, 'nao informada')
          || '. Cliente: ' || lead_row.name
          || '. Telefone: ' || coalesce(lead_row.phone, 'nao informado')
          || '. Duas rodadas foram concluidas e nenhum corretor elegivel assumiu o lead.'
        when lead_row.assignment_status = 'accepted' then
          lead_row.name
          || ' concluiu duas rodadas da esteira sem continuidade no atendimento.'
        else
          lead_row.name
          || ' nao foi assumido por nenhum corretor elegivel apos duas rodadas.'
      end;

      insert into public.crm_notification_outbox (
        recipient_id,
        kind,
        title,
        body,
        url,
        payload
      )
      select
        profile.id,
        'lead_unanswered',
        case
          when lead_row.source_portal is not null then 'Lead de portal sem atendimento'
          else 'Esteira de atendimento esgotada apos duas rodadas'
        end,
        timeout_message,
        '/leads',
        jsonb_build_object(
          'leadId', lead_row.id,
          'phone', lead_row.phone,
          'name', lead_row.name,
          'sourcePortal', lead_row.source_portal,
          'externalCode', lead_row.source_listing_id,
          'propertyId', lead_row.property_catalog_id,
          'runNumber', current_run,
          'roundsCompleted', 2,
          'attemptCount', attempt_count
        )
      from public.profiles as profile
      join auth.users as auth_user on auth_user.id = profile.id
      where profile.role = 'admin'
        and (
          profile.id = '37094db7-2457-48f2-8573-40c887e547e5'::uuid
          or (
            profile.id <> '37094db7-2457-48f2-8573-40c887e547e5'::uuid
            and lower(trim(auth_user.email)) = 'unassigned-institutional@example.invalid'
          )
        );

      insert into public.crm_lead_activities (
        lead_id,
        stage,
        note,
        author_id,
        author_name
      ) values (
        lead_row.id,
        'Esteira esgotada',
        'Duas rodadas da execucao ' || current_run
          || ' foram concluidas sem aceite. Allyson e acessocrm foram avisados.',
        null,
        'Sistema'
      );
    else
      select coalesce(max(queue.position), 0) + 1
      into next_position
      from public.lead_distribution_queue as queue
      where queue.lead_type = lead_row.lead_type;

      update public.lead_distribution_queue as queue
      set position = next_position,
          updated_at = now()
      where queue.lead_type = lead_row.lead_type
        and queue.broker_id = next_broker_id;

      next_attempt_number := attempt_count + 1;
      next_duration_minutes := case
        when next_attempt_number = 1 then 20
        else 10
      end;
      next_available_at := public.crm_next_lead_queue_moment(now());
      next_deadline_at := public.crm_add_lead_queue_minutes(
        next_available_at,
        next_duration_minutes
      );

      update public.crm_leads as lead
      set owner_id = next_broker_id,
          assignment_status = 'pending',
          assignment_available_at = next_available_at,
          assignment_deadline_at = next_deadline_at,
          assignment_run_number = current_run,
          assignment_reminder_sent_at = null,
          stage = 'Aguardando atendimento',
          updated_at = now()
      where lead.id = lead_row.id;

      insert into public.lead_assignment_attempts (
        lead_id,
        broker_id,
        attempt_number,
        run_number,
        round_number,
        notified_at,
        deadline_at
      ) values (
        lead_row.id,
        next_broker_id,
        next_attempt_number,
        current_run,
        current_round,
        next_available_at,
        next_deadline_at
      );

      insert into public.crm_notification_outbox (
        recipient_id,
        kind,
        title,
        body,
        url,
        payload,
        available_at
      ) values (
        next_broker_id,
        'lead_assignment',
        case
          when current_round = 2 then 'Lead na segunda rodada da esteira'
          else 'Lead transferido para sua carteira'
        end,
        'Voce tem ' || next_duration_minutes
          || ' minutos uteis para iniciar o atendimento de ' || lead_row.name || '.',
        '/leads',
        jsonb_build_object(
          'leadId', lead_row.id,
          'phone', lead_row.phone,
          'name', lead_row.name,
          'sourcePortal', lead_row.source_portal,
          'externalCode', lead_row.source_listing_id,
          'attemptNumber', next_attempt_number,
          'runNumber', current_run,
          'roundNumber', current_round,
          'availableAt', next_available_at,
          'deadlineAt', next_deadline_at
        ),
        next_available_at
      );

      insert into public.crm_lead_activities (
        lead_id,
        stage,
        note,
        author_id,
        author_name
      ) values (
        lead_row.id,
        'Lead redistribuido',
        'Execucao ' || current_run || ', rodada ' || current_round
          || ': tentativa ' || next_attempt_number || ' enviada ao corretor '
          || coalesce(nullif(next_broker_name, ''), next_broker_email)
          || ' com prazo de ' || next_duration_minutes || ' minutos uteis.',
        null,
        'Sistema'
      );
    end if;
  end loop;
end;
$$;

drop function if exists public.process_expired_lead_assignments_before_1830();

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

  select lead.*
  into lead_record
  from public.crm_leads as lead
  where lead.id = p_lead_id
  for update;

  if not found then
    raise exception 'Lead nao encontrado.';
  end if;
  if lead_record.assignment_status is distinct from 'exhausted' then
    raise exception 'Este lead nao esta com a esteira esgotada.';
  end if;

  perform pg_advisory_xact_lock(
    hashtext('lead-distribution:' || lead_record.lead_type)
  );

  select queue.broker_id, profile.full_name, profile.email
  into next_broker_id, next_broker_name, next_broker_email
  from public.lead_distribution_queue as queue
  join public.profiles as profile
    on profile.id = queue.broker_id
  where queue.lead_type = lead_record.lead_type
    and profile.role = 'broker'
    and not coalesce(profile.lead_distribution_blocked, false)
    and (
      lead_record.property_catalog_id is null
      or exists (
          select 1
          from public.crm_property_broker_access as access
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

  select coalesce(max(queue.position), 0) + 1
  into next_position
  from public.lead_distribution_queue as queue
  where queue.lead_type = lead_record.lead_type;

  update public.lead_distribution_queue as queue
  set position = next_position,
      updated_at = now()
  where queue.lead_type = lead_record.lead_type
    and queue.broker_id = next_broker_id;

  next_run_number := greatest(coalesce(lead_record.assignment_run_number, 1), 1) + 1;
  available_at := public.crm_next_lead_queue_moment(now());
  deadline_at := public.crm_add_lead_queue_minutes(available_at, 20);

  update public.crm_leads as lead
  set owner_id = next_broker_id,
      assignment_status = 'pending',
      assignment_available_at = available_at,
      assignment_deadline_at = deadline_at,
      assignment_run_number = next_run_number,
      assignment_reminder_sent_at = null,
      stage = 'Aguardando atendimento',
      updated_at = now()
  where lead.id = lead_record.id;

  insert into public.lead_assignment_attempts (
    lead_id,
    broker_id,
    attempt_number,
    run_number,
    round_number,
    notified_at,
    deadline_at
  ) values (
    lead_record.id,
    next_broker_id,
    1,
    next_run_number,
    1,
    available_at,
    deadline_at
  );

  insert into public.crm_notification_outbox (
    recipient_id,
    kind,
    title,
    body,
    url,
    payload,
    available_at
  ) values (
    next_broker_id,
    'lead_assignment',
    'Lead reiniciado na esteira',
    'Voce tem 20 minutos uteis para iniciar o atendimento de '
      || lead_record.name || '.',
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

  insert into public.crm_lead_activities (
    lead_id,
    stage,
    note,
    author_id,
    author_name
  ) values (
    lead_record.id,
    'Esteira reiniciada',
    'Allyson iniciou a execucao ' || next_run_number
      || ' da esteira, com ate duas rodadas e primeiro prazo de 20 minutos uteis.',
    auth.uid(),
    'crmallyson'
  );

  return coalesce(nullif(next_broker_name, ''), next_broker_email);
end;
$$;

-- Admins retain full visibility. A broker sees only owned leads and cannot see
-- a pending batch before its captured release time.
drop policy if exists "Admins read every lead; brokers read their own"
  on public.crm_leads;
drop policy if exists "Admins read all leads; brokers read only assigned leads"
  on public.crm_leads;
drop policy if exists "Admins read all leads; brokers read available assigned leads"
  on public.crm_leads;
create policy "Admins read all leads; brokers read available assigned leads"
  on public.crm_leads
  for select to authenticated
  using (
    public.is_admin()
    or (
      owner_id = auth.uid()
      and (
        assignment_status <> 'pending'
        or assignment_available_at <= now()
      )
    )
  );

drop policy if exists "Users read attempts for their leads"
  on public.lead_assignment_attempts;
drop policy if exists "Users read attempts for available assigned leads"
  on public.lead_assignment_attempts;
create policy "Users read attempts for available assigned leads"
  on public.lead_assignment_attempts
  for select to authenticated
  using (
    public.is_admin()
    or (
      lead_assignment_attempts.broker_id = auth.uid()
      and exists (
        select 1
        from public.crm_leads as lead
        where lead.id = lead_assignment_attempts.lead_id
          and lead.owner_id = auth.uid()
          and (
            lead.assignment_status <> 'pending'
            or lead.assignment_available_at <= now()
          )
      )
    )
  );

revoke all on function public.crm_is_lead_queue_hours(timestamptz)
  from public, anon;
revoke all on function public.crm_next_lead_queue_moment(timestamptz)
  from public, anon;
revoke all on function public.crm_next_calendar_day_nine(timestamptz)
  from public, anon;
revoke all on function public.crm_add_lead_queue_minutes(timestamptz, integer)
  from public, anon, authenticated;
grant execute on function public.crm_is_lead_queue_hours(timestamptz)
  to authenticated, service_role;
grant execute on function public.crm_next_lead_queue_moment(timestamptz)
  to authenticated, service_role;
grant execute on function public.crm_next_calendar_day_nine(timestamptz)
  to authenticated, service_role;
grant execute on function public.crm_add_lead_queue_minutes(timestamptz, integer)
  to service_role;

revoke all on function public.normalize_lead_assignment_attempt_schedule()
  from public, anon, authenticated;
revoke all on function public.sync_lead_assignment_deadline_from_attempt()
  from public, anon, authenticated;
revoke all on function public.normalize_lead_assignment_notification_schedule()
  from public, anon, authenticated;
revoke all on function public.start_lead_assignment()
  from public, anon, authenticated;
revoke all on function public.accept_lead_assignment(uuid)
  from public, anon;
revoke all on function public.process_expired_lead_assignments()
  from public, anon, authenticated;
revoke all on function public.restart_exhausted_lead_queue(uuid)
  from public, anon;
grant execute on function public.accept_lead_assignment(uuid) to authenticated;
grant execute on function public.process_expired_lead_assignments() to service_role;
grant execute on function public.restart_exhausted_lead_queue(uuid) to authenticated;

comment on table public.crm_operational_settings is
  'Singleton controlado por Allyson para notificacoes documentais e liberacao dos novos leads.';
comment on column public.crm_leads.assignment_available_at is
  'Momento capturado em que o lead pendente se torna visivel e pode ser aceito pelo corretor.';
comment on column public.crm_leads.assignment_run_number is
  'Execucao atual da esteira; reinicios manuais incrementam este numero sem apagar historico.';
comment on column public.lead_assignment_attempts.run_number is
  'Execucao da esteira a que a tentativa pertence.';
comment on column public.lead_assignment_attempts.round_number is
  'Primeira ou segunda passagem pelo conjunto de corretores elegiveis.';

commit;

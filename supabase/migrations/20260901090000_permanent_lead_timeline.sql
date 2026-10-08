begin;

create table if not exists public.crm_lead_timeline_events (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null,
  lead_name text,
  event_type text not null,
  stage text not null,
  note text,
  actor_id uuid,
  actor_name text not null default 'Sistema',
  broker_id uuid,
  broker_name text,
  occurred_at timestamptz not null default now(),
  scheduled_for timestamptz,
  source_table text not null,
  source_id text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint crm_lead_timeline_source_event_key unique (source_table, source_id, event_type)
);

create index if not exists crm_lead_timeline_lead_occurred_idx
  on public.crm_lead_timeline_events (lead_id, occurred_at desc, id);

alter table public.crm_lead_timeline_events enable row level security;

drop policy if exists "Team reads permanent timeline for accessible leads"
  on public.crm_lead_timeline_events;
create policy "Team reads permanent timeline for accessible leads"
  on public.crm_lead_timeline_events
  for select
  to authenticated
  using (
    public.is_admin()
    or exists (
      select 1
      from public.crm_leads as lead
      where lead.id = crm_lead_timeline_events.lead_id
        and lead.owner_id = auth.uid()
    )
  );

revoke all on public.crm_lead_timeline_events from public, anon, authenticated;
grant select on public.crm_lead_timeline_events to authenticated;

create or replace function public.crm_append_lead_timeline_event(
  p_lead_id uuid,
  p_lead_name text,
  p_event_type text,
  p_stage text,
  p_note text,
  p_actor_id uuid,
  p_actor_name text,
  p_broker_id uuid,
  p_broker_name text,
  p_occurred_at timestamptz,
  p_scheduled_for timestamptz,
  p_source_table text,
  p_source_id text,
  p_metadata jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if p_lead_id is null or nullif(trim(p_event_type), '') is null then
    return;
  end if;

  insert into public.crm_lead_timeline_events (
    lead_id,
    lead_name,
    event_type,
    stage,
    note,
    actor_id,
    actor_name,
    broker_id,
    broker_name,
    occurred_at,
    scheduled_for,
    source_table,
    source_id,
    metadata
  ) values (
    p_lead_id,
    nullif(trim(p_lead_name), ''),
    p_event_type,
    coalesce(nullif(trim(p_stage), ''), 'Evento do lead'),
    nullif(trim(p_note), ''),
    p_actor_id,
    coalesce(nullif(trim(p_actor_name), ''), 'Sistema'),
    p_broker_id,
    nullif(trim(p_broker_name), ''),
    coalesce(p_occurred_at, now()),
    p_scheduled_for,
    p_source_table,
    p_source_id,
    coalesce(p_metadata, '{}'::jsonb)
  )
  on conflict (source_table, source_id, event_type) do nothing;
end;
$$;

revoke all on function public.crm_append_lead_timeline_event(
  uuid, text, text, text, text, uuid, text, uuid, text,
  timestamptz, timestamptz, text, text, jsonb
) from public, anon, authenticated;

-- Recupera a criação dos leads que ainda existem.
insert into public.crm_lead_timeline_events (
  lead_id, lead_name, event_type, stage, note, actor_id, actor_name,
  broker_id, broker_name, occurred_at, source_table, source_id, metadata
)
select
  lead.id,
  lead.name,
  'lead_created',
  'Lead criado',
  'Lead cadastrado no CRM.',
  lead.created_by,
  coalesce(nullif(creator.full_name, ''), creator.email, 'Sistema'),
  lead.owner_id,
  coalesce(nullif(owner_profile.full_name, ''), owner_profile.email),
  lead.created_at,
  'crm_leads',
  lead.id::text || ':created',
  jsonb_build_object('snapshot', to_jsonb(lead))
from public.crm_leads as lead
left join public.profiles as creator on creator.id = lead.created_by
left join public.profiles as owner_profile on owner_profile.id = lead.owner_id
on conflict (source_table, source_id, event_type) do nothing;

-- Recupera todas as atividades que a tela antiga mostrava ou ocultava.
insert into public.crm_lead_timeline_events (
  lead_id, lead_name, event_type, stage, note, actor_id, actor_name,
  occurred_at, scheduled_for, source_table, source_id, metadata
)
select
  activity.lead_id,
  lead.name,
  'activity',
  activity.stage,
  activity.note,
  activity.author_id,
  coalesce(nullif(activity.author_name, ''), 'Sistema'),
  activity.created_at,
  activity.scheduled_for,
  'crm_lead_activities',
  activity.id::text,
  jsonb_build_object('activity_id', activity.id)
from public.crm_lead_activities as activity
left join public.crm_leads as lead on lead.id = activity.lead_id
on conflict (source_table, source_id, event_type) do nothing;

-- Recupera cada corretor para quem o lead foi enviado na fila.
insert into public.crm_lead_timeline_events (
  lead_id, lead_name, event_type, stage, note, actor_name,
  broker_id, broker_name, occurred_at, scheduled_for,
  source_table, source_id, metadata
)
select
  attempt.lead_id,
  lead.name,
  'assignment_offered',
  'Enviado para aceite',
  'Lead enviado para ' || coalesce(nullif(profile.full_name, ''), profile.email, 'corretor removido')
    || ' · execução ' || coalesce(attempt.run_number, 1)
    || ' · volta ' || coalesce(attempt.round_number, 1)
    || ' · tentativa ' || attempt.attempt_number || '.',
  'Sistema',
  attempt.broker_id,
  coalesce(nullif(profile.full_name, ''), profile.email, 'Corretor removido'),
  attempt.notified_at,
  attempt.deadline_at,
  'lead_assignment_attempts',
  attempt.id::text,
  to_jsonb(attempt)
from public.lead_assignment_attempts as attempt
left join public.crm_leads as lead on lead.id = attempt.lead_id
left join public.profiles as profile on profile.id = attempt.broker_id
on conflict (source_table, source_id, event_type) do nothing;

insert into public.crm_lead_timeline_events (
  lead_id, lead_name, event_type, stage, note, actor_name,
  broker_id, broker_name, occurred_at, source_table, source_id, metadata
)
select
  attempt.lead_id,
  lead.name,
  'assignment_accepted',
  'Lead aceito',
  coalesce(nullif(profile.full_name, ''), profile.email, 'Corretor removido') || ' aceitou o lead.',
  'Sistema',
  attempt.broker_id,
  coalesce(nullif(profile.full_name, ''), profile.email, 'Corretor removido'),
  attempt.accepted_at,
  'lead_assignment_attempts',
  attempt.id::text,
  to_jsonb(attempt)
from public.lead_assignment_attempts as attempt
left join public.crm_leads as lead on lead.id = attempt.lead_id
left join public.profiles as profile on profile.id = attempt.broker_id
where attempt.accepted_at is not null
on conflict (source_table, source_id, event_type) do nothing;

insert into public.crm_lead_timeline_events (
  lead_id, lead_name, event_type, stage, note, actor_name,
  broker_id, broker_name, occurred_at, source_table, source_id, metadata
)
select
  attempt.lead_id,
  lead.name,
  'assignment_expired',
  'Prazo de aceite expirado',
  coalesce(nullif(profile.full_name, ''), profile.email, 'Corretor removido')
    || ' não aceitou dentro do prazo.',
  'Sistema',
  attempt.broker_id,
  coalesce(nullif(profile.full_name, ''), profile.email, 'Corretor removido'),
  attempt.expired_at,
  'lead_assignment_attempts',
  attempt.id::text,
  to_jsonb(attempt)
from public.lead_assignment_attempts as attempt
left join public.crm_leads as lead on lead.id = attempt.lead_id
left join public.profiles as profile on profile.id = attempt.broker_id
where attempt.expired_at is not null
on conflict (source_table, source_id, event_type) do nothing;

-- Recupera notificações relacionadas ao lead, inclusive entrega e destinatário.
insert into public.crm_lead_timeline_events (
  lead_id, lead_name, event_type, stage, note, actor_name,
  broker_id, broker_name, occurred_at, source_table, source_id, metadata
)
select
  (notification.payload->>'leadId')::uuid,
  coalesce(lead.name, notification.payload->>'name'),
  'notification_created',
  'Notificação · ' || notification.title,
  notification.body
    || ' · Destinatário: ' || coalesce(nullif(profile.full_name, ''), profile.email, 'Usuário removido')
    || case
      when notification.delivered_at is not null then ' · Entregue.'
      when notification.delivery_status is not null then ' · Status: ' || notification.delivery_status || '.'
      else ''
    end,
  'Sistema',
  notification.recipient_id,
  coalesce(nullif(profile.full_name, ''), profile.email, 'Usuário removido'),
  notification.created_at,
  'crm_notification_outbox',
  notification.id::text,
  to_jsonb(notification)
from public.crm_notification_outbox as notification
left join public.crm_leads as lead on lead.id = (notification.payload->>'leadId')::uuid
left join public.profiles as profile on profile.id = notification.recipient_id
where notification.payload ? 'leadId'
  and coalesce(notification.payload->>'leadId', '') ~* '^[0-9a-f-]{36}$'
on conflict (source_table, source_id, event_type) do nothing;

-- Recupera mudanças relevantes e exclusões registradas na auditoria permanente.
insert into public.crm_lead_timeline_events (
  lead_id, lead_name, event_type, stage, note, actor_id, actor_name,
  broker_id, broker_name, occurred_at, source_table, source_id, metadata
)
select
  history.entity_id::uuid,
  coalesce(history.after_data->>'name', history.before_data->>'name', history.entity_label),
  'audit_' || history.operation,
  case
    when history.operation = 'delete' then 'Lead excluído'
    when history.changes ? 'owner_id' then 'Corretor responsável alterado'
    when history.changes ? 'stage' then 'Etapa alterada'
    when history.changes ? 'assignment_status' then 'Status da distribuição alterado'
    when history.changes ? 'property_interest' then 'Imóvel de interesse alterado'
    else 'Lead atualizado'
  end,
  concat_ws(
    ' · ',
    case when history.operation = 'delete' then 'O lead foi excluído do cadastro, mas este histórico foi preservado.' end,
    case when history.changes ? 'stage' then
      'Etapa: ' || coalesce(history.changes->'stage'->>'before', 'não informada')
        || ' → ' || coalesce(history.changes->'stage'->>'after', 'não informada') end,
    case when history.changes ? 'owner_id' then
      'Novo corretor: ' || coalesce(nullif(new_owner.full_name, ''), new_owner.email, 'não identificado') end,
    case when history.changes ? 'assignment_status' then
      'Distribuição: ' || coalesce(history.changes->'assignment_status'->>'before', 'não informada')
        || ' → ' || coalesce(history.changes->'assignment_status'->>'after', 'não informada') end,
    case when history.changes ? 'property_interest' then
      'Imóvel: ' || coalesce(history.changes->'property_interest'->>'before', 'não informado')
        || ' → ' || coalesce(history.changes->'property_interest'->>'after', 'não informado') end
  ),
  history.actor_id,
  coalesce(nullif(history.actor_name, ''), history.actor_email, 'Sistema'),
  nullif(history.after_data->>'owner_id', '')::uuid,
  coalesce(nullif(new_owner.full_name, ''), new_owner.email),
  history.occurred_at,
  'crm_user_action_history',
  history.id::text,
  jsonb_build_object(
    'operation', history.operation,
    'before', history.before_data,
    'after', history.after_data,
    'changes', history.changes
  )
from public.crm_user_action_history as history
left join public.profiles as new_owner
  on new_owner.id = nullif(history.after_data->>'owner_id', '')::uuid
where history.source_table = 'crm_leads'
  and history.entity_id ~* '^[0-9a-f-]{36}$'
  and (
    history.operation in ('insert', 'delete')
    or history.changes ?| array['owner_id', 'stage', 'assignment_status', 'property_interest']
  )
on conflict (source_table, source_id, event_type) do nothing;

create or replace function public.crm_capture_lead_row_timeline()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  actor_profile record;
  old_owner_name text;
  new_owner_name text;
  event_stage text;
  event_note text;
  event_id text := gen_random_uuid()::text;
begin
  select full_name, email into actor_profile
  from public.profiles where id = auth.uid();

  if tg_op = 'INSERT' then
    select coalesce(nullif(full_name, ''), email) into new_owner_name
    from public.profiles where id = new.owner_id;
    perform public.crm_append_lead_timeline_event(
      new.id, new.name, 'lead_created', 'Lead criado', 'Lead cadastrado no CRM.',
      auth.uid(), coalesce(nullif(actor_profile.full_name, ''), actor_profile.email, 'Sistema'),
      new.owner_id, new_owner_name, new.created_at, null,
      'crm_leads', new.id::text || ':created', jsonb_build_object('after', to_jsonb(new))
    );
    return new;
  end if;

  if tg_op = 'DELETE' then
    perform public.crm_append_lead_timeline_event(
      old.id, old.name, 'lead_deleted', 'Lead excluído',
      'O lead foi excluído do cadastro, mas a linha do tempo foi preservada.',
      auth.uid(), coalesce(nullif(actor_profile.full_name, ''), actor_profile.email, 'Sistema'),
      old.owner_id, null, now(), null,
      'crm_leads', event_id, jsonb_build_object('before', to_jsonb(old))
    );
    return old;
  end if;

  if (to_jsonb(old) - 'updated_at') is not distinct from (to_jsonb(new) - 'updated_at') then
    return new;
  end if;

  select coalesce(nullif(full_name, ''), email) into old_owner_name
  from public.profiles where id = old.owner_id;
  select coalesce(nullif(full_name, ''), email) into new_owner_name
  from public.profiles where id = new.owner_id;

  event_stage := case
    when old.owner_id is distinct from new.owner_id then 'Corretor responsável alterado'
    when old.stage is distinct from new.stage then 'Etapa alterada'
    when old.assignment_status is distinct from new.assignment_status then 'Status da distribuição alterado'
    when old.property_interest is distinct from new.property_interest then 'Imóvel de interesse alterado'
    else 'Lead atualizado'
  end;

  event_note := concat_ws(
    ' · ',
    case when old.owner_id is distinct from new.owner_id then
      'Corretor: ' || coalesce(old_owner_name, 'não atribuído') || ' → ' || coalesce(new_owner_name, 'não atribuído') end,
    case when old.stage is distinct from new.stage then
      'Etapa: ' || coalesce(old.stage, 'não informada') || ' → ' || coalesce(new.stage, 'não informada') end,
    case when old.assignment_status is distinct from new.assignment_status then
      'Distribuição: ' || coalesce(old.assignment_status, 'não informada') || ' → ' || coalesce(new.assignment_status, 'não informada') end,
    case when old.property_interest is distinct from new.property_interest then
      'Imóvel: ' || coalesce(old.property_interest, 'não informado') || ' → ' || coalesce(new.property_interest, 'não informado') end,
    case when old.assignment_deadline_at is distinct from new.assignment_deadline_at then
      'Prazo atualizado.' end,
    case when old.post_acceptance_qualification_completed_at is distinct from new.post_acceptance_qualification_completed_at then
      'Qualificação concluída.' end,
    case when old.post_acceptance_qualification_expired_at is distinct from new.post_acceptance_qualification_expired_at then
      'Prazo de qualificação expirado.' end
  );

  perform public.crm_append_lead_timeline_event(
    new.id, new.name, 'lead_updated', event_stage,
    coalesce(nullif(event_note, ''), 'Dados do lead atualizados.'),
    auth.uid(), coalesce(nullif(actor_profile.full_name, ''), actor_profile.email, 'Sistema'),
    new.owner_id, new_owner_name, now(), new.visit_scheduled_at,
    'crm_leads', event_id,
    jsonb_build_object('before', to_jsonb(old), 'after', to_jsonb(new))
  );
  return new;
end;
$$;

drop trigger if exists crm_capture_lead_row_timeline on public.crm_leads;
create trigger crm_capture_lead_row_timeline
after insert or update or delete on public.crm_leads
for each row execute function public.crm_capture_lead_row_timeline();

create or replace function public.crm_capture_assignment_timeline()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  lead_name_value text;
  broker_name_value text;
begin
  select name into lead_name_value from public.crm_leads where id = new.lead_id;
  select coalesce(nullif(full_name, ''), email, 'Corretor removido')
    into broker_name_value from public.profiles where id = new.broker_id;

  if tg_op = 'INSERT' then
    perform public.crm_append_lead_timeline_event(
      new.lead_id, lead_name_value, 'assignment_offered', 'Enviado para aceite',
      'Lead enviado para ' || coalesce(broker_name_value, 'corretor removido')
        || ' · execução ' || coalesce(new.run_number, 1)
        || ' · volta ' || coalesce(new.round_number, 1)
        || ' · tentativa ' || new.attempt_number || '.',
      null, 'Sistema', new.broker_id, broker_name_value, new.notified_at, new.deadline_at,
      'lead_assignment_attempts', new.id::text, to_jsonb(new)
    );
  end if;

  if new.accepted_at is not null and (tg_op = 'INSERT' or old.accepted_at is null) then
    perform public.crm_append_lead_timeline_event(
      new.lead_id, lead_name_value, 'assignment_accepted', 'Lead aceito',
      coalesce(broker_name_value, 'Corretor removido') || ' aceitou o lead.',
      null, 'Sistema', new.broker_id, broker_name_value, new.accepted_at, null,
      'lead_assignment_attempts', new.id::text, to_jsonb(new)
    );
  end if;

  if new.expired_at is not null and (tg_op = 'INSERT' or old.expired_at is null) then
    perform public.crm_append_lead_timeline_event(
      new.lead_id, lead_name_value, 'assignment_expired', 'Prazo de aceite expirado',
      coalesce(broker_name_value, 'Corretor removido') || ' não aceitou dentro do prazo.',
      null, 'Sistema', new.broker_id, broker_name_value, new.expired_at, null,
      'lead_assignment_attempts', new.id::text, to_jsonb(new)
    );
  end if;
  return new;
end;
$$;

drop trigger if exists crm_capture_assignment_timeline on public.lead_assignment_attempts;
create trigger crm_capture_assignment_timeline
after insert or update on public.lead_assignment_attempts
for each row execute function public.crm_capture_assignment_timeline();

create or replace function public.crm_capture_activity_timeline()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  lead_name_value text;
begin
  if tg_op = 'DELETE' then
    select name into lead_name_value
    from public.crm_leads where id = old.lead_id;
  else
    select name into lead_name_value
    from public.crm_leads where id = new.lead_id;
  end if;

  if tg_op = 'INSERT' then
    perform public.crm_append_lead_timeline_event(
      new.lead_id, lead_name_value, 'activity', new.stage, new.note,
      new.author_id, new.author_name, null, null, new.created_at, new.scheduled_for,
      'crm_lead_activities', new.id::text,
      jsonb_build_object('activity_id', new.id)
    );
    return new;
  elsif tg_op = 'UPDATE' then
    perform public.crm_append_lead_timeline_event(
      new.lead_id, lead_name_value, 'activity_edited', 'Registro editado',
      'Antes: ' || coalesce(old.note, old.stage) || ' · Depois: ' || coalesce(new.note, new.stage),
      auth.uid(), new.author_name, null, null, now(), new.scheduled_for,
      'crm_lead_activities', new.id::text || ':' || txid_current()::text,
      jsonb_build_object('before', to_jsonb(old), 'after', to_jsonb(new))
    );
    return new;
  else
    perform public.crm_append_lead_timeline_event(
      old.lead_id, lead_name_value, 'activity_deleted', 'Registro removido',
      'O registro foi removido da ficha, mas seu conteúdo foi preservado: ' || coalesce(old.note, old.stage),
      auth.uid(), old.author_name, null, null, now(), old.scheduled_for,
      'crm_lead_activities', old.id::text || ':' || txid_current()::text,
      jsonb_build_object('before', to_jsonb(old))
    );
    return old;
  end if;
end;
$$;

drop trigger if exists crm_capture_activity_timeline on public.crm_lead_activities;
create trigger crm_capture_activity_timeline
after insert or update or delete on public.crm_lead_activities
for each row execute function public.crm_capture_activity_timeline();

create or replace function public.crm_capture_notification_timeline()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  lead_uuid uuid;
  lead_name_value text;
  recipient_name text;
begin
  if not (new.payload ? 'leadId')
    or coalesce(new.payload->>'leadId', '') !~* '^[0-9a-f-]{36}$' then
    return new;
  end if;
  lead_uuid := (new.payload->>'leadId')::uuid;
  select name into lead_name_value from public.crm_leads where id = lead_uuid;
  select coalesce(nullif(full_name, ''), email, 'Usuário removido')
    into recipient_name from public.profiles where id = new.recipient_id;

  if tg_op = 'INSERT' then
    perform public.crm_append_lead_timeline_event(
      lead_uuid, coalesce(lead_name_value, new.payload->>'name'),
      'notification_created', 'Notificação · ' || new.title,
      new.body || ' · Destinatário: ' || coalesce(recipient_name, 'Usuário removido'),
      null, 'Sistema', new.recipient_id, recipient_name, new.created_at, new.available_at,
      'crm_notification_outbox', new.id::text, to_jsonb(new)
    );
  elsif new.delivered_at is not null and old.delivered_at is null then
    perform public.crm_append_lead_timeline_event(
      lead_uuid, coalesce(lead_name_value, new.payload->>'name'),
      'notification_delivered', 'Notificação entregue',
      new.title || ' entregue para ' || coalesce(recipient_name, 'Usuário removido') || '.',
      null, 'Sistema', new.recipient_id, recipient_name, new.delivered_at, null,
      'crm_notification_outbox', new.id::text, to_jsonb(new)
    );
  end if;
  return new;
end;
$$;

drop trigger if exists crm_capture_notification_timeline on public.crm_notification_outbox;
create trigger crm_capture_notification_timeline
after insert or update on public.crm_notification_outbox
for each row execute function public.crm_capture_notification_timeline();

commit;

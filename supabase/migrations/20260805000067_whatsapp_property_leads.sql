-- Entrada oficial do WhatsApp Business, com auditoria, idempotencia e
-- distribuicao estrita pelos corretores autorizados em cada imovel.

alter table public.crm_leads
  add column if not exists property_catalog_id text
    references public.crm_property_catalog(external_id) on delete set null,
  add column if not exists source_portal text
    check (source_portal in ('wimoveis', 'dfimoveis')),
  add column if not exists source_listing_id text,
  add column if not exists source_message_id text,
  add column if not exists registration_missing_fields text[] not null default array[]::text[],
  add column if not exists registration_completed_at timestamptz;

create unique index if not exists crm_leads_source_message_id_uidx
  on public.crm_leads(source_message_id)
  where source_message_id is not null;

create index if not exists crm_leads_portal_listing_idx
  on public.crm_leads(source_portal, source_listing_id)
  where source_portal is not null;

create index if not exists crm_leads_property_catalog_id_idx
  on public.crm_leads(property_catalog_id)
  where property_catalog_id is not null;

create table if not exists public.crm_whatsapp_inbound_events (
  id uuid primary key default gen_random_uuid(),
  message_id text not null unique,
  phone_number_id text,
  sender_phone text,
  contact_name text,
  message_text text,
  message_received_at timestamptz,
  parse_status text not null,
  parse_reason text,
  portal text check (portal in ('wimoveis', 'dfimoveis')),
  external_listing_id text,
  property_id text references public.crm_property_catalog(external_id) on delete set null,
  lead_id uuid references public.crm_leads(id) on delete set null,
  status text not null default 'received' check (
    status in (
      'received',
      'integration_paused',
      'ignored',
      'ambiguous',
      'invalid_payload',
      'invalid_phone',
      'property_not_found',
      'configuration_error',
      'no_eligible_broker',
      'linked_existing',
      'lead_created',
      'failed'
    )
  ),
  status_reason text,
  error_sqlstate text,
  eligible_broker_ids uuid[] not null default array[]::uuid[],
  raw_payload jsonb not null default '{}'::jsonb,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  updated_at timestamptz not null default now()
);

alter table public.crm_whatsapp_inbound_events
  add column if not exists error_sqlstate text;

create index if not exists crm_whatsapp_inbound_events_status_received_idx
  on public.crm_whatsapp_inbound_events(status, received_at desc);

create index if not exists crm_whatsapp_inbound_events_portal_listing_idx
  on public.crm_whatsapp_inbound_events(portal, external_listing_id)
  where portal is not null and external_listing_id is not null;

alter table public.crm_whatsapp_inbound_events enable row level security;

grant select on table public.crm_whatsapp_inbound_events to authenticated;

drop policy if exists "Admins read WhatsApp inbound events"
  on public.crm_whatsapp_inbound_events;
create policy "Admins read WhatsApp inbound events"
  on public.crm_whatsapp_inbound_events
  for select
  to authenticated
  using (public.is_admin());

-- O estado dos lembretes fica fora de crm_leads para que o disparo horario nao
-- altere updated_at nem reordene artificialmente a lista de leads.
create table if not exists public.crm_lead_registration_reminders (
  lead_id uuid primary key references public.crm_leads(id) on delete cascade,
  next_reminder_at timestamptz not null,
  last_reminder_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists crm_lead_registration_reminders_due_idx
  on public.crm_lead_registration_reminders(next_reminder_at);

alter table public.crm_lead_registration_reminders enable row level security;

grant select on table public.crm_lead_registration_reminders to authenticated;

drop policy if exists "Admins and owners read registration reminders"
  on public.crm_lead_registration_reminders;
create policy "Admins and owners read registration reminders"
  on public.crm_lead_registration_reminders
  for select
  to authenticated
  using (
    public.is_admin()
    or exists (
      select 1
      from public.crm_leads as lead
      where lead.id = crm_lead_registration_reminders.lead_id
        and lead.owner_id = auth.uid()
    )
  );

insert into public.crm_portal_lead_integrations(provider, enabled)
values ('whatsapp_business', false)
on conflict (provider) do nothing;

-- O WhatsApp envia telefones brasileiros em E.164 (55 + DDD + numero),
-- enquanto o cadastro manual atual normalmente usa apenas DDD + numero.
-- Esta identidade canonica faz os dois fluxos compartilharem deduplicacao e lock.
create or replace function public.normalize_crm_phone_identity(p_phone text)
returns text
language sql
immutable
parallel safe
set search_path = public
as $$
  with normalized as (
    select nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '') as digits
  )
  select case
    when digits like '55%' and length(digits) in (12, 13) then substr(digits, 3)
    else digits
  end
  from normalized;
$$;

create index if not exists crm_leads_normalized_phone_identity_idx
  on public.crm_leads(public.normalize_crm_phone_identity(phone))
  where phone is not null;

create or replace function public.protect_whatsapp_lead_system_fields()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  trusted_backend boolean := current_user in ('postgres', 'service_role', 'supabase_admin');
begin
  if trusted_backend or public.is_admin() then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.source_portal is not null
       or new.property_catalog_id is not null
       or new.source_listing_id is not null
       or new.source_message_id is not null
       or cardinality(coalesce(new.registration_missing_fields, array[]::text[])) > 0
       or new.registration_completed_at is not null then
      raise exception 'Campos tecnicos de integracao somente podem ser definidos pelo backend ou administrador.';
    end if;
    return new;
  end if;

  if new.source_portal is distinct from old.source_portal
     or new.property_catalog_id is distinct from old.property_catalog_id
     or new.source_listing_id is distinct from old.source_listing_id
     or new.source_message_id is distinct from old.source_message_id
     or (
       old.source_portal is not null
       and new.owner_id is distinct from old.owner_id
     ) then
    raise exception 'Origem tecnica e responsavel de um lead integrado somente podem ser alterados pelo administrador.';
  end if;

  if new.registration_missing_fields is distinct from old.registration_missing_fields
     or new.registration_completed_at is distinct from old.registration_completed_at then
    raise exception 'O estado do cadastro obrigatorio e calculado automaticamente pelo CRM.';
  end if;

  if old.source_portal is not null
     and (
       new.channel is distinct from old.channel
       or new.lead_type is distinct from old.lead_type
     ) then
    raise exception 'Origem e finalidade de um lead de portal somente podem ser alteradas pelo administrador.';
  end if;

  if old.source_portal is not null then
    if new.assignment_status is distinct from old.assignment_status
       or new.assignment_reminder_sent_at is distinct from old.assignment_reminder_sent_at then
      raise exception 'Use as acoes de aceite e atendimento do CRM para alterar esta oportunidade.';
    end if;

    if new.assignment_deadline_at is distinct from old.assignment_deadline_at
       and not (
         old.assignment_status = 'accepted'
         and new.stage <> 'Em atendimento'
         and new.assignment_deadline_at is null
       ) then
      raise exception 'O prazo da esteira e controlado automaticamente pelo CRM.';
    end if;

    if (
      new.visit_feedback_at is distinct from old.visit_feedback_at
      or new.visit_started_notified_at is distinct from old.visit_started_notified_at
      or new.visit_follow_up_notified_at is distinct from old.visit_follow_up_notified_at
      or new.visit_feedback_reminder_sent_at is distinct from old.visit_feedback_reminder_sent_at
    ) and not (
      new.stage = 'Visita agendada'
      and new.visit_feedback_at is null
      and new.visit_started_notified_at is null
      and new.visit_follow_up_notified_at is null
      and new.visit_feedback_reminder_sent_at is null
    ) then
      raise exception 'Os controles de retorno da visita sao atualizados automaticamente pelo CRM.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists crm_leads_protect_whatsapp_system_fields on public.crm_leads;
create trigger crm_leads_protect_whatsapp_system_fields
before insert or update on public.crm_leads
for each row
execute procedure public.protect_whatsapp_lead_system_fields();

revoke all on function public.protect_whatsapp_lead_system_fields() from public, anon, authenticated;

create or replace function public.set_portal_lead_integration_enabled(
  p_provider text,
  p_enabled boolean
)
returns public.crm_portal_lead_integrations
language plpgsql
security definer
set search_path = public
as $$
declare
  result public.crm_portal_lead_integrations;
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores podem alterar integracoes de leads.';
  end if;

  if p_provider not in ('wimoveis_vrsync', 'dfimoveis_vrsync', 'whatsapp_business') then
    raise exception 'Integracao nao reconhecida.';
  end if;

  insert into public.crm_portal_lead_integrations(provider, enabled, updated_at, updated_by)
  values (p_provider, p_enabled, now(), auth.uid())
  on conflict (provider) do update
    set enabled = excluded.enabled,
        updated_at = excluded.updated_at,
        updated_by = excluded.updated_by
  returning * into result;

  return result;
end;
$$;

revoke all on function public.set_portal_lead_integration_enabled(text, boolean) from public;
grant execute on function public.set_portal_lead_integration_enabled(text, boolean) to authenticated;

create or replace function public.refresh_portal_lead_registration_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  missing_fields text[] := array[]::text[];
begin
  if new.source_portal is null then
    new.registration_missing_fields := array[]::text[];
    new.registration_completed_at := null;
    return new;
  end if;

  if nullif(trim(coalesce(new.name, '')), '') is null
     or lower(trim(new.name)) in ('lead sem nome', 'sem nome') then
    missing_fields := array_append(missing_fields, 'name');
  end if;

  if length(coalesce(public.normalize_crm_phone_identity(new.phone), '')) not in (10, 11) then
    missing_fields := array_append(missing_fields, 'phone');
  end if;

  if nullif(trim(coalesce(new.email, '')), '') is null
     or trim(new.email) !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    missing_fields := array_append(missing_fields, 'email');
  end if;

  if new.property_catalog_id is null
     or nullif(trim(coalesce(new.property_interest, '')), '') is null then
    missing_fields := array_append(missing_fields, 'property_interest');
  end if;

  if new.lead_type is null or new.lead_type not in ('Venda', 'Aluguel') then
    missing_fields := array_append(missing_fields, 'lead_type');
  end if;

  if new.channel is distinct from (
    case new.source_portal
      when 'wimoveis' then 'W Imóveis'
      when 'dfimoveis' then 'DF Imóveis'
      else null
    end
  ) then
    missing_fields := array_append(missing_fields, 'channel');
  end if;

  if coalesce(new.desired_property_value, 0) <= 0 then
    missing_fields := array_append(missing_fields, 'desired_property_value');
  end if;

  if nullif(trim(coalesce(new.desired_location, '')), '') is null then
    missing_fields := array_append(missing_fields, 'desired_location');
  end if;

  new.registration_missing_fields := missing_fields;
  if cardinality(missing_fields) = 0 then
    if tg_op = 'INSERT' then
      new.registration_completed_at := coalesce(new.registration_completed_at, now());
    else
      new.registration_completed_at := coalesce(old.registration_completed_at, now());
    end if;
  else
    new.registration_completed_at := null;
  end if;

  return new;
end;
$$;

drop trigger if exists crm_leads_refresh_portal_registration_fields on public.crm_leads;
create trigger crm_leads_refresh_portal_registration_fields
before insert or update of
  source_portal,
  name,
  phone,
  email,
  property_catalog_id,
  property_interest,
  lead_type,
  channel,
  desired_property_value,
  desired_location,
  registration_missing_fields,
  registration_completed_at
on public.crm_leads
for each row
execute procedure public.refresh_portal_lead_registration_fields();

create or replace function public.sync_portal_lead_registration_reminder()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  should_notify_now boolean := false;
begin
  if new.source_portal is null
     or new.assignment_status <> 'accepted'
     or cardinality(new.registration_missing_fields) = 0 then
    delete from public.crm_lead_registration_reminders
    where lead_id = new.id;
    return new;
  end if;

  should_notify_now :=
    old.assignment_status is distinct from 'accepted'
    or old.owner_id is distinct from new.owner_id
    or (
      cardinality(old.registration_missing_fields) = 0
      and cardinality(new.registration_missing_fields) > 0
    );

  if should_notify_now then
    insert into public.crm_notification_outbox(
      recipient_id, kind, title, body, url, payload
    ) values (
      new.owner_id,
      'lead_registration_incomplete',
      'Complete o cadastro do novo lead recebido',
      'Campos obrigatorios pendentes: ' || array_to_string(new.registration_missing_fields, ', ') || '.',
      '/leads',
      jsonb_build_object(
        'leadId', new.id,
        'name', new.name,
        'missingFields', to_jsonb(new.registration_missing_fields),
        'sourcePortal', new.source_portal
      )
    );

    insert into public.crm_lead_registration_reminders(
      lead_id, next_reminder_at, last_reminder_at, updated_at
    ) values (
      new.id, now() + interval '1 hour', now(), now()
    )
    on conflict (lead_id) do update
      set next_reminder_at = excluded.next_reminder_at,
          last_reminder_at = excluded.last_reminder_at,
          updated_at = excluded.updated_at;
  else
    insert into public.crm_lead_registration_reminders(
      lead_id, next_reminder_at, updated_at
    ) values (
      new.id, now() + interval '1 hour', now()
    )
    on conflict (lead_id) do nothing;
  end if;

  return new;
end;
$$;

drop trigger if exists crm_leads_sync_portal_registration_reminder on public.crm_leads;
create trigger crm_leads_sync_portal_registration_reminder
after update of
  source_portal,
  assignment_status,
  owner_id,
  name,
  phone,
  email,
  property_catalog_id,
  property_interest,
  lead_type,
  channel,
  desired_property_value,
  desired_location
on public.crm_leads
for each row
execute procedure public.sync_portal_lead_registration_reminder();

-- Preserva o aceite atual e acrescenta uma ultima validacao de elegibilidade.
-- Se o acesso ao imovel for revogado durante os 15/4 minutos, o corretor nao
-- consegue aceitar uma oportunidade que deixou de estar autorizada.
create or replace function public.accept_lead_assignment(p_lead_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  current_profile record;
begin
  update public.crm_leads as lead
  set assignment_status = 'accepted',
      assignment_deadline_at = now() + interval '24 hours',
      assignment_reminder_sent_at = null,
      stage = 'Em atendimento'
  where lead.id = p_lead_id
    and lead.owner_id = auth.uid()
    and lead.assignment_status = 'pending'
    and (
      lead.source_portal is null
      or (
        lead.property_catalog_id is not null
        and exists (
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
    );

  if not found then
    raise exception 'Este lead nao esta mais disponivel para aceite ou seu acesso ao imovel foi alterado.';
  end if;

  update public.lead_assignment_attempts as attempt
  set accepted_at = now()
  where attempt.lead_id = p_lead_id
    and attempt.broker_id = auth.uid()
    and attempt.accepted_at is null
    and attempt.expired_at is null;

  select profile.full_name, profile.email
  into current_profile
  from public.profiles as profile
  where profile.id = auth.uid();

  insert into public.crm_lead_activities(
    lead_id, stage, note, author_id, author_name
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

revoke all on function public.accept_lead_assignment(uuid) from public, anon, authenticated;
grant execute on function public.accept_lead_assignment(uuid) to authenticated;

create or replace function public.enqueue_whatsapp_admin_notification(
  p_event_id uuid,
  p_kind text,
  p_title text,
  p_body text,
  p_payload jsonb default '{}'::jsonb
)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.crm_notification_outbox(
    recipient_id, kind, title, body, url, payload
  )
  select
    profile.id,
    p_kind,
    p_title,
    p_body,
    '/leads',
    coalesce(p_payload, '{}'::jsonb) || jsonb_build_object('whatsappEventId', p_event_id)
  from public.profiles as profile
  where profile.role = 'admin';
$$;

revoke all on function public.enqueue_whatsapp_admin_notification(uuid, text, text, text, jsonb)
  from public, anon, authenticated;

create or replace function public.process_whatsapp_inbound_message(
  p_message_id text,
  p_phone text,
  p_contact_name text,
  p_message_text text,
  p_received_at timestamptz,
  p_portal text,
  p_external_code text,
  p_phone_number_id text,
  p_parse_status text,
  p_parse_reason text,
  p_payload jsonb default '{}'::jsonb
)
returns table (
  status text,
  lead_id uuid,
  duplicate boolean,
  event_id uuid
)
language plpgsql
security definer
set search_path = public
as $$
declare
  existing_event record;
  inbound_event_id uuid;
  integration_enabled boolean := false;
  normalized_portal text;
  normalized_parse_status text;
  normalized_external_code text;
  normalized_phone text;
  selected_property record;
  selected_property_id text;
  selected_broker record;
  existing_lead record;
  existing_owner_eligible boolean := false;
  eligible_brokers uuid[] := array[]::uuid[];
  next_position integer;
  lead_type_value text;
  purpose_normalized text;
  purpose_is_sale boolean;
  purpose_is_rent boolean;
  channel_value text;
  property_location text;
  inserted_lead_id uuid;
  failure_sqlstate text;
begin
  if nullif(trim(coalesce(p_message_id, '')), '') is null then
    raise exception 'message_id do WhatsApp e obrigatorio.';
  end if;

  perform pg_advisory_xact_lock(
    hashtext('whatsapp-inbound:' || trim(p_message_id))
  );

  select event.status, event.lead_id, event.id
  into existing_event
  from public.crm_whatsapp_inbound_events as event
  where event.message_id = trim(p_message_id);

  if existing_event.id is not null then
    return query
    select existing_event.status::text, existing_event.lead_id::uuid, true, existing_event.id::uuid;
    return;
  end if;

  normalized_portal := case lower(trim(coalesce(p_portal, '')))
    when 'wimoveis' then 'wimoveis'
    when 'dfimoveis' then 'dfimoveis'
    else null
  end;
  normalized_parse_status := lower(trim(coalesce(p_parse_status, '')));
  normalized_external_code := nullif(trim(coalesce(p_external_code, '')), '');
  normalized_phone := public.normalize_crm_phone_identity(p_phone);

  insert into public.crm_whatsapp_inbound_events(
    message_id,
    phone_number_id,
    sender_phone,
    contact_name,
    message_text,
    message_received_at,
    parse_status,
    parse_reason,
    portal,
    external_listing_id,
    status,
    raw_payload
  ) values (
    trim(p_message_id),
    nullif(trim(coalesce(p_phone_number_id, '')), ''),
    normalized_phone,
    nullif(trim(coalesce(p_contact_name, '')), ''),
    nullif(left(trim(coalesce(p_message_text, '')), 8000), ''),
    p_received_at,
    coalesce(nullif(normalized_parse_status, ''), 'invalid'),
    nullif(left(trim(coalesce(p_parse_reason, '')), 500), ''),
    normalized_portal,
    normalized_external_code,
    'received',
    coalesce(p_payload, '{}'::jsonb)
  )
  returning id into inbound_event_id;

  -- O evento bruto fica fora do sub-bloco. Se qualquer etapa posterior falhar,
  -- o processamento e revertido sem perder a trilha de auditoria recebida.
  begin

  select integration.enabled
  into integration_enabled
  from public.crm_portal_lead_integrations as integration
  where integration.provider = 'whatsapp_business';

  if not coalesce(integration_enabled, false) then
    update public.crm_whatsapp_inbound_events as event
    set status = 'integration_paused',
        status_reason = 'Recebimento de leads do WhatsApp pausado no CRM.',
        processed_at = now(),
        updated_at = now()
    where event.id = inbound_event_id;

    return query select 'integration_paused'::text, null::uuid, false, inbound_event_id;
    return;
  end if;

  if normalized_parse_status = 'ignored' then
    update public.crm_whatsapp_inbound_events as event
    set status = 'ignored',
        status_reason = coalesce(nullif(trim(p_parse_reason), ''), 'Mensagem sem referencia segura de imovel.'),
        processed_at = now(),
        updated_at = now()
    where event.id = inbound_event_id;

    return query select 'ignored'::text, null::uuid, false, inbound_event_id;
    return;
  end if;

  if normalized_parse_status = 'ambiguous' then
    update public.crm_whatsapp_inbound_events as event
    set status = 'ambiguous',
        status_reason = coalesce(nullif(trim(p_parse_reason), ''), 'Foram encontrados codigos conflitantes.'),
        processed_at = now(),
        updated_at = now()
    where event.id = inbound_event_id;

    perform public.enqueue_whatsapp_admin_notification(
      inbound_event_id,
      'whatsapp_message_ambiguous',
      'Mensagem de portal precisa de revisao',
      'O WhatsApp recebeu uma mensagem com referencias de imovel conflitantes.',
      jsonb_build_object('phone', normalized_phone, 'messageId', trim(p_message_id))
    );

    return query select 'ambiguous'::text, null::uuid, false, inbound_event_id;
    return;
  end if;

  if normalized_parse_status <> 'matched_candidate'
     or normalized_portal is null
     or normalized_external_code is null then
    update public.crm_whatsapp_inbound_events as event
    set status = 'invalid_payload',
        status_reason = 'Parser nao forneceu portal e codigo validos.',
        processed_at = now(),
        updated_at = now()
    where event.id = inbound_event_id;

    perform public.enqueue_whatsapp_admin_notification(
      inbound_event_id,
      'whatsapp_lead_intervention',
      'Falha ao interpretar mensagem de portal',
      'Uma mensagem candidata a lead nao trouxe portal e codigo validos.',
      jsonb_build_object('phone', normalized_phone, 'messageId', trim(p_message_id))
    );

    return query select 'invalid_payload'::text, null::uuid, false, inbound_event_id;
    return;
  end if;

  select
    reference.property_id,
    property.external_id,
    property.title,
    property.address,
    property.neighborhood,
    property.city,
    property.purpose,
    property.value
  into selected_property
  from public.crm_property_portal_references as reference
  join public.crm_property_catalog as property
    on property.external_id = reference.property_id
  where reference.portal = normalized_portal
    and reference.external_listing_id = normalized_external_code
  limit 1;

  if selected_property.external_id is null then
    update public.crm_whatsapp_inbound_events as event
    set status = 'property_not_found',
        status_reason = 'Codigo externo nao localizado nas referencias do CRM.',
        processed_at = now(),
        updated_at = now()
    where event.id = inbound_event_id;

    perform public.enqueue_whatsapp_admin_notification(
      inbound_event_id,
      'whatsapp_code_unmatched',
      'Lead recebido com codigo de imovel nao localizado',
      'Origem: ' || case normalized_portal when 'dfimoveis' then 'DF Imóveis' else 'W Imóveis' end
        || '. Codigo: ' || normalized_external_code
        || '. Cliente: ' || coalesce(nullif(trim(p_contact_name), ''), 'sem nome')
        || '. Telefone: ' || coalesce(normalized_phone, 'nao informado') || '.',
      jsonb_build_object(
        'sourcePortal', normalized_portal,
        'externalCode', normalized_external_code,
        'contactName', nullif(trim(p_contact_name), ''),
        'phone', normalized_phone,
        'message', nullif(trim(p_message_text), ''),
        'receivedAt', p_received_at,
        'messageId', trim(p_message_id)
      )
    );

    return query select 'property_not_found'::text, null::uuid, false, inbound_event_id;
    return;
  end if;

  selected_property_id := selected_property.external_id;
  update public.crm_whatsapp_inbound_events as event
  set property_id = selected_property_id,
      updated_at = now()
  where event.id = inbound_event_id;

  purpose_normalized := lower(translate(
    coalesce(selected_property.purpose, ''),
    'ÁÀÂÃÉÊÍÓÔÕÚÇáàâãéêíóôõúç',
    'AAAAEEIOOOUCaaaaeeiooouc'
  ));
  purpose_is_sale := purpose_normalized like '%vend%';
  purpose_is_rent := purpose_normalized like '%alug%' or purpose_normalized like '%loca%';

  if purpose_is_sale = purpose_is_rent then
    update public.crm_whatsapp_inbound_events as event
    set status = 'configuration_error',
        status_reason = 'Finalidade do imovel ausente ou ambigua: ' || coalesce(selected_property.purpose, 'nao informada'),
        processed_at = now(),
        updated_at = now()
    where event.id = inbound_event_id;

    perform public.enqueue_whatsapp_admin_notification(
      inbound_event_id,
      'whatsapp_lead_intervention',
      'Imovel sem finalidade unica para distribuicao',
      'Revise a finalidade do imovel ' || selected_property.title
        || ' antes de distribuir o lead do codigo ' || normalized_external_code || '.',
      jsonb_build_object(
        'propertyId', selected_property_id,
        'sourcePortal', normalized_portal,
        'externalCode', normalized_external_code
      )
    );

    return query select 'configuration_error'::text, null::uuid, false, inbound_event_id;
    return;
  end if;

  lead_type_value := case when purpose_is_rent then 'Aluguel' else 'Venda' end;
  channel_value := case normalized_portal
    when 'dfimoveis' then 'DF Imóveis'
    else 'W Imóveis'
  end;

  if normalized_phone is null or length(normalized_phone) not in (10, 11) then
    update public.crm_whatsapp_inbound_events as event
    set status = 'invalid_phone',
        status_reason = 'Telefone do remetente ausente ou invalido.',
        processed_at = now(),
        updated_at = now()
    where event.id = inbound_event_id;

    perform public.enqueue_whatsapp_admin_notification(
      inbound_event_id,
      'whatsapp_lead_intervention',
      'Lead de portal sem telefone valido',
      'Nao foi possivel distribuir o contato do codigo ' || normalized_external_code
        || ' porque o WhatsApp nao trouxe um telefone valido.',
      jsonb_build_object(
        'propertyId', selected_property_id,
        'sourcePortal', normalized_portal,
        'externalCode', normalized_external_code,
        'leadType', lead_type_value
      )
    );

    return query select 'invalid_phone'::text, null::uuid, false, inbound_event_id;
    return;
  end if;

  -- Mantem a mesma ordem de locks usada pelo cadastro manual atual:
  -- primeiro a esteira da finalidade, depois o telefone. Isso evita deadlock
  -- entre um cadastro manual e um webhook simultaneos do mesmo contato.
  perform pg_advisory_xact_lock(hashtext('lead-distribution:' || lead_type_value));
  perform pg_advisory_xact_lock(hashtext(normalized_phone));

  select lead.id, lead.owner_id, lead.name
  into existing_lead
  from public.crm_leads as lead
  where public.normalize_crm_phone_identity(lead.phone) = normalized_phone
  order by lead.created_at desc, lead.id
  limit 1;

  if existing_lead.id is not null then
    select exists (
      select 1
      from public.profiles as profile
      join public.lead_distribution_queue as queue
        on queue.broker_id = profile.id
       and queue.lead_type = lead_type_value
      join public.crm_property_broker_access as access
        on access.property_id = selected_property_id
       and access.broker_id = profile.id
      where profile.id = existing_lead.owner_id
        and profile.role = 'broker'
        and not coalesce(profile.lead_distribution_blocked, false)
    )
    into existing_owner_eligible;

    if not existing_owner_eligible then
      update public.crm_whatsapp_inbound_events as event
      set status = 'configuration_error',
          status_reason = 'O telefone pertence a um lead cujo responsavel nao esta elegivel para este imovel.',
          property_id = selected_property_id,
          lead_id = existing_lead.id,
          processed_at = now(),
          updated_at = now()
      where event.id = inbound_event_id;

      perform public.enqueue_whatsapp_admin_notification(
        inbound_event_id,
        'whatsapp_lead_intervention',
        'Recontato exige intervencao administrativa',
        coalesce(nullif(existing_lead.name, ''), 'Um cliente') || ' voltou a chamar pelo '
          || channel_value || ', mas o responsavel atual nao esta autorizado e ativo para o imovel '
          || selected_property.title || '. Nenhum contato foi redistribuido automaticamente.',
        jsonb_build_object(
          'leadId', existing_lead.id,
          'propertyId', selected_property_id,
          'sourcePortal', normalized_portal,
          'externalCode', normalized_external_code,
          'phone', normalized_phone
        )
      );

      return query select 'configuration_error'::text, existing_lead.id, false, inbound_event_id;
      return;
    end if;

    update public.crm_whatsapp_inbound_events as event
    set status = 'linked_existing',
        status_reason = 'Telefone ja pertence a um lead existente; nenhuma nova rodada foi criada.',
        property_id = selected_property_id,
        lead_id = existing_lead.id,
        eligible_broker_ids = array[existing_lead.owner_id],
        processed_at = now(),
        updated_at = now()
    where event.id = inbound_event_id;

    insert into public.crm_lead_activities(
      lead_id, stage, note, author_id, author_name
    ) values (
      existing_lead.id,
      'Novo contato via WhatsApp',
      'Origem: ' || channel_value || '. Codigo: ' || normalized_external_code
        || '. Mensagem: ' || coalesce(nullif(trim(p_message_text), ''), '(sem texto)'),
      null,
      'Integracao WhatsApp'
    );

    insert into public.crm_notification_outbox(
      recipient_id, kind, title, body, url, payload
    ) values (
      existing_lead.owner_id,
      'whatsapp_existing_lead_contact',
      'Novo contato de um lead existente',
      coalesce(nullif(existing_lead.name, ''), 'Um cliente') || ' voltou a chamar pelo '
        || channel_value || ' sobre o imovel ' || selected_property.title || '.',
      '/leads',
      jsonb_build_object(
        'leadId', existing_lead.id,
        'whatsappEventId', inbound_event_id,
        'sourcePortal', normalized_portal,
        'externalCode', normalized_external_code
      )
    );

    return query select 'linked_existing'::text, existing_lead.id, false, inbound_event_id;
    return;
  end if;

  select coalesce(array_agg(candidate.broker_id order by candidate.position), array[]::uuid[])
  into eligible_brokers
  from (
    select queue.broker_id, queue.position
    from public.lead_distribution_queue as queue
    join public.profiles as profile
      on profile.id = queue.broker_id
    join public.crm_property_broker_access as access
      on access.property_id = selected_property_id
     and access.broker_id = queue.broker_id
    where queue.lead_type = lead_type_value
      and profile.role = 'broker'
      and not coalesce(profile.lead_distribution_blocked, false)
  ) as candidate;

  update public.crm_whatsapp_inbound_events as event
  set eligible_broker_ids = eligible_brokers,
      updated_at = now()
  where event.id = inbound_event_id;

  if cardinality(eligible_brokers) = 0 then
    update public.crm_whatsapp_inbound_events as event
    set status = 'no_eligible_broker',
        status_reason = 'Nenhum corretor autorizado esta ativo e disponivel na fila do imovel.',
        processed_at = now(),
        updated_at = now()
    where event.id = inbound_event_id;

    perform public.enqueue_whatsapp_admin_notification(
      inbound_event_id,
      'whatsapp_lead_intervention',
      'Lead sem corretor elegivel',
      'Origem: ' || channel_value || '. Imovel: ' || selected_property.title
        || '. Codigo: ' || normalized_external_code || '. Finalidade: ' || lead_type_value
        || '. Cliente: '
        || coalesce(nullif(trim(p_contact_name), ''), 'sem nome') || '. Telefone: '
        || normalized_phone || '. Nenhum corretor autorizado esta disponivel.',
      jsonb_build_object(
        'propertyId', selected_property_id,
        'sourcePortal', normalized_portal,
        'externalCode', normalized_external_code,
        'leadType', lead_type_value,
        'phone', normalized_phone
      )
    );

    return query select 'no_eligible_broker'::text, null::uuid, false, inbound_event_id;
    return;
  end if;

  select queue.broker_id, profile.full_name, profile.email
  into selected_broker
  from public.lead_distribution_queue as queue
  join public.profiles as profile
    on profile.id = queue.broker_id
  join public.crm_property_broker_access as access
    on access.property_id = selected_property_id
   and access.broker_id = queue.broker_id
  where queue.lead_type = lead_type_value
    and profile.role = 'broker'
    and not coalesce(profile.lead_distribution_blocked, false)
  order by queue.position
  limit 1
  for update of queue skip locked;

  if selected_broker.broker_id is null then
    update public.crm_whatsapp_inbound_events as event
    set status = 'no_eligible_broker',
        status_reason = 'A fila mudou durante o processamento e nenhum corretor permaneceu elegivel.',
        processed_at = now(),
        updated_at = now()
    where event.id = inbound_event_id;

    perform public.enqueue_whatsapp_admin_notification(
      inbound_event_id,
      'whatsapp_lead_intervention',
      'Lead sem corretor elegivel',
      'Nenhum corretor permaneceu disponivel para o imovel ' || selected_property.title || '.',
      jsonb_build_object(
        'propertyId', selected_property_id,
        'sourcePortal', normalized_portal,
        'externalCode', normalized_external_code,
        'leadType', lead_type_value
      )
    );

    return query select 'no_eligible_broker'::text, null::uuid, false, inbound_event_id;
    return;
  end if;

  select coalesce(max(queue.position), 0) + 1
  into next_position
  from public.lead_distribution_queue as queue
  where queue.lead_type = lead_type_value;

  update public.lead_distribution_queue as queue
  set position = next_position,
      updated_at = now()
  where queue.lead_type = lead_type_value
    and queue.broker_id = selected_broker.broker_id;

  property_location := nullif(
    concat_ws(
      ', ',
      nullif(trim(coalesce(selected_property.address, '')), ''),
      nullif(trim(coalesce(selected_property.neighborhood, '')), ''),
      nullif(trim(coalesce(selected_property.city, '')), '')
    ),
    ''
  );

  insert into public.crm_leads(
    name,
    phone,
    email,
    property_interest,
    stage,
    channel,
    budget,
    notes,
    owner_id,
    created_by,
    lead_type,
    desired_property_value,
    desired_location,
    property_catalog_id,
    source_portal,
    source_listing_id,
    source_message_id
  ) values (
    coalesce(nullif(trim(p_contact_name), ''), 'Lead sem nome'),
    normalized_phone,
    null,
    selected_property.title,
    'Lead',
    channel_value,
    0,
    nullif(trim(p_message_text), ''),
    selected_broker.broker_id,
    selected_broker.broker_id,
    lead_type_value,
    coalesce(selected_property.value, 0),
    property_location,
    selected_property_id,
    normalized_portal,
    normalized_external_code,
    trim(p_message_id)
  )
  returning id into inserted_lead_id;

  insert into public.crm_lead_activities(
    lead_id, stage, note, author_id, author_name
  ) values (
    inserted_lead_id,
    'Lead recebido via WhatsApp',
    'Origem: ' || channel_value || '. Codigo: ' || normalized_external_code
      || '. Mensagem original: ' || coalesce(nullif(trim(p_message_text), ''), '(sem texto)'),
    null,
    'Integracao WhatsApp'
  );

  update public.crm_whatsapp_inbound_events as event
  set status = 'lead_created',
      status_reason = 'Lead criado e primeira tentativa de distribuicao iniciada.',
      property_id = selected_property_id,
      lead_id = inserted_lead_id,
      processed_at = now(),
      updated_at = now()
  where event.id = inbound_event_id;

  return query select 'lead_created'::text, inserted_lead_id, false, inbound_event_id;
  exception
    when others then
      get stacked diagnostics failure_sqlstate = returned_sqlstate;

      update public.crm_whatsapp_inbound_events as event
      set status = 'failed',
          status_reason = 'Falha interna durante o processamento. Consulte o codigo SQLSTATE no evento.',
          error_sqlstate = failure_sqlstate,
          processed_at = now(),
          updated_at = now()
      where event.id = inbound_event_id;

      -- A falha do proprio canal de notificacao nao pode apagar o evento de
      -- auditoria nem impedir a resposta idempotente do webhook.
      begin
        perform public.enqueue_whatsapp_admin_notification(
          inbound_event_id,
          'whatsapp_lead_intervention',
          'Falha interna ao processar mensagem do WhatsApp',
          'O evento foi preservado para analise administrativa. Codigo SQLSTATE: '
            || coalesce(failure_sqlstate, 'desconhecido') || '.',
          jsonb_build_object('messageId', trim(p_message_id))
        );
      exception
        when others then
          null;
      end;

      return query select 'failed'::text, null::uuid, false, inbound_event_id;
      return;
  end;
end;
$$;

revoke all on function public.process_whatsapp_inbound_message(
  text, text, text, text, timestamptz, text, text, text, text, text, jsonb
) from public, anon, authenticated;
grant execute on function public.process_whatsapp_inbound_message(
  text, text, text, text, timestamptz, text, text, text, text, text, jsonb
) to service_role;

-- Mantem a regra existente de 15 minutos na primeira tentativa e 4 minutos
-- nas seguintes, mas nunca sai do conjunto autorizado para leads de portal.
create or replace function public.process_expired_lead_assignments()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  lead_row record;
  next_broker record;
  next_position integer;
  attempt_count integer;
  timeout_message text;
  source_label text;
begin
  for lead_row in
    select *
    from public.crm_leads
    where assignment_deadline_at <= now()
      and (
        assignment_status = 'pending'
        or (assignment_status = 'accepted' and stage = 'Em atendimento')
      )
    for update skip locked
  loop
    update public.lead_assignment_attempts as attempt
    set expired_at = now()
    where attempt.lead_id = lead_row.id
      and attempt.expired_at is null
      and (
        (lead_row.assignment_status = 'pending' and attempt.accepted_at is null)
        or lead_row.assignment_status = 'accepted'
      );

    if lead_row.assignment_status = 'pending' then
      insert into public.crm_notification_outbox(
        recipient_id, kind, title, body, url, payload
      ) values (
        lead_row.owner_id,
        'lead_assignment_expired',
        'Prazo para aceitar o lead expirou',
        'O prazo para assumir o atendimento de ' || lead_row.name || ' terminou.',
        '/leads',
        jsonb_build_object(
          'leadId', lead_row.id,
          'name', lead_row.name,
          'sourcePortal', lead_row.source_portal,
          'externalCode', lead_row.source_listing_id
        )
      );
    end if;

    insert into public.crm_lead_activities(
      lead_id, stage, note, author_id, author_name
    ) values (
      lead_row.id,
      case
        when lead_row.assignment_status = 'pending' then 'Prazo de aceite expirado'
        else 'Prazo de atendimento expirado'
      end,
      'Prazo do corretor responsavel encerrado automaticamente pelo sistema.',
      null,
      'Sistema'
    );

    select count(*)
    into attempt_count
    from public.lead_assignment_attempts as attempt
    where attempt.lead_id = lead_row.id;

    perform pg_advisory_xact_lock(
      hashtext('lead-distribution:' || lead_row.lead_type)
    );

    select queue.broker_id, profile.full_name, profile.email
    into next_broker
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
          and previous_attempt.broker_id = queue.broker_id
      )
      and (
        lead_row.source_portal is null
        or (
          lead_row.property_catalog_id is not null
          and exists (
            select 1
            from public.crm_property_broker_access as access
            where access.property_id = lead_row.property_catalog_id
              and access.broker_id = queue.broker_id
          )
        )
      )
    order by queue.position
    limit 1
    for update of queue skip locked;

    if next_broker.broker_id is null then
      update public.crm_leads as lead
      set assignment_status = 'exhausted',
          assignment_deadline_at = null
      where lead.id = lead_row.id;

      source_label := case lead_row.source_portal
        when 'dfimoveis' then 'DF Imóveis'
        when 'wimoveis' then 'W Imóveis'
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
          || '. Todos os corretores elegiveis foram acionados e nenhum assumiu o lead.'
        when lead_row.assignment_status = 'accepted' then
          lead_row.name || ' ficou 24h em atendimento sem avanco.'
        else
          lead_row.name || ' nao foi assumido por nenhum corretor disponivel.'
      end;

      insert into public.crm_notification_outbox(
        recipient_id, kind, title, body, url, payload
      )
      select
        profile.id,
        'lead_unanswered',
        case
          when lead_row.source_portal is not null then 'Lead de portal sem atendimento'
          else 'Esteira de atendimento esgotada'
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
          'attemptCount', attempt_count
        )
      from public.profiles as profile
      where profile.role = 'admin';
    else
      select coalesce(max(queue.position), 0) + 1
      into next_position
      from public.lead_distribution_queue as queue
      where queue.lead_type = lead_row.lead_type;

      update public.lead_distribution_queue as queue
      set position = next_position,
          updated_at = now()
      where queue.lead_type = lead_row.lead_type
        and queue.broker_id = next_broker.broker_id;

      update public.crm_leads as lead
      set owner_id = next_broker.broker_id,
          assignment_status = 'pending',
          assignment_deadline_at = now() + interval '4 minutes',
          assignment_reminder_sent_at = null,
          stage = 'Aguardando atendimento'
      where lead.id = lead_row.id;

      insert into public.lead_assignment_attempts(
        lead_id, broker_id, attempt_number, deadline_at
      ) values (
        lead_row.id,
        next_broker.broker_id,
        attempt_count + 1,
        now() + interval '4 minutes'
      );

      insert into public.crm_notification_outbox(
        recipient_id, kind, title, body, url, payload
      ) values (
        next_broker.broker_id,
        'lead_assignment',
        'Lead transferido para sua carteira',
        'Voce tem 4 minutos para iniciar o atendimento de ' || lead_row.name || '.',
        '/leads',
        jsonb_build_object(
          'leadId', lead_row.id,
          'phone', lead_row.phone,
          'name', lead_row.name,
          'sourcePortal', lead_row.source_portal,
          'externalCode', lead_row.source_listing_id,
          'attemptNumber', attempt_count + 1
        )
      );

      insert into public.crm_lead_activities(
        lead_id, stage, note, author_id, author_name
      ) values (
        lead_row.id,
        'Lead redistribuido',
        'Nova tentativa enviada ao corretor '
          || coalesce(nullif(next_broker.full_name, ''), next_broker.email)
          || ' com prazo de 4 minutos.',
        null,
        'Sistema'
      );
    end if;
  end loop;
end;
$$;

revoke all on function public.process_expired_lead_assignments() from public, anon, authenticated;
grant execute on function public.process_expired_lead_assignments() to service_role;

-- Preserva os dois lembretes existentes (atendimento e visita) e acrescenta
-- somente a cobranca horaria do cadastro obrigatorio de leads de portal.
create or replace function public.process_due_lead_reminders()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  lead_row record;
  registration_row record;
begin
  -- 30 min antes de vencer as 24h do atendimento.
  for lead_row in
    select id, owner_id, name, assignment_deadline_at
    from public.crm_leads
    where assignment_status = 'accepted'
      and stage = 'Em atendimento'
      and assignment_deadline_at > now()
      and assignment_deadline_at <= now() + interval '30 minutes'
      and assignment_reminder_sent_at is null
    for update skip locked
  loop
    update public.crm_leads
    set assignment_reminder_sent_at = now()
    where id = lead_row.id;

    insert into public.crm_notification_outbox(
      recipient_id, kind, title, body, url, payload
    ) values (
      lead_row.owner_id,
      'attendance_reminder',
      'Atendimento vence em 30 minutos',
      'O prazo do lead ' || lead_row.name
        || ' termina em até 30 minutos. Avance a etapa ou registre “Ainda em atendimento”.',
      '/leads',
      jsonb_build_object('leadId', lead_row.id, 'name', lead_row.name)
    );
  end loop;

  -- 30 min antes da cobranca obrigatoria de feedback, que ocorre 2h apos a visita.
  for lead_row in
    select id, owner_id, name, visit_scheduled_at
    from public.crm_leads
    where stage = 'Visita agendada'
      and visit_scheduled_at <= now() - interval '1 hour 30 minutes'
      and visit_scheduled_at > now() - interval '2 hours'
      and visit_feedback_at is null
      and visit_feedback_reminder_sent_at is null
    for update skip locked
  loop
    update public.crm_leads
    set visit_feedback_reminder_sent_at = now()
    where id = lead_row.id;

    insert into public.crm_notification_outbox(
      recipient_id, kind, title, body, url, payload
    ) values (
      lead_row.owner_id,
      'visit_feedback_reminder',
      'Feedback da visita vence em 30 minutos',
      'Registre como foi a visita com ' || lead_row.name
        || ' antes de ser bloqueado da fila.',
      '/leads',
      jsonb_build_object('leadId', lead_row.id, 'name', lead_row.name)
    );
  end loop;

  -- O estado fica travado e e avancado antes do insert para impedir duplicidade
  -- mesmo quando duas execucoes do job comecam praticamente juntas.
  for registration_row in
    select
      reminder.lead_id,
      lead.owner_id,
      lead.name,
      lead.source_portal,
      lead.registration_missing_fields
    from public.crm_lead_registration_reminders as reminder
    join public.crm_leads as lead
      on lead.id = reminder.lead_id
    where reminder.next_reminder_at <= now()
      and lead.source_portal is not null
      and lead.assignment_status = 'accepted'
      and cardinality(lead.registration_missing_fields) > 0
    for update of reminder skip locked
  loop
    update public.crm_lead_registration_reminders as reminder
    set last_reminder_at = now(),
        next_reminder_at = now() + interval '1 hour',
        updated_at = now()
    where reminder.lead_id = registration_row.lead_id;

    insert into public.crm_notification_outbox(
      recipient_id, kind, title, body, url, payload
    ) values (
      registration_row.owner_id,
      'lead_registration_incomplete',
      'Complete o cadastro do novo lead recebido',
      'Campos obrigatorios pendentes: '
        || array_to_string(registration_row.registration_missing_fields, ', ') || '.',
      '/leads',
      jsonb_build_object(
        'leadId', registration_row.lead_id,
        'name', registration_row.name,
        'missingFields', to_jsonb(registration_row.registration_missing_fields),
        'sourcePortal', registration_row.source_portal
      )
    );
  end loop;

  delete from public.crm_lead_registration_reminders as reminder
  using public.crm_leads as lead
  where lead.id = reminder.lead_id
    and (
      lead.source_portal is null
      or lead.assignment_status <> 'accepted'
      or cardinality(lead.registration_missing_fields) = 0
    );
end;
$$;

revoke all on function public.process_due_lead_reminders() from public, anon, authenticated;
grant execute on function public.process_due_lead_reminders() to service_role;

comment on table public.crm_whatsapp_inbound_events is
  'Auditoria idempotente das mensagens de texto recebidas pelo webhook oficial do WhatsApp.';

comment on column public.crm_leads.source_portal is
  'Portal identificado na mensagem original: wimoveis ou dfimoveis.';

comment on column public.crm_leads.source_listing_id is
  'Codigo externo do anuncio extraido com seguranca da mensagem do portal.';

comment on column public.crm_leads.registration_missing_fields is
  'Identificadores dos campos obrigatorios ainda pendentes no cadastro do lead de portal.';

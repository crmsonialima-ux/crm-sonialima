-- Expediente operacional das notificacoes: 08:00 <= hora < 19:00,
-- todos os dias, sempre interpretado em America/Sao_Paulo.
--
-- Alertas ligados a horario, escalonamentos e contatos que podem perder um
-- lead continuam imediatos. Avisos administrativos/repetitivos sao liberados
-- na proxima abertura. A esteira de aceite preserva integralmente os 15/4
-- minutos, mas passa a conta-los somente dentro do expediente.

create or replace function public.crm_is_business_hours(
  p_moment timestamptz default now()
)
returns boolean
language sql
stable
set search_path = public
as $$
  select (p_moment at time zone 'America/Sao_Paulo')::time >= time '08:00'
     and (p_moment at time zone 'America/Sao_Paulo')::time < time '19:00';
$$;

create or replace function public.crm_next_business_moment(
  p_moment timestamptz default now()
)
returns timestamptz
language plpgsql
stable
set search_path = public
as $$
declare
  local_moment timestamp := p_moment at time zone 'America/Sao_Paulo';
  next_local timestamp;
begin
  if local_moment::time < time '08:00' then
    next_local := local_moment::date + time '08:00';
  elsif local_moment::time >= time '19:00' then
    next_local := (local_moment::date + 1) + time '08:00';
  else
    return p_moment;
  end if;

  return next_local at time zone 'America/Sao_Paulo';
end;
$$;

create or replace function public.crm_add_business_minutes(
  p_start timestamptz,
  p_minutes integer
)
returns timestamptz
language plpgsql
stable
set search_path = public
as $$
declare
  local_cursor timestamp;
  local_close timestamp;
  available_minutes integer;
  remaining_minutes integer := greatest(coalesce(p_minutes, 0), 0);
begin
  local_cursor := public.crm_next_business_moment(p_start)
    at time zone 'America/Sao_Paulo';

  while remaining_minutes > 0 loop
    local_close := local_cursor::date + time '19:00';
    available_minutes := greatest(
      floor(extract(epoch from (local_close - local_cursor)) / 60)::integer,
      0
    );

    if remaining_minutes <= available_minutes then
      local_cursor := local_cursor + make_interval(mins => remaining_minutes);
      remaining_minutes := 0;
    else
      remaining_minutes := remaining_minutes - available_minutes;
      local_cursor := (local_cursor::date + 1) + time '08:00';
    end if;
  end loop;

  return local_cursor at time zone 'America/Sao_Paulo';
end;
$$;

revoke all on function public.crm_is_business_hours(timestamptz) from public, anon;
revoke all on function public.crm_next_business_moment(timestamptz) from public, anon;
revoke all on function public.crm_add_business_minutes(timestamptz,integer) from public, anon;
grant execute on function public.crm_is_business_hours(timestamptz) to authenticated, service_role;
grant execute on function public.crm_next_business_moment(timestamptz) to authenticated, service_role;
grant execute on function public.crm_add_business_minutes(timestamptz,integer) to authenticated, service_role;

alter table public.crm_notification_outbox
  add column if not exists available_at timestamptz;

-- Notificacoes antigas mantem a disponibilidade original. A regra nova vale
-- apenas para eventos gerados depois desta migration.
update public.crm_notification_outbox
set available_at = created_at
where available_at is null;

alter table public.crm_notification_outbox
  alter column available_at set default now(),
  alter column available_at set not null;

create index if not exists crm_notification_outbox_available_delivery_idx
  on public.crm_notification_outbox (available_at, created_at, id)
  where delivered_at is null;

create table if not exists public.crm_notification_delivery_policies (
  kind text primary key,
  delivery_mode text not null
    check (delivery_mode in ('immediate', 'business_hours')),
  rationale text not null,
  updated_at timestamptz not null default now()
);

alter table public.crm_notification_delivery_policies enable row level security;
revoke all on public.crm_notification_delivery_policies from public, anon, authenticated;

-- Tipos desconhecidos permanecem imediatos por seguranca. Assim uma nova
-- notificacao critica nunca sera adiada silenciosamente por falta de cadastro.
insert into public.crm_notification_delivery_policies(kind, delivery_mode, rationale)
values
  ('lead_assignment', 'business_hours', 'A esteira usa minutos uteis e so pode ser aceita durante o expediente.'),
  ('lead_assignment_expired', 'immediate', 'Informa expiracao efetivamente processada.'),
  ('lead_unanswered', 'immediate', 'Escalonamento operacional para administradores.'),
  ('attendance_reminder', 'immediate', 'Aviso exato antes do prazo de 24 horas.'),
  ('visit_started', 'immediate', 'Aviso ligado ao horario real da visita.'),
  ('visit_follow_up', 'immediate', 'Bloqueio e retorno ligados ao horario real da visita.'),
  ('visit_feedback_reminder', 'immediate', 'Aviso exato antes do bloqueio de visita.'),
  ('lead_visit_scheduled', 'immediate', 'Compromisso com data e hora definidas.'),
  ('whatsapp_existing_lead_contact', 'immediate', 'Contato real de cliente que exige atendimento.'),
  ('whatsapp_code_unmatched', 'immediate', 'Falha pode impedir a distribuicao de um lead real.'),
  ('whatsapp_lead_intervention', 'immediate', 'Falha pode impedir a distribuicao de um lead real.'),
  ('whatsapp_message_ambiguous', 'immediate', 'Mensagem de possivel cliente exige revisao.'),
  ('agenda_new_demand', 'immediate', 'O responsavel deve ser avisado no momento da criacao.'),
  ('agenda_reminder', 'immediate', 'Lembrete exato de compromisso.'),
  ('agenda_requester_reminder', 'immediate', 'Lembrete exato de demanda em 30 minutos.'),
  ('agenda_requester_followup', 'immediate', 'Acompanhamento exato uma hora apos a demanda.'),
  ('agenda_escalation', 'immediate', 'Escalonamentos de 3, 5 e 24 horas nao podem ser alterados.'),
  ('agenda_cartorio_delivered_to_vitor', 'immediate', 'Vitor deve ser avisado no ato da entrega.'),
  ('agenda_cartorio_vitor_document_overdue', 'immediate', 'Escalonamento de 24 horas para administradores.'),
  ('agenda_pickup_reminder', 'immediate', 'O job ja dispara as 09:00 de Brasilia.'),
  ('property_match', 'business_hours', 'Sugestao comercial sem prazo de minutos.'),
  ('proposal_admin_alert', 'business_hours', 'Aviso administrativo sem prazo imediato.'),
  ('property_document_reminder', 'business_hours', 'Cobranca documental recorrente.'),
  ('lead_proposal_document_reminder', 'business_hours', 'Cobranca documental recorrente.'),
  ('lead_registration_incomplete', 'business_hours', 'Cobranca horaria de cadastro.'),
  ('agenda_protocol_reminder', 'business_hours', 'Cobranca repetitiva a cada 15 minutos.'),
  ('agenda_cartorio_vitor_document_reminder', 'business_hours', 'Cobranca repetitiva a cada hora.'),
  ('agenda_request_progress', 'business_hours', 'Atualizacao informativa de andamento.'),
  ('agenda_request_completed', 'business_hours', 'Atualizacao informativa de conclusao.'),
  ('assignment_lab', 'immediate', 'Teste manual com prazo curto.'),
  ('assignment_lab_complete', 'immediate', 'Resultado de teste iniciado manualmente.'),
  ('assignment_queue_separation_test', 'immediate', 'Teste manual da esteira.')
on conflict (kind) do update
set delivery_mode = excluded.delivery_mode,
    rationale = excluded.rationale,
    updated_at = now();

create or replace function public.crm_apply_notification_business_hours()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  configured_mode text;
  event_moment timestamptz;
begin
  if tg_op = 'UPDATE' then
    if new.kind is not distinct from old.kind
       and new.created_at is not distinct from old.created_at
       and new.available_at is not distinct from old.available_at then
      return new;
    end if;
  end if;

  select policy.delivery_mode
  into configured_mode
  from public.crm_notification_delivery_policies as policy
  where policy.kind = new.kind;

  event_moment := coalesce(new.created_at, now());
  new.available_at := coalesce(new.available_at, event_moment);

  if configured_mode = 'business_hours' then
    new.available_at := greatest(
      new.available_at,
      public.crm_next_business_moment(event_moment)
    );
  end if;

  return new;
end;
$$;

revoke all on function public.crm_apply_notification_business_hours()
  from public, anon, authenticated;

drop trigger if exists crm_notification_apply_business_hours
  on public.crm_notification_outbox;
create trigger crm_notification_apply_business_hours
before insert or update on public.crm_notification_outbox
for each row execute function public.crm_apply_notification_business_hours();

-- O inbox e o polling local so enxergam a notificacao quando ela estiver
-- liberada. A policy global do validador criada na migration 70 permanece
-- independente e continua permitindo a auditoria dos itens agendados.
drop policy if exists "Users read their notifications"
  on public.crm_notification_outbox;
create policy "Users read their notifications"
  on public.crm_notification_outbox
  for select
  using (
    recipient_id = auth.uid()
    and available_at <= now()
  );

drop policy if exists "Users update their notifications"
  on public.crm_notification_outbox;
create policy "Users update their notifications"
  on public.crm_notification_outbox
  for update
  using (
    recipient_id = auth.uid()
    and available_at <= now()
  )
  with check (
    recipient_id = auth.uid()
    and available_at <= now()
  );

-- Primeiro corretor: 15 minutos uteis. O registro pode nascer fora do
-- expediente, mas o prazo e a notificacao so comecam na proxima abertura.
create or replace function public.start_lead_assignment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  assignment_available_at timestamptz := public.crm_next_business_moment(now());
  assignment_deadline timestamptz := public.crm_add_business_minutes(now(), 15);
begin
  update public.crm_leads
  set assignment_status = 'pending',
      assignment_deadline_at = assignment_deadline,
      stage = 'Aguardando atendimento'
  where id = new.id;

  insert into public.lead_assignment_attempts(
    lead_id, broker_id, attempt_number, notified_at, deadline_at
  ) values (
    new.id, new.owner_id, 1, assignment_available_at, assignment_deadline
  );

  insert into public.crm_notification_outbox(
    recipient_id, kind, title, body, url, payload, available_at
  ) values (
    new.owner_id,
    'lead_assignment',
    'Novo lead aguardando atendimento',
    'Voce tem 15 minutos uteis para iniciar o atendimento de ' || new.name || '.',
    '/leads',
    jsonb_build_object(
      'leadId', new.id,
      'phone', new.phone,
      'name', new.name,
      'availableAt', assignment_available_at,
      'deadlineAt', assignment_deadline
    ),
    assignment_available_at
  );

  return new;
end;
$$;

revoke all on function public.start_lead_assignment() from public, anon, authenticated;

-- O aceite fora da janela ou depois do prazo e recusado, inclusive se o job
-- ainda nao tiver processado a expiracao no minuto da virada.
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
    and lead.assignment_deadline_at > now()
    and public.crm_is_business_hours(now())
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
    raise exception 'Este lead nao esta disponivel para aceite neste horario ou seu prazo/acesso foi alterado.';
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

revoke all on function public.accept_lead_assignment(uuid)
  from public, anon, authenticated;
grant execute on function public.accept_lead_assignment(uuid) to authenticated;

-- Mantem uma unica cadencia horaria para cadastro incompleto. Se o aceite
-- ocorrer fora da janela, o primeiro aviso abre as 08:00 e o proximo as 09:00.
create or replace function public.sync_portal_lead_registration_reminder()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  should_notify_now boolean := false;
  first_available_at timestamptz := public.crm_next_business_moment(now());
  next_business_reminder timestamptz := public.crm_add_business_minutes(now(), 60);
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
      recipient_id, kind, title, body, url, payload, available_at
    ) values (
      new.owner_id,
      'lead_registration_incomplete',
      'Complete o cadastro do novo lead recebido',
      'Campos obrigatorios pendentes: '
        || array_to_string(new.registration_missing_fields, ', ') || '.',
      '/leads',
      jsonb_build_object(
        'leadId', new.id,
        'name', new.name,
        'missingFields', to_jsonb(new.registration_missing_fields),
        'sourcePortal', new.source_portal
      ),
      first_available_at
    );

    insert into public.crm_lead_registration_reminders(
      lead_id, next_reminder_at, last_reminder_at, updated_at
    ) values (
      new.id, next_business_reminder, now(), now()
    )
    on conflict (lead_id) do update
      set next_reminder_at = excluded.next_reminder_at,
          last_reminder_at = excluded.last_reminder_at,
          updated_at = excluded.updated_at;
  else
    insert into public.crm_lead_registration_reminders(
      lead_id, next_reminder_at, updated_at
    ) values (
      new.id, next_business_reminder, now()
    )
    on conflict (lead_id) do nothing;
  end if;

  return new;
end;
$$;

revoke all on function public.sync_portal_lead_registration_reminder()
  from public, anon, authenticated;

-- Pendencias de aceite so giram durante o expediente. O prazo absoluto de
-- 24 horas de um atendimento aceito continua sendo processado no horario
-- real; uma eventual nova tentativa nasce para a proxima janela.
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
  next_available_at timestamptz;
  next_deadline_at timestamptz;
begin
  for lead_row in
    select *
    from public.crm_leads
    where assignment_deadline_at <= now()
      and (
        assignment_status = 'pending'
        or (assignment_status = 'accepted' and stage = 'Em atendimento')
      )
      and (
        assignment_status = 'accepted'
        or public.crm_is_business_hours(now())
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

      next_available_at := public.crm_next_business_moment(now());
      next_deadline_at := public.crm_add_business_minutes(now(), 4);

      update public.crm_leads as lead
      set owner_id = next_broker.broker_id,
          assignment_status = 'pending',
          assignment_deadline_at = next_deadline_at,
          assignment_reminder_sent_at = null,
          stage = 'Aguardando atendimento'
      where lead.id = lead_row.id;

      insert into public.lead_assignment_attempts(
        lead_id, broker_id, attempt_number, notified_at, deadline_at
      ) values (
        lead_row.id,
        next_broker.broker_id,
        attempt_count + 1,
        next_available_at,
        next_deadline_at
      );

      insert into public.crm_notification_outbox(
        recipient_id, kind, title, body, url, payload, available_at
      ) values (
        next_broker.broker_id,
        'lead_assignment',
        'Lead transferido para sua carteira',
        'Voce tem 4 minutos uteis para iniciar o atendimento de ' || lead_row.name || '.',
        '/leads',
        jsonb_build_object(
          'leadId', lead_row.id,
          'phone', lead_row.phone,
          'name', lead_row.name,
          'sourcePortal', lead_row.source_portal,
          'externalCode', lead_row.source_listing_id,
          'attemptNumber', attempt_count + 1,
          'availableAt', next_available_at,
          'deadlineAt', next_deadline_at
        ),
        next_available_at
      );

      insert into public.crm_lead_activities(
        lead_id, stage, note, author_id, author_name
      ) values (
        lead_row.id,
        'Lead redistribuido',
        'Nova tentativa enviada ao corretor '
          || coalesce(nullif(next_broker.full_name, ''), next_broker.email)
          || ' com prazo de 4 minutos uteis.',
        null,
        'Sistema'
      );
    end if;
  end loop;
end;
$$;

revoke all on function public.process_expired_lead_assignments()
  from public, anon, authenticated;
grant execute on function public.process_expired_lead_assignments() to service_role;

-- Os alertas exatos de atendimento/visita continuam 24/7. Somente a
-- cobranca horaria de cadastro incompleto respeita e consome horario util.
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
        || ' termina em ate 30 minutos. Avance a etapa ou registre "Ainda em atendimento".',
      '/leads',
      jsonb_build_object('leadId', lead_row.id, 'name', lead_row.name)
    );
  end loop;

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

  if public.crm_is_business_hours(now()) then
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
          next_reminder_at = public.crm_add_business_minutes(now(), 60),
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
  end if;

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

revoke all on function public.process_due_lead_reminders()
  from public, anon, authenticated;
grant execute on function public.process_due_lead_reminders() to service_role;

-- Preserva todos os prazos exatos da Agenda. Apenas a cobranca repetitiva do
-- protocolo deixa de gerar linhas durante a noite; as 08:00 sai um unico
-- lembrete e a cadencia de 15 minutos recomeca dali.
create or replace function public.process_agenda_notifications()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  entry record;
  derley_id uuid;
  vitor_id uuid;
begin
  select id into derley_id
  from public.profiles
  where lower(email) = 'unassigned-agenda@example.invalid'
  limit 1;

  select id into vitor_id
  from public.profiles
  where lower(email) = 'unassigned-operator@example.invalid'
  limit 1;

  for entry in
    select agenda.*
    from public.crm_agenda_entries as agenda
    where agenda.reminder_sent_at is null
      and agenda.scheduled_at between now() and now() + interval '30 minutes'
    for update of agenda skip locked
  loop
    if entry.target_user_id = derley_id
       and entry.created_by is distinct from derley_id
       and entry.source_kind is distinct from 'lead_visit' then
      perform public.enqueue_agenda_requester_notification(
        entry.id,
        'pre_30m',
        'agenda_requester_reminder',
        'Demanda do Derley em 30 minutos',
        'A demanda que voce cadastrou para o Derley comeca em 30 minutos: '
          || entry.observation
      );
    else
      insert into public.crm_notification_outbox(
        recipient_id, kind, title, body, url, payload
      ) values (
        entry.target_user_id,
        'agenda_reminder',
        'Compromisso em 30 minutos',
        entry.observation,
        '/agenda',
        jsonb_build_object('agendaId', entry.id)
      );
    end if;

    update public.crm_agenda_entries
    set reminder_sent_at = now()
    where id = entry.id;
  end loop;

  for entry in
    select agenda.*
    from public.crm_agenda_entries as agenda
    where agenda.target_user_id = derley_id
      and agenda.created_by is distinct from derley_id
      and agenda.source_kind is distinct from 'lead_visit'
      and agenda.scheduled_at + interval '1 hour' <= now()
      and not exists (
        select 1
        from public.crm_agenda_requester_notification_events as sent_event
        where sent_event.agenda_id = agenda.id
          and sent_event.event_key = 'post_1h'
      )
    for update of agenda skip locked
  loop
    perform public.enqueue_agenda_requester_notification(
      entry.id,
      'post_1h',
      'agenda_requester_followup',
      'Acompanhe a demanda enviada ao Derley',
      'Ja passou 1 hora do horario marcado. Consulte o andamento da demanda: '
        || entry.observation
    );
  end loop;

  for entry in
    select agenda.*
    from public.crm_agenda_entries as agenda
    where agenda.category in ('neo_energia', 'caesb')
      and agenda.target_user_id = derley_id
      and agenda.feedback_at is null
      and agenda.scheduled_at + interval '3 hours' <= now()
      and agenda.vitor_notified_at is null
    for update of agenda skip locked
  loop
    if vitor_id is not null then
      insert into public.crm_notification_outbox(
        recipient_id, kind, title, body, url, payload
      ) values (
        vitor_id,
        'agenda_escalation',
        'Demanda sem retorno de Derley',
        entry.observation,
        '/agenda',
        jsonb_build_object('agendaId', entry.id)
      );
    end if;

    update public.crm_agenda_entries
    set vitor_notified_at = now()
    where id = entry.id;
  end loop;

  for entry in
    select agenda.*
    from public.crm_agenda_entries as agenda
    where agenda.category in ('neo_energia', 'caesb')
      and agenda.target_user_id = derley_id
      and agenda.feedback_at is null
      and agenda.scheduled_at + interval '5 hours' <= now()
      and agenda.admin_notified_at is null
    for update of agenda skip locked
  loop
    insert into public.crm_notification_outbox(
      recipient_id, kind, title, body, url, payload
    )
    select
      profile.id,
      'agenda_escalation',
      'Demanda sem retorno',
      'Derley e Vitor ainda nao registraram retorno: ' || entry.observation,
      '/agenda',
      jsonb_build_object('agendaId', entry.id)
    from public.profiles as profile
    where profile.role = 'admin';

    update public.crm_agenda_entries
    set admin_notified_at = now()
    where id = entry.id;
  end loop;

  if public.crm_is_business_hours(now()) then
    for entry in
      select agenda.*
      from public.crm_agenda_entries as agenda
      where agenda.category = 'cartorio'
        and agenda.target_user_id = derley_id
        and agenda.protocol_path is null
        and agenda.scheduled_at + interval '3 hours' <= now()
        and (
          agenda.protocol_reminder_sent_at is null
          or agenda.protocol_reminder_sent_at <= now() - interval '15 minutes'
        )
      for update of agenda skip locked
    loop
      insert into public.crm_notification_outbox(
        recipient_id, kind, title, body, url, payload
      ) values (
        derley_id,
        'agenda_protocol_reminder',
        'Anexe o protocolo do Cartorio',
        entry.observation,
        '/agenda',
        jsonb_build_object('agendaId', entry.id)
      );

      update public.crm_agenda_entries
      set protocol_reminder_sent_at = now()
      where id = entry.id;
    end loop;
  end if;

  for entry in
    select agenda.*
    from public.crm_agenda_entries as agenda
    where agenda.category = 'cartorio'
      and agenda.target_user_id = derley_id
      and agenda.protocol_path is null
      and agenda.scheduled_at + interval '24 hours' <= now()
      and agenda.protocol_vitor_notified_at is null
    for update of agenda skip locked
  loop
    if vitor_id is not null then
      insert into public.crm_notification_outbox(
        recipient_id, kind, title, body, url, payload
      ) values (
        vitor_id,
        'agenda_escalation',
        'Protocolo de Cartorio pendente ha 24 horas',
        entry.observation,
        '/agenda',
        jsonb_build_object('agendaId', entry.id)
      );
    end if;

    update public.crm_agenda_entries
    set protocol_vitor_notified_at = now()
    where id = entry.id;
  end loop;
end;
$$;

revoke all on function public.process_agenda_notifications()
  from public, anon, authenticated;
grant execute on function public.process_agenda_notifications() to service_role;

-- A cobranca horaria de digitalizacao respeita o expediente e nao acumula
-- repeticoes noturnas. O escalonamento de 24 horas ao admin permanece exato.
create or replace function public.process_agenda_cartorio_vitor_document_notifications()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  entry record;
  vitor uuid;
  notification_body text;
begin
  select id into vitor
  from public.profiles
  where lower(email) = 'unassigned-operator@example.invalid'
  limit 1;

  if vitor is not null and public.crm_is_business_hours(now()) then
    for entry in
      select *
      from public.crm_agenda_entries
      where category = 'cartorio'
        and cartorio_delivered_to_vitor_at is not null
        and cartorio_vitor_tracking_started_at is not null
        and jsonb_array_length(coalesce(cartorio_vitor_document_paths, '[]'::jsonb)) = 0
        and cartorio_vitor_tracking_started_at + interval '1 hour' <= now()
        and (
          cartorio_vitor_document_last_reminder_at is null
          or cartorio_vitor_document_last_reminder_at + interval '1 hour' <= now()
        )
      for update skip locked
    loop
      notification_body := 'Digitalize e anexe o documento do cliente '
        || coalesce(nullif(entry.cartorio_client_name, ''), 'nao informado')
        || '. Entregue por Derley em '
        || to_char(
          entry.cartorio_delivered_to_vitor_at at time zone 'America/Sao_Paulo',
          'DD/MM/YYYY HH24:MI'
        ) || '.';

      insert into public.crm_notification_outbox(
        recipient_id, kind, title, body, url, payload
      ) values (
        vitor,
        'agenda_cartorio_vitor_document_reminder',
        'Documento de Cartorio aguardando digitalizacao',
        notification_body,
        '/agenda',
        jsonb_build_object('agendaId', entry.id)
      );

      update public.crm_agenda_entries
      set cartorio_vitor_document_last_reminder_at = now()
      where id = entry.id;
    end loop;
  end if;

  for entry in
    select *
    from public.crm_agenda_entries
    where category = 'cartorio'
      and cartorio_delivered_to_vitor_at is not null
      and cartorio_vitor_tracking_started_at is not null
      and jsonb_array_length(coalesce(cartorio_vitor_document_paths, '[]'::jsonb)) = 0
      and cartorio_vitor_tracking_started_at + interval '24 hours' <= now()
      and cartorio_vitor_document_admin_notified_at is null
    for update skip locked
  loop
    notification_body := 'Vitor ainda nao anexou o documento digitalizado do cliente '
      || coalesce(nullif(entry.cartorio_client_name, ''), 'nao informado')
      || ', entregue por Derley ha 24 horas.';

    insert into public.crm_notification_outbox(
      recipient_id, kind, title, body, url, payload
    )
    select
      id,
      'agenda_cartorio_vitor_document_overdue',
      'Digitalizacao de Cartorio pendente ha 24 horas',
      notification_body,
      '/agenda',
      jsonb_build_object('agendaId', entry.id)
    from public.profiles
    where role = 'admin';

    update public.crm_agenda_entries
    set cartorio_vitor_document_admin_notified_at = now()
    where id = entry.id;
  end loop;
end;
$$;

revoke all on function public.process_agenda_cartorio_vitor_document_notifications()
  from public, anon, authenticated;
grant execute on function public.process_agenda_cartorio_vitor_document_notifications()
  to service_role;

comment on column public.crm_notification_outbox.available_at is
  'Instante em que a notificacao pode aparecer no inbox e ser enviada por push.';

comment on table public.crm_notification_delivery_policies is
  'Matriz central de notificacoes imediatas e restritas ao expediente 08:00-19:00 America/Sao_Paulo.';

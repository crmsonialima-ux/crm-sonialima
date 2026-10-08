begin;

-- Atualizar start_lead_assignment (15 min)
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
    15
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
    'Voce tem 15 minutos uteis para iniciar o atendimento de ' || new.name || '.',
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

-- Atualizar normalize_lead_assignment_attempt_schedule (15/5 min)
create or replace function public.normalize_lead_assignment_attempt_schedule()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  duration_minutes integer := case when new.attempt_number = 1 then 15 else 5 end;
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

-- Atualizar process_expired_lead_assignments (15/5 min)
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
    update public.lead_assignment_attempts as attempt
    set expired_at = now()
    where attempt.lead_id = lead_row.id
      and attempt.broker_id = lead_row.owner_id
      and attempt.run_number = lead_row.assignment_run_number
      and attempt.expired_at is null
      and attempt.accepted_at is null;

    current_run := coalesce(lead_row.assignment_run_number, 1);
    select coalesce(max(attempt_number), 0)
    into attempt_count
    from public.lead_assignment_attempts
    where lead_id = lead_row.id
      and run_number = current_run;

    select round_number
    into current_round
    from public.lead_assignment_attempts
    where lead_id = lead_row.id
      and run_number = current_run
    order by attempt_number desc
    limit 1;
    current_round := coalesce(current_round, 1::smallint);

    if lead_row.property_catalog_id is null then
      select queue.broker_id, profile.full_name, profile.email
      into next_broker_id, next_broker_name, next_broker_email
      from public.lead_distribution_queue as queue
      join public.profiles as profile on profile.id = queue.broker_id
      where queue.lead_type = lead_row.lead_type
        and profile.role = 'broker'
        and not coalesce(profile.lead_distribution_blocked, false)
        and (profile.lead_distribution_blocked_until is null or profile.lead_distribution_blocked_until <= now())
        and not exists (
          select 1
          from public.lead_assignment_attempts as attempt
          where attempt.lead_id = lead_row.id
            and attempt.run_number = current_run
            and attempt.round_number = current_round
            and attempt.broker_id = queue.broker_id
        )
      order by queue.position
      limit 1
      for update of queue skip locked;
    else
      select queue.broker_id, profile.full_name, profile.email
      into next_broker_id, next_broker_name, next_broker_email
      from public.crm_property_broker_access as access
      join public.lead_distribution_queue as queue
        on queue.broker_id = access.broker_id
       and queue.lead_type = lead_row.lead_type
      join public.profiles as profile on profile.id = access.broker_id
      where access.property_id = lead_row.property_catalog_id
        and profile.role = 'broker'
        and not coalesce(profile.lead_distribution_blocked, false)
        and (profile.lead_distribution_blocked_until is null or profile.lead_distribution_blocked_until <= now())
        and not exists (
          select 1
          from public.lead_assignment_attempts as attempt
          where attempt.lead_id = lead_row.id
            and attempt.run_number = current_run
            and attempt.round_number = current_round
            and attempt.broker_id = access.broker_id
        )
      order by queue.position
      limit 1
      for update of queue skip locked;
    end if;

    if next_broker_id is null and current_round = 1 then
      current_round := 2;

      if lead_row.property_catalog_id is null then
        select queue.broker_id, profile.full_name, profile.email
        into next_broker_id, next_broker_name, next_broker_email
        from public.lead_distribution_queue as queue
        join public.profiles as profile on profile.id = queue.broker_id
        where queue.lead_type = lead_row.lead_type
          and profile.role = 'broker'
          and not coalesce(profile.lead_distribution_blocked, false)
          and (profile.lead_distribution_blocked_until is null or profile.lead_distribution_blocked_until <= now())
          and not exists (
            select 1
            from public.lead_assignment_attempts as attempt
            where attempt.lead_id = lead_row.id
              and attempt.run_number = current_run
              and attempt.round_number = current_round
              and attempt.broker_id = queue.broker_id
          )
        order by queue.position
        limit 1
        for update of queue skip locked;
      else
        select queue.broker_id, profile.full_name, profile.email
        into next_broker_id, next_broker_name, next_broker_email
        from public.crm_property_broker_access as access
        join public.lead_distribution_queue as queue
          on queue.broker_id = access.broker_id
         and queue.lead_type = lead_row.lead_type
        join public.profiles as profile on profile.id = access.broker_id
        where access.property_id = lead_row.property_catalog_id
          and profile.role = 'broker'
          and not coalesce(profile.lead_distribution_blocked, false)
          and (profile.lead_distribution_blocked_until is null or profile.lead_distribution_blocked_until <= now())
          and not exists (
            select 1
            from public.lead_assignment_attempts as attempt
            where attempt.lead_id = lead_row.id
              and attempt.run_number = current_run
              and attempt.round_number = current_round
              and attempt.broker_id = access.broker_id
          )
        order by queue.position
        limit 1
        for update of queue skip locked;
      end if;
    end if;

    timeout_message := case
      when lead_row.assignment_status = 'pending' then 'Prazo de aceite expirado'
      when lead_row.assignment_status = 'accepted' and lead_row.stage = 'Em atendimento' then 'Atraso no atendimento'
      else 'Prazo esgotado'
    end;

    if next_broker_id is null then
      update public.crm_leads as l
      set assignment_status = 'exhausted',
          assignment_deadline_at = null,
          assignment_available_at = null,
          assignment_reminder_sent_at = null,
          stage = 'Aguardando redistribuicao pelo Allyson'
      where l.id = lead_row.id;

      source_label := coalesce(
        nullif(lead_row.channel, ''),
        nullif(lead_row.external_id, ''),
        'Origem manual'
      );
      insert into public.crm_lead_activities(lead_id, stage, note, author_name)
      values(
        lead_row.id,
        'Distribuicao esgotada',
        timeout_message || '. Nao ha mais corretores elegiveis. Aguardando Allyson.',
        'Sistema'
      );
      insert into public.crm_notification_outbox(recipient_id, kind, title, body, url, payload)
      select
        p.id,
        'lead_assignment_exhausted',
        'Lead esgotado na distribuicao',
        lead_row.name || ' (' || source_label || ') passou por todos os corretores e retornou para a gerencia.',
        '/leads',
        jsonb_build_object('leadId', lead_row.id)
      from public.profiles as p
      where lower(trim(p.email)) in ('crmsoniaallyson@gmail.com', 'unassigned-institutional@example.invalid');
      continue;
    end if;

    select coalesce(max(position), 0) + 1
    into next_position
    from public.lead_distribution_queue
    where lead_type = lead_row.lead_type;

    update public.lead_distribution_queue
    set position = next_position, updated_at = now()
    where lead_type = lead_row.lead_type and broker_id = next_broker_id;

    next_attempt_number := attempt_count + 1;
    next_duration_minutes := case
      when next_attempt_number = 1 then 15
      else 5
    end;
    next_available_at := public.crm_next_lead_queue_moment(now());
    next_deadline_at := public.crm_add_lead_queue_minutes(next_available_at, next_duration_minutes);

    update public.crm_leads as l
    set owner_id = next_broker_id,
        assignment_status = 'pending',
        assignment_available_at = next_available_at,
        assignment_deadline_at = next_deadline_at,
        assignment_reminder_sent_at = null,
        stage = 'Aguardando atendimento'
    where l.id = lead_row.id;

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

    insert into public.crm_lead_activities(lead_id, stage, note, author_name)
    values(
      lead_row.id,
      'Lead redistribuido',
      timeout_message || '. Distribuido para ' || coalesce(nullif(next_broker_name, ''), next_broker_email) || ' (' || next_duration_minutes || ' min uteis).',
      'Sistema'
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
      'Novo lead aguardando atendimento',
      'Voce tem ' || next_duration_minutes || ' minutos uteis para iniciar o atendimento de ' || lead_row.name || '.',
      '/leads',
      jsonb_build_object(
        'leadId', lead_row.id,
        'phone', lead_row.phone,
        'name', lead_row.name,
        'attemptNumber', next_attempt_number,
        'runNumber', current_run,
        'roundNumber', current_round,
        'availableAt', next_available_at,
        'deadlineAt', next_deadline_at
      ),
      next_available_at
    );
  end loop;
end;
$$;

-- Atualizar restart_exhausted_lead_queue (15 min)
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
  deadline_at := public.crm_add_lead_queue_minutes(available_at, 15);

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
    'Voce tem 15 minutos uteis para iniciar o atendimento de '
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
      || ' da esteira, com ate duas rodadas e primeiro prazo de 15 minutos uteis.',
    auth.uid(),
    'crmallyson'
  );

  return coalesce(nullif(next_broker_name, ''), next_broker_email);
end;
$$;

commit;

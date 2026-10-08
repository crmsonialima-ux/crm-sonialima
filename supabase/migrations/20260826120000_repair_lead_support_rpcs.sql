begin;

create or replace function public.create_lead_with_phones(
  p_name text,
  p_phone text,
  p_additional_phones text[],
  p_email text,
  p_property_interest text,
  p_stage text,
  p_channel text,
  p_notes text,
  p_lead_type text,
  p_desired_property_value numeric,
  p_desired_location text,
  p_visit_scheduled_at timestamptz default null
)
returns table (lead_id uuid, assigned_owner_id uuid, assigned_owner_name text)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  current_profile public.profiles%rowtype;
  created_lead_id uuid;
  created_owner_id uuid;
  created_owner_name text;
begin
  if auth.uid() is null then raise exception 'Sessao nao encontrada.'; end if;

  select profile.* into current_profile
  from public.profiles as profile where profile.id = auth.uid();
  if not found then raise exception 'Perfil nao encontrado.'; end if;

  if public.is_allyson_admin() then
    if p_visit_scheduled_at is not null then
      select result.lead_id, result.assigned_owner_id, result.assigned_owner_name
      into created_lead_id, created_owner_id, created_owner_name
      from public.create_scheduled_visit_lead(
        p_name, p_phone, p_email, p_property_interest, p_channel, p_notes,
        p_lead_type, p_desired_property_value, p_desired_location, null,
        p_visit_scheduled_at
      ) as result;
    else
      select result.lead_id, result.assigned_owner_id, result.assigned_owner_name
      into created_lead_id, created_owner_id, created_owner_name
      from public.create_distributed_lead(
        p_name, p_phone, p_email, p_property_interest, p_stage, p_channel,
        p_notes, '', p_lead_type, p_desired_property_value, p_desired_location
      ) as result;
    end if;
  elsif current_profile.role = 'broker' then
    select result.lead_id, result.assigned_owner_id, result.assigned_owner_name
    into created_lead_id, created_owner_id, created_owner_name
    from public.create_creator_owned_lead(
      p_name, p_phone, p_email, p_property_interest, p_stage, p_channel,
      p_notes, p_lead_type, p_desired_property_value, p_desired_location, null
    ) as result;
  elsif public.is_restricted_admin() then
    if p_lead_type not in ('Venda', 'Aluguel') then raise exception 'Tipo de lead invalido.'; end if;
    if coalesce(p_desired_property_value, 0) <= 0 then raise exception 'Informe o valor medio do imovel desejado.'; end if;
    if nullif(trim(p_desired_location), '') is null then raise exception 'Informe a localizacao desejada.'; end if;

    insert into public.crm_leads (
      name, phone, email, property_interest, stage, channel, budget, notes,
      owner_id, created_by, lead_type, desired_property_value, desired_location,
      assignment_status, assignment_deadline_at
    ) values (
      trim(p_name), nullif(trim(p_phone), ''), nullif(trim(p_email), ''),
      nullif(trim(p_property_interest), ''), 'Em atendimento', nullif(trim(p_channel), ''),
      0, nullif(trim(p_notes), ''), auth.uid(), auth.uid(), p_lead_type,
      p_desired_property_value, trim(p_desired_location), 'accepted', null
    ) returning id into created_lead_id;

    update public.crm_leads as saved_lead
    set stage = 'Em atendimento', assignment_status = 'accepted', assignment_deadline_at = null
    where saved_lead.id = created_lead_id;

    delete from public.lead_assignment_attempts as attempt
    where attempt.lead_id = created_lead_id;
    delete from public.crm_notification_outbox as notification
    where notification.kind = 'lead_assignment'
      and notification.payload ->> 'leadId' = created_lead_id::text;

    created_owner_id := current_profile.id;
    created_owner_name := coalesce(nullif(current_profile.full_name, ''), current_profile.email);
  else
    raise exception 'Perfil sem permissao para cadastrar lead.';
  end if;

  if created_lead_id is null then raise exception 'Nao foi possivel cadastrar o lead.'; end if;

  update public.crm_leads as saved_lead
  set additional_phones = coalesce(p_additional_phones, '{}'::text[])
  where saved_lead.id = created_lead_id;

  return query select created_lead_id, created_owner_id, created_owner_name;
end;
$$;

revoke all on function public.create_lead_with_phones(
  text, text, text[], text, text, text, text, text, text, numeric, text, timestamptz
) from public, anon;
grant execute on function public.create_lead_with_phones(
  text, text, text[], text, text, text, text, text, text, numeric, text, timestamptz
) to authenticated;

create or replace function public.crm_restart_match_lead_queue(p_lead_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  lead_row public.crm_leads%rowtype;
  selected_broker_id uuid;
  next_position integer;
  run_number integer;
  available_at timestamptz;
  deadline_at timestamptz;
begin
  select lead.* into lead_row
  from public.crm_leads as lead where lead.id = p_lead_id for update;
  if not found then return; end if;

  perform pg_advisory_xact_lock(hashtext('lead-distribution:' || lead_row.lead_type));

  select queue.broker_id into selected_broker_id
  from public.lead_distribution_queue as queue
  join public.profiles as profile on profile.id = queue.broker_id
  where queue.lead_type = lead_row.lead_type
    and (
      profile.role = 'broker'
      or (queue.lead_type = 'Venda' and lower(trim(profile.email)) = 'unassigned-institutional@example.invalid')
    )
    and not coalesce(profile.lead_distribution_blocked, false)
    and (profile.lead_distribution_blocked_until is null or profile.lead_distribution_blocked_until <= now())
    and (
      not exists (
        select 1 from public.crm_property_match_notifications as match
        where match.lead_id = lead_row.id
      )
      or exists (
        select 1
        from public.crm_property_match_notifications as match
        join public.crm_property_broker_access as access
          on access.property_id = match.property_external_id
         and access.broker_id = queue.broker_id
        where match.lead_id = lead_row.id
      )
    )
  order by queue.position
  limit 1
  for update of queue skip locked;

  if selected_broker_id is null then
    update public.crm_leads
    set assignment_status = 'exhausted', assignment_deadline_at = null
    where id = p_lead_id;
    return;
  end if;

  select coalesce(max(queue.position), 0) + 1 into next_position
  from public.lead_distribution_queue as queue
  where queue.lead_type = lead_row.lead_type;

  update public.lead_distribution_queue as queue
  set position = next_position, updated_at = now()
  where queue.lead_type = lead_row.lead_type
    and queue.broker_id = selected_broker_id;

  run_number := greatest(coalesce(lead_row.assignment_run_number, 1), 1) + 1;
  available_at := public.crm_next_lead_queue_moment(now());
  deadline_at := public.crm_add_lead_queue_minutes(available_at, 20);

  update public.crm_leads
  set owner_id = selected_broker_id,
      stage = 'Aguardando atendimento',
      assignment_status = 'pending',
      assignment_available_at = available_at,
      assignment_deadline_at = deadline_at,
      assignment_run_number = run_number,
      assignment_reminder_sent_at = null,
      updated_at = now()
  where id = p_lead_id;

  insert into public.lead_assignment_attempts (
    lead_id, broker_id, attempt_number, run_number, round_number, notified_at, deadline_at
  ) values (p_lead_id, selected_broker_id, 1, run_number, 1, available_at, deadline_at);

  insert into public.crm_notification_outbox (
    recipient_id, kind, title, body, url, payload, available_at
  ) values (
    selected_broker_id, 'lead_assignment', 'Lead retornou a esteira',
    'O prazo da oferta de imovel similar terminou. O lead voltou para a esteira com os imoveis sugeridos anexados.',
    '/leads?focusLeadId=' || p_lead_id,
    jsonb_build_object('leadId', p_lead_id, 'runNumber', run_number, 'roundNumber', 1,
      'availableAt', available_at, 'deadlineAt', deadline_at, 'similarPropertiesAttached', true),
    available_at
  );
end;
$$;

revoke all on function public.crm_restart_match_lead_queue(uuid) from public, anon, authenticated;

create or replace function public.allyson_release_scheduled_lead(p_lead_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  lead_row public.crm_leads%rowtype;
  target_deadline timestamptz;
  actor_name text;
begin
  if not public.is_allyson_admin() then
    raise exception 'Apenas Allyson pode antecipar leads programados.';
  end if;

  select lead.* into lead_row
  from public.crm_leads as lead where lead.id = p_lead_id for update;
  if not found then raise exception 'Lead nao encontrado.'; end if;
  if lead_row.assignment_available_at is null or lead_row.assignment_available_at <= now() then
    raise exception 'O lead nao esta programado para o futuro.';
  end if;

  select coalesce(nullif(profile.full_name, ''), profile.email)
  into actor_name from public.profiles as profile where profile.id = auth.uid();
  target_deadline := public.crm_add_lead_queue_minutes(now(), 20);

  update public.crm_leads
  set assignment_available_at = now(), assignment_deadline_at = target_deadline
  where id = p_lead_id;

  insert into public.crm_lead_activities (lead_id, stage, note, author_id, author_name)
  values (
    p_lead_id, lead_row.stage,
    'Liberou antecipadamente a distribuicao do lead programado.',
    auth.uid(), coalesce(actor_name, 'Allyson')
  );

  update public.lead_assignment_attempts
  set notified_at = now(), deadline_at = target_deadline
  where lead_id = p_lead_id and attempt_number = 1 and run_number = 1;

  update public.crm_notification_outbox
  set available_at = now(),
      payload = jsonb_set(
        jsonb_set(coalesce(payload, '{}'::jsonb), '{availableAt}', to_jsonb(now()::timestamptz)),
        '{deadlineAt}', to_jsonb(target_deadline)
      )
  where kind = 'lead_assignment'
    and payload ->> 'leadId' = p_lead_id::text
    and payload ->> 'attemptNumber' = '1';
end;
$$;

revoke all on function public.allyson_release_scheduled_lead(uuid) from public, anon, authenticated;
grant execute on function public.allyson_release_scheduled_lead(uuid) to authenticated;

create or replace function public.set_property_capturer(p_property_id text, p_broker_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.can_manage_property_brokers() then
    raise exception 'Somente Allyson e acesso CRM podem selecionar os captadores.';
  end if;
  if p_broker_id is null then
    delete from public.crm_property_capturer_assignments
    where property_id = nullif(trim(p_property_id), '');
    return;
  end if;
  perform public.set_property_capturers(p_property_id, array[p_broker_id::text]);
end;
$$;

create or replace function public.set_property_capturer_selection(p_property_id text, p_selection text)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.can_manage_property_brokers() then
    raise exception 'Somente Allyson e acesso CRM podem selecionar os captadores.';
  end if;
  if nullif(trim(p_selection), '') is null then
    delete from public.crm_property_capturer_assignments
    where property_id = nullif(trim(p_property_id), '');
    return;
  end if;
  perform public.set_property_capturers(p_property_id, array[trim(p_selection)]);
end;
$$;

revoke all on function public.set_property_capturer(text, uuid) from public, anon;
revoke all on function public.set_property_capturer_selection(text, text) from public, anon;
grant execute on function public.set_property_capturer(text, uuid) to authenticated;
grant execute on function public.set_property_capturer_selection(text, text) to authenticated;

commit;

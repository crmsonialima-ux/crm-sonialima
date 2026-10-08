begin;

-- Leads from the new website use the Site channel while retaining link_bio as
-- the established public-intake source portal.
create or replace function public.refresh_portal_lead_registration_fields()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  missing_fields text[] := array[]::text[];
  expected_channel text;
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
  if new.property_catalog_id is null
     or nullif(trim(coalesce(new.property_interest, '')), '') is null then
    missing_fields := array_append(missing_fields, 'property_interest');
  end if;
  if new.lead_type is null or new.lead_type not in ('Venda', 'Aluguel') then
    missing_fields := array_append(missing_fields, 'lead_type');
  end if;

  expected_channel := case new.source_portal
    when 'wimoveis' then 'W Imóveis'
    when 'dfimoveis' then 'DF Imóveis'
    when 'link_bio' then case
      when coalesce(new.external_id, '') like 'site-%' then 'Site'
      else 'Link da bio'
    end
    else null
  end;
  if expected_channel is not null and new.channel is distinct from expected_channel then
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
    new.registration_completed_at := case when tg_op = 'INSERT'
      then coalesce(new.registration_completed_at, now())
      else coalesce(old.registration_completed_at, now()) end;
  else
    new.registration_completed_at := null;
  end if;
  return new;
end;
$$;

-- A validated financing lead is delivered directly to Vitor. It never gets a
-- queue attempt, cannot be redistributed, and starts the normal qualification.
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
  direct_financing boolean := false;
begin
  direct_financing := new.source_portal = 'link_bio'
    and new.channel = 'Site'
    and new.property_interest = 'Financiamento Caixa'
    and coalesce(new.external_id, '') like 'site-financing-%'
    and exists (
      select 1
      from public.profiles profile
      where profile.id = new.owner_id
        and profile.role = 'broker'
        and lower(trim(profile.email)) = 'unassigned-operator@example.invalid'
    );

  if direct_financing then
    update public.crm_leads lead
    set assignment_status = 'accepted',
        assignment_available_at = null,
        assignment_deadline_at = now() + interval '24 hours',
        assignment_run_number = 1,
        assignment_reminder_sent_at = null,
        stage = 'Em atendimento',
        post_acceptance_qualification_deadline_at = now() + interval '2 hours',
        post_acceptance_qualification_completed_at = null,
        post_acceptance_qualification_expired_at = null
    where lead.id = new.id;

    insert into public.crm_notification_outbox(
      recipient_id, kind, title, body, url, payload, available_at
    ) values (
      new.owner_id,
      'lead_direct_assignment',
      'Novo lead de Financiamento Caixa',
      'Um lead do site foi atribuído diretamente a você. Faça a qualificação obrigatória.',
      '/leads?focusLeadId=' || new.id,
      jsonb_build_object(
        'leadId', new.id,
        'source', 'site_sonialima_imoveis',
        'routingMode', 'fixed_owner',
        'assignedOwner', 'crmvitor',
        'assignedDirectly', true
      ),
      now()
    );
    return new;
  end if;

  select settings.defer_new_leads_to_next_day_nine
  into defer_until_tomorrow
  from public.crm_operational_settings settings
  where settings.singleton;

  target_available_at := case
    when coalesce(defer_until_tomorrow, false)
      then public.crm_next_calendar_day_nine(now())
    else public.crm_next_lead_queue_moment(now())
  end;
  target_deadline_at := public.crm_add_lead_queue_minutes(target_available_at, 15);

  update public.crm_leads lead
  set assignment_status = 'pending',
      assignment_available_at = target_available_at,
      assignment_deadline_at = target_deadline_at,
      assignment_run_number = 1,
      assignment_reminder_sent_at = null,
      stage = 'Aguardando atendimento'
  where lead.id = new.id;

  insert into public.lead_assignment_attempts(
    lead_id, broker_id, attempt_number, run_number, round_number, notified_at, deadline_at
  ) values (
    new.id, new.owner_id, 1, 1, 1, target_available_at, target_deadline_at
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

revoke all on function public.start_lead_assignment() from public, anon, authenticated;

create or replace function public.create_public_bio_lead(
  p_name text,
  p_phone text,
  p_email text,
  p_property_interest text,
  p_lead_type text,
  p_request_fingerprint text,
  p_contract_version text,
  p_source text,
  p_page_url text,
  p_routing_mode text,
  p_assigned_owner text
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  normalized_name text := trim(coalesce(p_name, ''));
  normalized_phone text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  normalized_email text := lower(trim(coalesce(p_email, '')));
  normalized_interest text := trim(coalesce(p_property_interest, ''));
  normalized_type text := trim(coalesce(p_lead_type, ''));
  normalized_source text := trim(coalesce(p_source, ''));
  normalized_page_url text := trim(coalesce(p_page_url, ''));
  normalized_routing text := trim(coalesce(p_routing_mode, ''));
  normalized_owner text := nullif(lower(trim(coalesce(p_assigned_owner, ''))), '');
  fingerprint text := trim(coalesce(p_request_fingerprint, ''));
  is_fixed_financing boolean := false;
  next_broker record;
  next_position integer;
  allyson_id uuid;
  target_owner_id uuid;
  target_owner_name text;
  inserted_lead uuid;
  metadata_note text;
begin
  if current_user not in ('service_role', 'postgres', 'supabase_admin') then
    raise exception 'Acesso não autorizado.';
  end if;
  if p_contract_version is distinct from '1.0' then
    raise exception 'Versão do contrato inválida.';
  end if;
  if char_length(normalized_name) not between 2 and 120 or normalized_name ~ '[[:cntrl:]]' then
    raise exception 'Nome inválido.';
  end if;
  if left(normalized_phone, 2) = '55' and char_length(normalized_phone) in (12, 13) then
    normalized_phone := substring(normalized_phone from 3);
  end if;
  if char_length(normalized_phone) not in (10, 11) then
    raise exception 'Telefone inválido.';
  end if;
  if char_length(normalized_email) > 254
     or (normalized_email <> '' and normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') then
    raise exception 'E-mail inválido.';
  end if;
  if normalized_type not in ('Venda', 'Aluguel') then
    raise exception 'Tipo de interesse inválido.';
  end if;
  if char_length(normalized_interest) not between 2 and 160 or normalized_interest ~ '[[:cntrl:]]' then
    raise exception 'Interesse inválido.';
  end if;
  if normalized_source <> 'site_sonialima_imoveis' then
    raise exception 'Origem inválida.';
  end if;
  if char_length(normalized_page_url) not between 10 and 500
     or normalized_page_url !~ '^https://(sonialima-imoveis\.pages\.dev|contatosonialima\.netlify\.app|contato\.crmsonialimaimoveis\.online)(/|$)' then
    raise exception 'Página de origem inválida.';
  end if;
  if normalized_routing not in ('fixed_owner', 'round_robin') then
    raise exception 'Roteamento inválido.';
  end if;
  if normalized_owner is not null and normalized_owner <> 'crmvitor' then
    raise exception 'Responsável solicitado não permitido.';
  end if;
  if char_length(fingerprint) < 32 then
    raise exception 'Requisição inválida.';
  end if;

  is_fixed_financing := normalized_interest = 'Financiamento Caixa'
    and normalized_routing = 'fixed_owner'
    and normalized_owner = 'crmvitor';
  if not is_fixed_financing
     and not (
       normalized_interest <> 'Financiamento Caixa'
       and normalized_routing = 'round_robin'
       and normalized_owner is null
     ) then
    raise exception 'Combinação de interesse e roteamento inválida.';
  end if;

  perform pg_advisory_xact_lock(hashtext('bio-intake:' || fingerprint));
  if (select count(*) from public.crm_public_lead_intake_requests request
      where request.request_fingerprint = fingerprint
        and request.created_at > now() - interval '1 hour') >= 5 then
    raise exception 'Muitas tentativas. Aguarde uma hora e tente novamente.';
  end if;

  perform pg_advisory_xact_lock(hashtext('lead-phone:' || normalized_phone));
  if exists (
    select 1 from public.crm_leads lead
    where public.normalize_crm_phone_identity(lead.phone) = normalized_phone
  ) then
    raise exception 'Este telefone já possui atendimento cadastrado. Nossa equipe entrará em contato.';
  end if;

  select profile.id into allyson_id
  from public.profiles profile
  where lower(trim(profile.email)) = 'crmsoniaallyson@gmail.com'
  limit 1;
  if allyson_id is null then raise exception 'Responsável administrativo não encontrado.'; end if;

  if is_fixed_financing then
    select profile.id, coalesce(nullif(profile.full_name, ''), profile.email)
    into target_owner_id, target_owner_name
    from public.profiles profile
    where lower(trim(profile.email)) = 'unassigned-operator@example.invalid'
      and profile.role = 'broker'
    limit 1;
    if target_owner_id is null then raise exception 'Responsável crmvitor não encontrado.'; end if;
  else
    perform pg_advisory_xact_lock(hashtext('lead-distribution:' || normalized_type));
    select queue.broker_id, profile.full_name, profile.email
    into next_broker
    from public.lead_distribution_queue queue
    join public.profiles profile on profile.id = queue.broker_id
    where queue.lead_type = normalized_type
      and not coalesce(profile.lead_distribution_blocked, false)
      and (
        profile.role = 'broker'
        or (normalized_type = 'Venda' and lower(trim(profile.email)) = 'unassigned-institutional@example.invalid')
      )
    order by queue.position
    limit 1
    for update of queue skip locked;
    if next_broker.broker_id is null then
      raise exception 'Não há corretores disponíveis na fila de %.', normalized_type;
    end if;

    target_owner_id := next_broker.broker_id;
    target_owner_name := coalesce(nullif(next_broker.full_name, ''), next_broker.email);
    select coalesce(max(queue.position), 0) + 1 into next_position
    from public.lead_distribution_queue queue where queue.lead_type = normalized_type;
    update public.lead_distribution_queue queue
    set position = next_position, updated_at = now()
    where queue.lead_type = normalized_type and queue.broker_id = target_owner_id;
  end if;

  metadata_note := 'Origem: ' || normalized_source
    || E'\nPágina: ' || normalized_page_url
    || E'\nContrato: ' || p_contract_version
    || E'\nRoteamento: ' || normalized_routing
    || E'\nResponsável solicitado: ' || coalesce(normalized_owner, '(automático)');

  insert into public.crm_leads (
    name, phone, email, property_interest, property_catalog_id, stage, channel,
    budget, notes, owner_id, created_by, external_id, lead_type,
    desired_property_value, desired_location, source_portal,
    commercial_qualification_required
  ) values (
    normalized_name, normalized_phone, nullif(normalized_email, ''), normalized_interest,
    null, 'Aguardando atendimento', 'Site', 0,
    'Cadastro automático pelo site SoniaLima.' || E'\n' || metadata_note,
    target_owner_id, allyson_id,
    case when is_fixed_financing then 'site-financing-' else 'site-' end || gen_random_uuid()::text,
    normalized_type, null, null, 'link_bio', true
  ) returning id into inserted_lead;

  insert into public.crm_public_lead_intake_requests(request_fingerprint, lead_id)
  values (fingerprint, inserted_lead);

  insert into public.crm_lead_activities(lead_id, stage, note, author_id, author_name)
  values (
    inserted_lead,
    'Lead recebido pelo site',
    'Interesse: ' || normalized_interest || E'\n' || metadata_note
      || E'\nDestino interno: ' || target_owner_name,
    allyson_id,
    'Integração Site SoniaLima'
  );

  insert into public.crm_notification_outbox(
    recipient_id, kind, title, body, url, payload, available_at
  ) values (
    allyson_id,
    'bio_lead_incomplete',
    'Novo lead do site SoniaLima',
    normalized_name || ' enviou o interesse "' || normalized_interest || '" pelo site.',
    '/leads?focusLeadId=' || inserted_lead,
    jsonb_build_object(
      'leadId', inserted_lead,
      'name', normalized_name,
      'phone', normalized_phone,
      'email', nullif(normalized_email, ''),
      'interest', normalized_interest,
      'leadType', normalized_type,
      'source', normalized_source,
      'pageUrl', normalized_page_url,
      'routingMode', normalized_routing,
      'assignedOwner', normalized_owner,
      'fixedOwnerApplied', is_fixed_financing
    ),
    now()
  );

  return inserted_lead;
end;
$$;

revoke all on function public.create_public_bio_lead(
  text, text, text, text, text, text, text, text, text, text, text
) from public, anon, authenticated;
grant execute on function public.create_public_bio_lead(
  text, text, text, text, text, text, text, text, text, text, text
) to service_role;

commit;

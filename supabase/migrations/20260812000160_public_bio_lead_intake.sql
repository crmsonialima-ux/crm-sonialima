begin;

alter table public.crm_leads
  drop constraint if exists crm_leads_source_portal_check;
alter table public.crm_leads
  add constraint crm_leads_source_portal_check
  check (source_portal in ('wimoveis', 'dfimoveis', 'link_bio'));

create table if not exists public.crm_public_lead_intake_requests (
  id uuid primary key default gen_random_uuid(),
  request_fingerprint text not null,
  lead_id uuid references public.crm_leads(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists crm_public_lead_intake_requests_rate_idx
  on public.crm_public_lead_intake_requests(request_fingerprint, created_at desc);

alter table public.crm_public_lead_intake_requests enable row level security;
revoke all on public.crm_public_lead_intake_requests from public, anon, authenticated;

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
    when 'link_bio' then 'Link da bio'
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

create or replace function public.create_public_bio_lead(
  p_name text,
  p_phone text,
  p_lead_type text,
  p_request_fingerprint text
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  normalized_name text := trim(coalesce(p_name, ''));
  normalized_phone text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  normalized_type text := trim(coalesce(p_lead_type, ''));
  fingerprint text := trim(coalesce(p_request_fingerprint, ''));
  next_broker record;
  next_position integer;
  allyson_id uuid;
  inserted_lead uuid;
begin
  if current_user not in ('service_role', 'postgres', 'supabase_admin') then
    raise exception 'Acesso não autorizado.';
  end if;
  if char_length(normalized_name) not between 2 and 120 then
    raise exception 'Informe um nome válido.';
  end if;
  if left(normalized_phone, 2) = '55' and char_length(normalized_phone) in (12, 13) then
    normalized_phone := substring(normalized_phone from 3);
  end if;
  if char_length(normalized_phone) not in (10, 11) then
    raise exception 'Informe um telefone válido com DDD.';
  end if;
  if normalized_type not in ('Venda', 'Aluguel') then
    raise exception 'Selecione interesse em comprar ou alugar.';
  end if;
  if char_length(fingerprint) < 32 then
    raise exception 'Requisição inválida.';
  end if;

  perform pg_advisory_xact_lock(hashtext('bio-intake:' || fingerprint));
  if (select count(*) from public.crm_public_lead_intake_requests r
      where r.request_fingerprint = fingerprint
        and r.created_at > now() - interval '1 hour') >= 5 then
    raise exception 'Muitas tentativas. Aguarde uma hora e tente novamente.';
  end if;

  perform pg_advisory_xact_lock(hashtext('lead-phone:' || normalized_phone));
  if exists (
    select 1 from public.crm_leads l
    where public.normalize_crm_phone_identity(l.phone) = normalized_phone
  ) then
    raise exception 'Este telefone já possui atendimento cadastrado. Nossa equipe entrará em contato.';
  end if;

  select p.id into allyson_id
  from public.profiles p
  where lower(trim(p.email)) = 'crmsoniaallyson@gmail.com'
  limit 1;
  if allyson_id is null then
    raise exception 'Responsável administrativo não encontrado.';
  end if;

  perform pg_advisory_xact_lock(hashtext('lead-distribution:' || normalized_type));
  select q.broker_id, p.full_name, p.email
  into next_broker
  from public.lead_distribution_queue q
  join public.profiles p on p.id = q.broker_id
  where q.lead_type = normalized_type
    and not coalesce(p.lead_distribution_blocked, false)
    and (
      p.role = 'broker'
      or (normalized_type = 'Venda' and lower(trim(p.email)) = 'unassigned-institutional@example.invalid')
    )
  order by q.position
  limit 1
  for update of q skip locked;

  if next_broker.broker_id is null then
    raise exception 'Não há corretores disponíveis na fila de %.', normalized_type;
  end if;

  select coalesce(max(q.position), 0) + 1 into next_position
  from public.lead_distribution_queue q where q.lead_type = normalized_type;
  update public.lead_distribution_queue q
  set position = next_position, updated_at = now()
  where q.lead_type = normalized_type and q.broker_id = next_broker.broker_id;

  insert into public.crm_leads (
    name, phone, email, property_interest, property_catalog_id, stage, channel,
    budget, notes, owner_id, created_by, external_id, lead_type,
    desired_property_value, desired_location, source_portal,
    commercial_qualification_required
  ) values (
    normalized_name, normalized_phone, null, null, null, 'Aguardando atendimento',
    'Link da bio', 0,
    'Cadastro automático pelo link da bio. Complete o imóvel de interesse, o valor e a localização desejada.',
    next_broker.broker_id, allyson_id, 'bio-' || gen_random_uuid()::text,
    normalized_type, null, null, 'link_bio', true
  ) returning id into inserted_lead;

  insert into public.crm_public_lead_intake_requests(request_fingerprint, lead_id)
  values (fingerprint, inserted_lead);

  insert into public.crm_notification_outbox(
    recipient_id, kind, title, body, url, payload, available_at
  ) values (
    allyson_id,
    'bio_lead_incomplete',
    'Novo lead do link da bio',
    normalized_name || ' entrou na fila de ' || lower(normalized_type) ||
      '. Complete o imóvel de interesse, o valor e a localização.',
    '/leads?focusLeadId=' || inserted_lead,
    jsonb_build_object(
      'leadId', inserted_lead,
      'name', normalized_name,
      'phone', normalized_phone,
      'leadType', normalized_type,
      'missingFields', jsonb_build_array('property_interest', 'desired_property_value', 'desired_location')
    ),
    now()
  );

  return inserted_lead;
end;
$$;

revoke all on function public.create_public_bio_lead(text,text,text,text)
  from public, anon, authenticated;
grant execute on function public.create_public_bio_lead(text,text,text,text)
  to service_role;

commit;

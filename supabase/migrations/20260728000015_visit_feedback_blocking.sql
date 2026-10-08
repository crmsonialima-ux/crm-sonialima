-- Um corretor com retorno de visita pendente fica temporariamente fora das duas esteiras.
alter table public.profiles
  add column if not exists lead_distribution_blocked boolean not null default false,
  add column if not exists lead_distribution_blocked_reason text,
  add column if not exists lead_distribution_blocked_at timestamptz;

alter table public.crm_leads
  add column if not exists visit_feedback_at timestamptz,
  add column if not exists visit_started_notified_at timestamptz,
  add column if not exists visit_follow_up_notified_at timestamptz;

create or replace function public.refresh_broker_visit_block(p_broker_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare has_pending_feedback boolean;
begin
  select exists (
    select 1
    from public.crm_leads
    where owner_id = p_broker_id
      and visit_scheduled_at is not null
      and visit_scheduled_at <= now() - interval '2 hours'
      and visit_feedback_at is null
  ) into has_pending_feedback;

  update public.profiles
  set lead_distribution_blocked = has_pending_feedback,
      lead_distribution_blocked_reason = case
        when has_pending_feedback then 'Feedback de visita pendente há mais de 2 horas.'
        else null
      end,
      lead_distribution_blocked_at = case when has_pending_feedback then coalesce(lead_distribution_blocked_at, now()) else null end,
      updated_at = now()
  where id = p_broker_id;

  return has_pending_feedback;
end;
$$;

create or replace function public.record_visit_feedback_block_status()
returns trigger language plpgsql security definer set search_path = public as $$
declare lead_owner uuid;
begin
  if new.stage = 'Visita realizada' and nullif(trim(coalesce(new.note, '')), '') is not null then
    update public.crm_leads
    set visit_feedback_at = coalesce(visit_feedback_at, now())
    where id = new.lead_id
    returning owner_id into lead_owner;
    if lead_owner is not null then
      perform public.refresh_broker_visit_block(lead_owner);
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists crm_lead_activities_record_visit_feedback on public.crm_lead_activities;
create trigger crm_lead_activities_record_visit_feedback
after insert on public.crm_lead_activities
for each row execute procedure public.record_visit_feedback_block_status();

create or replace function public.refresh_visit_block_after_lead_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.owner_id is distinct from new.owner_id then
    perform public.refresh_broker_visit_block(old.owner_id);
  end if;
  perform public.refresh_broker_visit_block(new.owner_id);
  return new;
end;
$$;

drop trigger if exists crm_leads_refresh_visit_block on public.crm_leads;
create trigger crm_leads_refresh_visit_block
after update of visit_scheduled_at, owner_id, visit_feedback_at, stage on public.crm_leads
for each row execute procedure public.refresh_visit_block_after_lead_change();

create or replace function public.process_due_visit_notifications()
returns void language plpgsql security definer set search_path = public as $$
declare lead_row record;
begin
  for lead_row in
    select id, owner_id, name, property_interest, visit_scheduled_at,
      visit_started_notified_at, visit_follow_up_notified_at
    from public.crm_leads
    where stage = 'Visita agendada'
      and visit_scheduled_at is not null
      and visit_scheduled_at <= now()
      and (visit_started_notified_at is null or visit_follow_up_notified_at is null)
    for update skip locked
  loop
    if lead_row.visit_started_notified_at is null then
      update public.crm_leads set visit_started_notified_at = now() where id = lead_row.id;
      if lead_row.visit_scheduled_at > now() - interval '2 hours' then
        insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
        values (lead_row.owner_id, 'visit_started', 'Hora da visita',
          'A visita com ' || lead_row.name || ' começa agora. Depois, registre como foi a visita.',
          '/leads', jsonb_build_object('leadId', lead_row.id, 'name', lead_row.name));
      end if;
    end if;

    if lead_row.visit_follow_up_notified_at is null
       and lead_row.visit_scheduled_at <= now() - interval '2 hours' then
      update public.crm_leads set visit_follow_up_notified_at = now() where id = lead_row.id;
      perform public.refresh_broker_visit_block(lead_row.owner_id);
      insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
      values (lead_row.owner_id, 'visit_follow_up', 'Como foi a visita?',
        'Você ficou bloqueado temporariamente da fila até registrar o retorno da visita com ' || lead_row.name || '.',
        '/leads', jsonb_build_object('leadId', lead_row.id, 'name', lead_row.name));
    end if;
  end loop;
end;
$$;

-- A distribuição ignora corretores bloqueados, preservando a ordem dos demais.
create or replace function public.create_distributed_lead(
  p_name text, p_phone text, p_email text, p_property_interest text, p_stage text,
  p_channel text, p_notes text, p_external_id text, p_lead_type text
)
returns table (lead_id uuid, assigned_owner_id uuid, assigned_owner_name text)
language plpgsql security definer set search_path = public as $$
declare next_broker record; next_position integer; inserted_lead uuid; normalized_phone text;
begin
  if auth.uid() is null then raise exception 'Sessão não encontrada.'; end if;
  if p_lead_type not in ('Venda', 'Aluguel') then raise exception 'Tipo de lead inválido.'; end if;
  perform pg_advisory_xact_lock(hashtext('lead-distribution:' || p_lead_type));
  normalized_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if normalized_phone = '' then raise exception 'Telefone é obrigatório.'; end if;
  perform pg_advisory_xact_lock(hashtext(normalized_phone));
  if exists (select 1 from public.crm_leads where regexp_replace(coalesce(phone, ''), '\D', '', 'g') = normalized_phone) then
    raise exception 'Já existe um lead cadastrado com este telefone.';
  end if;
  select queue.broker_id, profile.full_name, profile.email into next_broker
  from public.lead_distribution_queue queue join public.profiles profile on profile.id = queue.broker_id
  where queue.lead_type = p_lead_type and profile.role = 'broker'
    and not coalesce(profile.lead_distribution_blocked, false)
  order by queue.position limit 1 for update of queue skip locked;
  if next_broker.broker_id is null then raise exception 'Não há corretores disponíveis na fila de %.', p_lead_type; end if;
  select coalesce(max(position), 0) + 1 into next_position from public.lead_distribution_queue where lead_type = p_lead_type;
  update public.lead_distribution_queue set position = next_position, updated_at = now()
  where lead_type = p_lead_type and broker_id = next_broker.broker_id;
  insert into public.crm_leads (name, phone, email, property_interest, stage, channel, budget, notes, owner_id, created_by, external_id, lead_type)
  values (p_name, nullif(p_phone, ''), nullif(p_email, ''), nullif(p_property_interest, ''), p_stage,
    nullif(p_channel, ''), 0, nullif(p_notes, ''), next_broker.broker_id, auth.uid(), nullif(p_external_id, ''), p_lead_type)
  returning id into inserted_lead;
  return query select inserted_lead, next_broker.broker_id, coalesce(nullif(next_broker.full_name, ''), next_broker.email);
end;
$$;

create or replace function public.import_sheet_lead_with_distribution(
  p_external_id text, p_name text, p_phone text, p_property_interest text, p_stage text,
  p_channel text, p_notes text, p_lead_type text
)
returns table (lead_id uuid, assigned_owner_name text)
language plpgsql security definer set search_path = public as $$
declare next_broker record; next_position integer; inserted_lead uuid;
begin
  if not public.is_admin() then raise exception 'Apenas administradores podem sincronizar leads da planilha.'; end if;
  if nullif(p_external_id, '') is null then raise exception 'O identificador do lead da planilha é obrigatório.'; end if;
  if p_lead_type not in ('Venda', 'Aluguel') then raise exception 'Tipo de lead inválido.'; end if;
  select id into inserted_lead from public.crm_leads where external_id = p_external_id;
  if inserted_lead is not null then
    return query select lead.id, coalesce(profile.full_name, profile.email)
    from public.crm_leads lead join public.profiles profile on profile.id = lead.owner_id where lead.id = inserted_lead;
    return;
  end if;
  perform pg_advisory_xact_lock(hashtext('lead-distribution:' || p_lead_type));
  select queue.broker_id, profile.full_name, profile.email into next_broker
  from public.lead_distribution_queue queue join public.profiles profile on profile.id = queue.broker_id
  where queue.lead_type = p_lead_type and profile.role = 'broker'
    and not coalesce(profile.lead_distribution_blocked, false)
  order by queue.position limit 1 for update of queue skip locked;
  if next_broker.broker_id is null then raise exception 'Não há corretores disponíveis na fila de %.', p_lead_type; end if;
  select coalesce(max(position), 0) + 1 into next_position from public.lead_distribution_queue where lead_type = p_lead_type;
  update public.lead_distribution_queue set position = next_position, updated_at = now()
  where lead_type = p_lead_type and broker_id = next_broker.broker_id;
  insert into public.crm_leads (name, phone, property_interest, stage, channel, budget, notes, owner_id, created_by, external_id, lead_type)
  values (p_name, nullif(p_phone, ''), nullif(p_property_interest, ''), p_stage, nullif(p_channel, ''), 0,
    nullif(p_notes, ''), next_broker.broker_id, auth.uid(), p_external_id, p_lead_type) returning id into inserted_lead;
  return query select inserted_lead, coalesce(nullif(next_broker.full_name, ''), next_broker.email);
end;
$$;

grant execute on function public.create_distributed_lead(text, text, text, text, text, text, text, text, text) to authenticated;
grant execute on function public.import_sheet_lead_with_distribution(text, text, text, text, text, text, text, text) to authenticated;

-- A transferência por expiração também ignora corretores bloqueados.
create or replace function public.process_expired_lead_assignments()
returns void language plpgsql security definer set search_path = public as $$
declare lead_row record; next_broker record; next_position integer; attempt_count integer; timeout_message text;
begin
  for lead_row in
    select * from public.crm_leads
    where assignment_deadline_at <= now()
      and (assignment_status = 'pending' or (assignment_status = 'accepted' and stage = 'Em atendimento'))
    for update skip locked
  loop
    update public.lead_assignment_attempts set expired_at = now()
    where lead_id = lead_row.id and expired_at is null
      and ((lead_row.assignment_status = 'pending' and accepted_at is null) or lead_row.assignment_status = 'accepted');
    select count(*) into attempt_count from public.lead_assignment_attempts where lead_id = lead_row.id;
    perform pg_advisory_xact_lock(hashtext('lead-distribution:' || lead_row.lead_type));
    select q.broker_id, p.full_name, p.email into next_broker
    from public.lead_distribution_queue q join public.profiles p on p.id = q.broker_id
    where q.lead_type = lead_row.lead_type and p.role = 'broker'
      and not coalesce(p.lead_distribution_blocked, false)
      and not exists (select 1 from public.lead_assignment_attempts a where a.lead_id = lead_row.id and a.broker_id = q.broker_id)
    order by q.position limit 1 for update of q skip locked;
    if next_broker.broker_id is null then
      update public.crm_leads set assignment_status = 'exhausted', assignment_deadline_at = null where id = lead_row.id;
      timeout_message := case when lead_row.assignment_status = 'accepted'
        then lead_row.name || ' ficou 24h em atendimento sem avanço.'
        else lead_row.name || ' não foi assumido por nenhum corretor disponível.' end;
      insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
      select id, 'lead_unanswered', 'Esteira de atendimento esgotada', timeout_message, '/leads',
        jsonb_build_object('leadId', lead_row.id, 'phone', lead_row.phone, 'name', lead_row.name)
      from public.profiles where role = 'admin';
    else
      select coalesce(max(position), 0) + 1 into next_position from public.lead_distribution_queue where lead_type = lead_row.lead_type;
      update public.lead_distribution_queue set position = next_position, updated_at = now()
      where lead_type = lead_row.lead_type and broker_id = next_broker.broker_id;
      update public.crm_leads
      set owner_id = next_broker.broker_id, assignment_status = 'pending',
        assignment_deadline_at = now() + interval '4 minutes', stage = 'Aguardando atendimento'
      where id = lead_row.id;
      insert into public.lead_assignment_attempts (lead_id, broker_id, attempt_number, deadline_at)
      values (lead_row.id, next_broker.broker_id, attempt_count + 1, now() + interval '4 minutes');
      insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
      values (next_broker.broker_id, 'lead_assignment', 'Lead transferido para sua carteira',
        'Você tem 4 minutos para iniciar o atendimento de ' || lead_row.name || '.', '/leads',
        jsonb_build_object('leadId', lead_row.id, 'phone', lead_row.phone, 'name', lead_row.name));
    end if;
  end loop;
end;
$$;

select public.refresh_broker_visit_block(id)
from public.profiles
where role = 'broker';

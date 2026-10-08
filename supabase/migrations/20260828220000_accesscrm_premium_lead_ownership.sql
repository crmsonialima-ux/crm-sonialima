begin;

create or replace function public.is_accesscrm_profile(p_profile_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1 from public.profiles profile
    where profile.id = p_profile_id
      and lower(trim(profile.email)) = 'unassigned-institutional@example.invalid'
  );
$$;

-- SoniaLima pode receber uma oferta pendente normalmente. Depois do aceite,
-- a propriedade e permanente e todos os prazos/qualificacoes ficam nulos.
create or replace function public.enforce_accesscrm_premium_lead_rules()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  new_owner_is_accesscrm boolean := public.is_accesscrm_profile(new.owner_id);
  old_owner_is_accesscrm boolean := false;
begin
  if tg_op = 'UPDATE' then
    old_owner_is_accesscrm := public.is_accesscrm_profile(old.owner_id);

    if old_owner_is_accesscrm
       and old.assignment_status = 'accepted'
       and new.owner_id is distinct from old.owner_id then
      raise exception 'Lead aceito pelo SoniaLima pertence permanentemente ao AcessoCRM.';
    end if;

    if old_owner_is_accesscrm and old.assignment_status = 'accepted' then
      new.assignment_status := 'accepted';
    end if;
  end if;

  if not new_owner_is_accesscrm then return new; end if;

  new.commercial_qualification_required := false;
  new.post_acceptance_qualification_deadline_at := null;
  new.post_acceptance_qualification_completed_at := null;
  new.post_acceptance_qualification_expired_at := null;
  new.post_acceptance_call_made := null;
  new.post_acceptance_call_result := null;
  new.post_acceptance_interaction := null;
  new.post_acceptance_whatsapp_contacted := null;
  new.post_acceptance_whatsapp_print_path := null;
  new.post_acceptance_whatsapp_has_whatsapp := null;

  if new.assignment_status = 'accepted' then
    new.assignment_available_at := null;
    new.assignment_deadline_at := null;
    new.assignment_reminder_sent_at := null;

    -- O clique de aceite nao muda a etapa. Depois disso, SoniaLima pode
    -- escolher uma etapa se quiser, sem qualquer obrigacao ou penalidade.
    if tg_op = 'INSERT' then
      new.stage := '';
    elsif old.assignment_status is distinct from 'accepted'
       or new.owner_id is distinct from old.owner_id then
      new.stage := '';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists zzzzzz_accesscrm_premium_lead_rules on public.crm_leads;
create trigger zzzzzz_accesscrm_premium_lead_rules
before insert or update on public.crm_leads
for each row execute function public.enforce_accesscrm_premium_lead_rules();

-- Nenhuma rotina automatica pode bloquear o usuario premium. A chave manual
-- controlada pelo Allyson continua sendo a unica forma de tira-lo da fila.
create or replace function public.enforce_accesscrm_premium_profile_rules()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if lower(trim(coalesce(new.email, ''))) <> 'unassigned-institutional@example.invalid' then
    return new;
  end if;

  new.lead_distribution_blocked_until := null;
  if coalesce(new.lead_distribution_manually_disabled, false) then
    new.lead_distribution_blocked := true;
    new.lead_distribution_blocked_reason := 'Desativado manualmente da fila pelo Allyson';
    new.lead_distribution_blocked_at := coalesce(new.lead_distribution_blocked_at, now());
  else
    new.lead_distribution_blocked := false;
    new.lead_distribution_blocked_reason := null;
    new.lead_distribution_blocked_at := null;
  end if;
  return new;
end;
$$;

drop trigger if exists zzzzzz_accesscrm_premium_profile_rules on public.profiles;
create trigger zzzzzz_accesscrm_premium_profile_rules
before insert or update on public.profiles
for each row execute function public.enforce_accesscrm_premium_profile_rules();

-- Defesa contra rotinas legadas: lembrete de qualificacao para AcessoCRM nem
-- chega a ser gravado.
create or replace function public.skip_accesscrm_qualification_notifications()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if new.kind = 'qualification_reminder'
     and public.is_accesscrm_profile(new.recipient_id) then
    return null;
  end if;
  return new;
end;
$$;

drop trigger if exists zzzzzz_skip_accesscrm_qualification_notifications
  on public.crm_notification_outbox;
create trigger zzzzzz_skip_accesscrm_qualification_notifications
before insert on public.crm_notification_outbox
for each row execute function public.skip_accesscrm_qualification_notifications();

drop function if exists public.accept_lead_assignment(uuid);
create function public.accept_lead_assignment(p_lead_id uuid)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  current_profile record;
  accepted_run_number integer;
  qualification_deadline timestamptz;
  is_accesscrm boolean := public.is_accesscrm_profile(auth.uid());
  manual_release boolean := false;
begin
  select profile.full_name, profile.email
  into current_profile
  from public.profiles profile
  where profile.id = auth.uid();
  if not found then raise exception 'Perfil nao encontrado.'; end if;

  select exists (
    select 1 from public.crm_notification_outbox notification
    where notification.kind = 'lead_assignment'
      and notification.recipient_id = auth.uid()
      and notification.payload ->> 'leadId' = p_lead_id::text
      and coalesce((notification.payload ->> 'manualRelease')::boolean, false)
  ) into manual_release;

  qualification_deadline := case when is_accesscrm then null
    else public.crm_add_lead_queue_minutes(now(), 120) end;

  update public.crm_leads lead
  set assignment_status = 'accepted',
      assignment_available_at = null,
      assignment_deadline_at = case when is_accesscrm then null
        else now() + interval '24 hours' end,
      assignment_reminder_sent_at = null,
      stage = case when is_accesscrm then lead.stage else 'Em atendimento' end,
      commercial_qualification_required = case when is_accesscrm then false
        else lead.commercial_qualification_required end,
      post_acceptance_qualification_deadline_at = qualification_deadline,
      post_acceptance_call_made = null,
      post_acceptance_call_result = null,
      post_acceptance_interaction = null,
      post_acceptance_whatsapp_contacted = null,
      post_acceptance_whatsapp_print_path = null,
      post_acceptance_whatsapp_has_whatsapp = null,
      post_acceptance_qualification_completed_at = null,
      post_acceptance_qualification_expired_at = null,
      updated_at = now()
  where lead.id = p_lead_id
    and lead.owner_id = auth.uid()
    and lead.assignment_status = 'pending'
    and lead.assignment_available_at <= now()
    and lead.assignment_deadline_at > now()
    and (public.crm_is_lead_queue_hours(now()) or manual_release)
    and (
      is_accesscrm
      or lead.property_catalog_id is null
      or exists (
        select 1
        from public.crm_property_broker_access access
        join public.lead_distribution_queue queue
          on queue.broker_id = access.broker_id
         and queue.lead_type = lead.lead_type
        join public.profiles profile on profile.id = access.broker_id
        where access.property_id = lead.property_catalog_id
          and access.broker_id = auth.uid()
          and profile.role = 'broker'
          and not coalesce(profile.lead_distribution_blocked, false)
          and (profile.lead_distribution_blocked_until is null
               or profile.lead_distribution_blocked_until <= now())
      )
    )
  returning lead.assignment_run_number into accepted_run_number;

  if not found then
    raise exception 'Este lead nao esta mais disponivel para aceite.';
  end if;

  update public.lead_assignment_attempts attempt
  set accepted_at = now()
  where attempt.lead_id = p_lead_id
    and attempt.broker_id = auth.uid()
    and attempt.run_number = accepted_run_number
    and attempt.notified_at <= now()
    and attempt.accepted_at is null
    and attempt.expired_at is null;

  insert into public.crm_lead_activities (lead_id, stage, note, author_id, author_name)
  values (
    p_lead_id,
    'Lead aceito',
    case when is_accesscrm
      then 'Lead aceito pelo SoniaLima sem prazo, qualificacao ou penalidade.'
      else 'Atendimento iniciado; qualificacao obrigatoria ate ' ||
        to_char(qualification_deadline at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || '.'
    end,
    auth.uid(),
    coalesce(nullif(current_profile.full_name, ''), current_profile.email)
  );

  delete from public.crm_notification_outbox notification
  where notification.kind = 'qualification_reminder'
    and notification.recipient_id = auth.uid()
    and notification.payload ->> 'leadId' = p_lead_id::text
    and notification.delivered_at is null;

  if not is_accesscrm then
    insert into public.crm_notification_outbox (
      recipient_id, kind, title, body, url, payload, available_at
    ) values
      (auth.uid(), 'qualification_reminder', 'Lead assumido - qualificacao obrigatoria',
       'Conclua todas as perguntas dentro de 2 horas uteis.', '/leads',
       jsonb_build_object('leadId', p_lead_id), now()),
      (auth.uid(), 'qualification_reminder', 'Qualificacao pendente',
       'Restam aproximadamente 1h30 para concluir.', '/leads',
       jsonb_build_object('leadId', p_lead_id), public.crm_add_lead_queue_minutes(now(), 30)),
      (auth.uid(), 'qualification_reminder', 'Qualificacao pendente',
       'Resta aproximadamente 1 hora para concluir.', '/leads',
       jsonb_build_object('leadId', p_lead_id), public.crm_add_lead_queue_minutes(now(), 60)),
      (auth.uid(), 'qualification_reminder', 'Qualificacao pendente',
       'Faltam aproximadamente 30 minutos para concluir.', '/leads',
       jsonb_build_object('leadId', p_lead_id), public.crm_add_lead_queue_minutes(now(), 90));
  end if;

  return case when is_accesscrm
    then 'Lead aceito definitivamente pelo SoniaLima.'
    else 'Lead aceito com sucesso.' end;
end;
$$;

revoke all on function public.accept_lead_assignment(uuid) from public, anon;
grant execute on function public.accept_lead_assignment(uuid) to authenticated;

create or replace function public.process_expired_lead_qualifications()
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  lead_row record;
  actor_name text;
begin
  for lead_row in
    select lead.*
    from public.crm_leads lead
    join public.profiles owner on owner.id = lead.owner_id
    where lead.assignment_status = 'accepted'
      and lower(trim(owner.email)) <> 'unassigned-institutional@example.invalid'
      and lead.post_acceptance_qualification_deadline_at <= now()
      and lead.post_acceptance_qualification_completed_at is null
      and lead.post_acceptance_qualification_expired_at is null
    order by lead.post_acceptance_qualification_deadline_at, lead.id
    for update of lead skip locked
  loop
    select coalesce(nullif(profile.full_name, ''), profile.email)
    into actor_name from public.profiles profile where profile.id = lead_row.owner_id;

    update public.profiles profile
    set lead_distribution_blocked_until = greatest(
          coalesce(profile.lead_distribution_blocked_until, '-infinity'::timestamptz),
          now() + interval '5 hours'),
        lead_distribution_blocked_reason = 'Penalidade: qualificacao obrigatoria nao concluida',
        updated_at = now()
    where profile.id = lead_row.owner_id;

    update public.crm_leads lead
    set assignment_status = 'pending',
        assignment_available_at = now() - interval '1 second',
        assignment_deadline_at = now() - interval '1 second',
        assignment_reminder_sent_at = null,
        stage = 'Aguardando atendimento',
        post_acceptance_qualification_expired_at = now(),
        updated_at = now()
    where lead.id = lead_row.id;

    update public.crm_notification_outbox notification
    set delivery_status = 'cancelled'
    where notification.kind = 'qualification_reminder'
      and notification.recipient_id = lead_row.owner_id
      and notification.payload ->> 'leadId' = lead_row.id::text
      and notification.delivered_at is null;

    insert into public.crm_lead_activities (
      lead_id, stage, note, author_id, author_name
    ) values (
      lead_row.id, 'Qualificacao expirada',
      'Qualificacao obrigatoria nao concluida. Corretor bloqueado por 5 horas e lead devolvido a esteira.',
      lead_row.owner_id, coalesce(actor_name, 'Sistema'));
  end loop;
end;
$$;

revoke all on function public.process_expired_lead_qualifications()
  from public, anon, authenticated;
grant execute on function public.process_expired_lead_qualifications() to service_role;

-- Qualquer nova oferta ao AcessoCRM consome sua vez e o coloca no fim da
-- fila de Venda, mesmo quando um bundle antigo iniciou o fluxo.
create or replace function public.rotate_accesscrm_after_lead_offer()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  next_position integer;
begin
  if new.assignment_status <> 'pending'
     or not public.is_accesscrm_profile(new.owner_id) then
    return new;
  end if;

  if tg_op = 'UPDATE'
     and old.owner_id is not distinct from new.owner_id
     and old.assignment_status = 'pending' then
    return new;
  end if;

  select coalesce(max(queue.position), 0) + 1
  into next_position
  from public.lead_distribution_queue queue
  where queue.lead_type = new.lead_type;

  update public.lead_distribution_queue queue
  set position = next_position, updated_at = now()
  where queue.lead_type = new.lead_type
    and queue.broker_id = new.owner_id;
  return new;
end;
$$;

drop trigger if exists zzzzzz_rotate_accesscrm_after_lead_offer on public.crm_leads;
create trigger zzzzzz_rotate_accesscrm_after_lead_offer
after insert or update of owner_id, assignment_status on public.crm_leads
for each row execute function public.rotate_accesscrm_after_lead_offer();

-- Se um navegador antigo selecionar SoniaLima no campo de responsavel, o
-- servidor ignora a fixacao direta e executa a distribuicao normal da fila.
create or replace function public.create_allyson_assigned_lead_with_phones(
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
  p_owner_id uuid,
  p_visit_scheduled_at timestamptz default null
)
returns table (lead_id uuid, assigned_owner_id uuid, assigned_owner_name text)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  created_lead record;
begin
  if not public.is_allyson_admin() then
    raise exception 'Somente Allyson pode atribuir um novo lead diretamente.';
  end if;
  if p_owner_id is null then raise exception 'Selecione o corretor responsavel.'; end if;

  if public.is_accesscrm_profile(p_owner_id) and p_visit_scheduled_at is null then
    select result.* into created_lead
    from public.create_lead_with_phones(
      p_name, p_phone, p_additional_phones, p_email, p_property_interest,
      p_stage, p_channel, p_notes, p_lead_type, p_desired_property_value,
      p_desired_location, null
    ) result;
    return query select created_lead.lead_id, created_lead.assigned_owner_id,
      created_lead.assigned_owner_name;
    return;
  end if;

  if p_visit_scheduled_at is not null then
    select result.* into created_lead
    from public.create_scheduled_visit_lead(
      p_name, p_phone, p_email, p_property_interest, p_channel, p_notes,
      p_lead_type, p_desired_property_value, p_desired_location, p_owner_id,
      p_visit_scheduled_at
    ) result;
  else
    select result.* into created_lead
    from public.create_admin_assigned_lead(
      p_name, p_phone, p_email, p_property_interest, p_stage, p_channel,
      p_notes, p_lead_type, p_desired_property_value, p_desired_location,
      p_owner_id
    ) result;

    update public.crm_leads lead
    set stage = p_stage,
        assignment_status = 'accepted',
        assignment_available_at = null,
        assignment_deadline_at = null,
        assignment_reminder_sent_at = null,
        updated_at = now()
    where lead.id = created_lead.lead_id;

    delete from public.lead_assignment_attempts attempt
    where attempt.lead_id = created_lead.lead_id;
    delete from public.crm_notification_outbox notification
    where notification.kind = 'lead_assignment'
      and notification.payload ->> 'leadId' = created_lead.lead_id::text;

    insert into public.crm_notification_outbox (
      recipient_id, kind, title, body, url, payload
    ) values (
      created_lead.assigned_owner_id,
      'lead_direct_assignment',
      'Novo lead atribuido por Allyson',
      trim(p_name) || ' foi atribuido diretamente a voce.',
      '/leads',
      jsonb_build_object(
        'leadId', created_lead.lead_id,
        'name', trim(p_name),
        'phone', nullif(trim(p_phone), ''),
        'assignedDirectly', true
      )
    );
  end if;

  if created_lead.lead_id is null then
    raise exception 'Nao foi possivel cadastrar o lead.';
  end if;

  update public.crm_leads lead
  set additional_phones = coalesce(p_additional_phones, '{}'::text[])
  where lead.id = created_lead.lead_id;

  return query select created_lead.lead_id, created_lead.assigned_owner_id,
    created_lead.assigned_owner_name;
end;
$$;

revoke all on function public.create_allyson_assigned_lead_with_phones(
  text,text,text[],text,text,text,text,text,text,numeric,text,uuid,timestamptz
) from public, anon, authenticated;
grant execute on function public.create_allyson_assigned_lead_with_phones(
  text,text,text[],text,text,text,text,text,text,numeric,text,uuid,timestamptz
) to authenticated;

-- Transferencia administrativa para SoniaLima tambem cria posse permanente,
-- preserva a etapa atual e nao menciona nem agenda qualificacao.
create or replace function public.transfer_lead_directly(p_lead_id uuid, p_owner_id uuid)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  lead_record public.crm_leads%rowtype;
  broker_record record;
  qualification_deadline timestamptz;
  target_is_accesscrm boolean := public.is_accesscrm_profile(p_owner_id);
begin
  if not public.is_allyson_admin() then
    raise exception 'Somente Allyson pode transferir um lead diretamente.';
  end if;

  select lead.* into lead_record
  from public.crm_leads lead where lead.id = p_lead_id for update;
  if not found then raise exception 'Lead nao encontrado.'; end if;

  select profile.id, profile.full_name, profile.email
  into broker_record
  from public.profiles profile
  where profile.id = p_owner_id
    and (profile.role = 'broker' or public.is_accesscrm_profile(profile.id));
  if not found then raise exception 'Corretor cadastrado nao encontrado.'; end if;

  update public.lead_assignment_attempts attempt
  set expired_at = coalesce(attempt.expired_at, now())
  where attempt.lead_id = lead_record.id
    and attempt.accepted_at is null and attempt.expired_at is null;

  delete from public.crm_notification_outbox notification
  where notification.delivered_at is null
    and notification.payload ->> 'leadId' = lead_record.id::text
    and notification.kind in (
      'lead_assignment', 'lead_direct_assignment', 'qualification_reminder');

  qualification_deadline := case when target_is_accesscrm then null
    else public.crm_add_lead_queue_minutes(now(), 120) end;
  perform set_config('crm.allyson_direct_transfer_lead_id', lead_record.id::text, true);
  perform set_config('crm.allyson_direct_transfer_owner_id', broker_record.id::text, true);

  update public.crm_leads lead
  set owner_id = broker_record.id,
      assignment_status = 'accepted',
      assignment_available_at = null,
      assignment_deadline_at = case when target_is_accesscrm then null
        else now() + interval '24 hours' end,
      assignment_reminder_sent_at = null,
      stage = case when target_is_accesscrm then lead_record.stage else 'Em atendimento' end,
      commercial_qualification_required = case when target_is_accesscrm then false
        else lead.commercial_qualification_required end,
      post_acceptance_qualification_deadline_at = qualification_deadline,
      post_acceptance_qualification_completed_at = null,
      post_acceptance_qualification_expired_at = null,
      post_acceptance_call_made = null,
      post_acceptance_call_result = null,
      post_acceptance_interaction = null,
      post_acceptance_whatsapp_contacted = null,
      post_acceptance_whatsapp_print_path = null,
      post_acceptance_whatsapp_has_whatsapp = null,
      updated_at = now()
  where lead.id = lead_record.id;

  perform set_config('crm.allyson_direct_transfer_lead_id', '', true);
  perform set_config('crm.allyson_direct_transfer_owner_id', '', true);

  insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
  values (
    broker_record.id,
    'lead_direct_assignment',
    'Novo lead atribuido diretamente',
    case when target_is_accesscrm
      then 'Um lead foi atribuido definitivamente ao SoniaLima, sem prazo ou qualificacao.'
      else 'Um lead foi atribuido diretamente a voce. Responda agora a qualificacao obrigatoria.'
    end,
    '/leads?focusLeadId=' || lead_record.id,
    jsonb_build_object('leadId', lead_record.id, 'assignedDirectly', true)
  );

  insert into public.crm_lead_activities (lead_id, stage, note, author_id, author_name)
  values (
    lead_record.id,
    'Transferencia direta',
    case when target_is_accesscrm
      then 'Lead transferido definitivamente para SoniaLima, sem prazo, qualificacao ou penalidade.'
      else 'Lead transferido diretamente para ' ||
        coalesce(broker_record.full_name, broker_record.email) ||
        '. A qualificacao obrigatoria de 2 horas uteis foi iniciada.'
    end,
    auth.uid(),
    'Sistema (Gestao)'
  );

  return coalesce(broker_record.full_name, broker_record.email);
end;
$$;

revoke all on function public.transfer_lead_directly(uuid, uuid) from public, anon;
grant execute on function public.transfer_lead_directly(uuid, uuid) to authenticated;

-- Limpa agora qualquer penalidade automatica antiga do AcessoCRM.
update public.profiles profile
set lead_distribution_blocked = coalesce(profile.lead_distribution_manually_disabled, false),
    lead_distribution_blocked_until = null,
    lead_distribution_blocked_reason = case
      when profile.lead_distribution_manually_disabled
        then 'Desativado manualmente da fila pelo Allyson'
      else null
    end,
    lead_distribution_blocked_at = case
      when profile.lead_distribution_manually_disabled
        then coalesce(profile.lead_distribution_blocked_at, now())
      else null
    end,
    updated_at = now()
where lower(trim(profile.email)) = 'unassigned-institutional@example.invalid';

-- Leads ja aceitos por SoniaLima recebem imediatamente a regra permanente.
update public.crm_leads lead
set assignment_available_at = null,
    assignment_deadline_at = null,
    assignment_reminder_sent_at = null,
    commercial_qualification_required = false,
    post_acceptance_qualification_deadline_at = null,
    post_acceptance_qualification_completed_at = null,
    post_acceptance_qualification_expired_at = null,
    post_acceptance_call_made = null,
    post_acceptance_call_result = null,
    post_acceptance_interaction = null,
    post_acceptance_whatsapp_contacted = null,
    post_acceptance_whatsapp_print_path = null,
    post_acceptance_whatsapp_has_whatsapp = null,
    stage = case
      when lead.stage in ('Aguardando atendimento', 'Em atendimento') then ''
      else lead.stage
    end,
    updated_at = now()
from public.profiles owner
where owner.id = lead.owner_id
  and lower(trim(owner.email)) = 'unassigned-institutional@example.invalid'
  and lead.assignment_status = 'accepted';

update public.crm_notification_outbox notification
set delivery_status = 'cancelled',
    dismissed_at = coalesce(notification.dismissed_at, now())
where notification.kind = 'qualification_reminder'
  and exists (
    select 1
    from public.crm_leads lead
    join public.profiles owner on owner.id = lead.owner_id
    where lead.id::text = notification.payload ->> 'leadId'
      and lower(trim(owner.email)) = 'unassigned-institutional@example.invalid'
  );

-- A oferta atual consumiu a vez do SoniaLima: posiciona-o no fim da fila de
-- Venda. As proximas ofertas repetem esse movimento pelo gatilho acima.
update public.lead_distribution_queue queue
set position = (
      select coalesce(max(other_queue.position), 0) + 1
      from public.lead_distribution_queue other_queue
      where other_queue.lead_type = 'Venda'
    ),
    updated_at = now()
from public.profiles profile
where queue.broker_id = profile.id
  and queue.lead_type = 'Venda'
  and lower(trim(profile.email)) = 'unassigned-institutional@example.invalid';

revoke all on function public.is_accesscrm_profile(uuid) from public, anon;
grant execute on function public.is_accesscrm_profile(uuid) to authenticated, service_role;

commit;

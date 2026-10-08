begin;

-- Central guarantee: a lead tied to a catalog property can only be assigned to
-- a broker selected for that property. Direct assignments also start the same
-- mandatory qualification used by the automatic queue.
create or replace function public.enforce_lead_owner_integrity()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  owner_profile record;
  assignment_started boolean := false;
  assignment_target_changed boolean := false;
begin
  if new.property_catalog_id is null
     and nullif(trim(coalesce(new.property_interest, '')), '') is not null
     and upper(trim(new.property_interest)) <> 'NAO TEM IMOVEL DE INTERESSE AINDA'
     and upper(trim(new.property_interest)) <> 'NÃO TEM IMÓVEL DE INTERESSE AINDA' then
    select catalog.external_id
    into new.property_catalog_id
    from public.crm_property_catalog as catalog
    where lower(trim(catalog.title)) = lower(trim(new.property_interest))
       or lower(trim(coalesce(catalog.address, ''))) = lower(trim(new.property_interest))
    order by catalog.updated_at desc, catalog.external_id
    limit 1;
  end if;

  select
    profile.role::text as role,
    profile.email,
    coalesce(profile.lead_distribution_blocked, false) as permanently_blocked,
    profile.lead_distribution_blocked_until as blocked_until
  into owner_profile
  from public.profiles as profile
  where profile.id = new.owner_id;

  if tg_op = 'INSERT' then
    assignment_target_changed := true;
  else
    assignment_target_changed := new.owner_id is distinct from old.owner_id
      or new.assignment_status is distinct from old.assignment_status
      or new.property_catalog_id is distinct from old.property_catalog_id;
  end if;

  if owner_profile.role = 'broker' then
    if new.property_catalog_id is not null
       and assignment_target_changed
       and not exists (
         select 1
         from public.crm_property_broker_access as access
         where access.property_id = new.property_catalog_id
           and access.broker_id = new.owner_id
       ) then
      raise exception 'Este corretor nao esta vinculado ao imovel do lead.';
    end if;

    if tg_op = 'UPDATE' then
      assignment_started := new.assignment_status = 'accepted'
        and (
          old.assignment_status is distinct from 'accepted'
          or new.owner_id is distinct from old.owner_id
        );
    end if;

    if assignment_started then
      if owner_profile.permanently_blocked
         or (owner_profile.blocked_until is not null and owner_profile.blocked_until > now()) then
        raise exception 'O corretor selecionado esta bloqueado para receber leads.';
      end if;

      new.assignment_available_at := null;
      new.assignment_deadline_at := now() + interval '24 hours';
      new.assignment_reminder_sent_at := null;
      new.post_acceptance_qualification_deadline_at := public.crm_add_lead_queue_minutes(now(), 120);
      new.post_acceptance_qualification_completed_at := null;
      new.post_acceptance_qualification_expired_at := null;
      new.post_acceptance_call_made := null;
      new.post_acceptance_call_result := null;
      new.post_acceptance_interaction := null;
      new.post_acceptance_whatsapp_contacted := null;
      new.post_acceptance_whatsapp_print_path := null;
      new.post_acceptance_whatsapp_has_whatsapp := null;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists zzzz_crm_leads_enforce_owner_integrity on public.crm_leads;
create trigger zzzz_crm_leads_enforce_owner_integrity
before insert or update on public.crm_leads
for each row execute function public.enforce_lead_owner_integrity();

create or replace function public.notify_required_lead_qualification()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if new.assignment_status = 'accepted'
     and new.post_acceptance_qualification_deadline_at is not null
     and (
       old.post_acceptance_qualification_deadline_at is distinct from new.post_acceptance_qualification_deadline_at
       or old.owner_id is distinct from new.owner_id
     ) then
    insert into public.crm_notification_outbox (
      recipient_id, kind, title, body, url, payload, available_at
    ) values
      (new.owner_id, 'qualification_reminder', 'Lead assumido - qualificacao obrigatoria',
       'Conclua todas as perguntas da qualificacao dentro de 2 horas uteis.', '/leads',
       jsonb_build_object('leadId', new.id), now()),
      (new.owner_id, 'qualification_reminder', 'Qualificacao pendente',
       'Restam aproximadamente 1h30 de horario comercial para concluir a qualificacao.', '/leads',
       jsonb_build_object('leadId', new.id), public.crm_add_lead_queue_minutes(now(), 30)),
      (new.owner_id, 'qualification_reminder', 'Qualificacao pendente',
       'Resta aproximadamente 1 hora comercial para concluir a qualificacao.', '/leads',
       jsonb_build_object('leadId', new.id), public.crm_add_lead_queue_minutes(now(), 60)),
      (new.owner_id, 'qualification_reminder', 'Qualificacao pendente',
       'Atencao: faltam aproximadamente 30 minutos para o prazo da qualificacao.', '/leads',
       jsonb_build_object('leadId', new.id), public.crm_add_lead_queue_minutes(now(), 90));
  end if;
  return new;
end;
$$;

drop trigger if exists zzzz_crm_leads_notify_required_qualification on public.crm_leads;
create trigger zzzz_crm_leads_notify_required_qualification
after update on public.crm_leads
for each row execute function public.notify_required_lead_qualification();

-- Keep the existing acceptance contract, while making reminder creation
-- idempotent with the central trigger above.
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
  new_qualification_deadline timestamptz;
begin
  new_qualification_deadline := public.crm_add_lead_queue_minutes(now(), 120);

  update public.crm_leads as lead
  set assignment_status = 'accepted',
      assignment_available_at = null,
      assignment_deadline_at = now() + interval '24 hours',
      assignment_reminder_sent_at = null,
      stage = 'Em atendimento',
      post_acceptance_qualification_deadline_at = new_qualification_deadline,
      post_acceptance_call_made = null,
      post_acceptance_call_result = null,
      post_acceptance_interaction = null,
      post_acceptance_whatsapp_contacted = null,
      post_acceptance_whatsapp_print_path = null,
      post_acceptance_whatsapp_has_whatsapp = null,
      post_acceptance_qualification_completed_at = null,
      post_acceptance_qualification_expired_at = null
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
        join public.profiles as profile on profile.id = access.broker_id
        where access.property_id = lead.property_catalog_id
          and access.broker_id = auth.uid()
          and profile.role = 'broker'
          and not coalesce(profile.lead_distribution_blocked, false)
          and (profile.lead_distribution_blocked_until is null or profile.lead_distribution_blocked_until <= now())
      )
    )
  returning lead.assignment_run_number into accepted_run_number;

  if not found then
    raise exception 'Este lead nao esta disponivel para aceite, o acesso ao imovel mudou ou o corretor esta bloqueado.';
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

  insert into public.crm_lead_activities (lead_id, stage, note, author_id, author_name)
  values (
    p_lead_id,
    'Lead aceito',
    'Atendimento iniciado; qualificacao obrigatoria ate ' ||
      to_char(new_qualification_deadline at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || '.',
    auth.uid(),
    coalesce(nullif(current_profile.full_name, ''), current_profile.email)
  );

  delete from public.crm_notification_outbox as notification
  where notification.kind = 'qualification_reminder'
    and notification.recipient_id = auth.uid()
    and notification.payload ->> 'leadId' = p_lead_id::text
    and notification.delivered_at is null;

  insert into public.crm_notification_outbox (
    recipient_id, kind, title, body, url, payload, available_at
  ) values
    (auth.uid(), 'qualification_reminder', 'Lead assumido - qualificacao obrigatoria',
     'Conclua todas as perguntas da qualificacao dentro de 2 horas uteis.', '/leads',
     jsonb_build_object('leadId', p_lead_id), now()),
    (auth.uid(), 'qualification_reminder', 'Qualificacao pendente',
     'Restam aproximadamente 1h30 de horario comercial para concluir a qualificacao.', '/leads',
     jsonb_build_object('leadId', p_lead_id), public.crm_add_lead_queue_minutes(now(), 30)),
    (auth.uid(), 'qualification_reminder', 'Qualificacao pendente',
     'Resta aproximadamente 1 hora comercial para concluir a qualificacao.', '/leads',
     jsonb_build_object('leadId', p_lead_id), public.crm_add_lead_queue_minutes(now(), 60)),
    (auth.uid(), 'qualification_reminder', 'Qualificacao pendente',
     'Atencao: faltam aproximadamente 30 minutos para o prazo da qualificacao.', '/leads',
     jsonb_build_object('leadId', p_lead_id), public.crm_add_lead_queue_minutes(now(), 90));

  return 'Lead aceito com sucesso.';
end;
$$;

revoke all on function public.accept_lead_assignment(uuid) from public, anon;
grant execute on function public.accept_lead_assignment(uuid) to authenticated;

create or replace function public.transfer_lead_directly(p_lead_id uuid, p_owner_id uuid)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  lead_record public.crm_leads%rowtype;
  broker_record record;
begin
  if not public.is_allyson_admin() then
    raise exception 'Somente Allyson pode transferir um lead diretamente.';
  end if;

  select lead.* into lead_record
  from public.crm_leads as lead
  where lead.id = p_lead_id
  for update;
  if not found then raise exception 'Lead nao encontrado.'; end if;

  select profile.id, profile.full_name, profile.email
  into broker_record
  from public.profiles as profile
  where profile.id = p_owner_id
    and profile.role = 'broker'
    and not coalesce(profile.lead_distribution_blocked, false)
    and (profile.lead_distribution_blocked_until is null or profile.lead_distribution_blocked_until <= now());
  if not found then raise exception 'Corretor indisponivel, bloqueado ou nao encontrado.'; end if;

  if lead_record.property_catalog_id is not null and not exists (
    select 1 from public.crm_property_broker_access as access
    where access.property_id = lead_record.property_catalog_id
      and access.broker_id = broker_record.id
  ) then
    raise exception 'Este corretor nao esta vinculado ao imovel do lead.';
  end if;

  update public.lead_assignment_attempts as attempt
  set expired_at = coalesce(attempt.expired_at, now())
  where attempt.lead_id = lead_record.id
    and attempt.accepted_at is null
    and attempt.expired_at is null;

  delete from public.crm_notification_outbox as notification
  where notification.delivered_at is null
    and notification.payload ->> 'leadId' = lead_record.id::text
    and notification.kind in ('lead_assignment', 'qualification_reminder');

  update public.crm_leads as lead
  set owner_id = broker_record.id,
      assignment_status = 'accepted',
      assignment_available_at = null,
      assignment_deadline_at = now() + interval '24 hours',
      assignment_reminder_sent_at = null,
      stage = 'Em atendimento',
      post_acceptance_qualification_deadline_at = null,
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

  insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
  values (
    broker_record.id,
    'lead_direct_assignment',
    'Novo lead atribuido diretamente',
    'Um lead foi atribuido diretamente a voce. Responda agora a qualificacao obrigatoria.',
    '/leads?focusLeadId=' || lead_record.id,
    jsonb_build_object('leadId', lead_record.id, 'assignedDirectly', true)
  );

  insert into public.crm_lead_activities (lead_id, stage, note, author_id, author_name)
  values (
    lead_record.id,
    'Transferencia direta',
    'Lead transferido diretamente para ' || coalesce(broker_record.full_name, broker_record.email) ||
      '. A qualificacao obrigatoria de 2 horas uteis foi iniciada.',
    auth.uid(),
    'Sistema (Gestao)'
  );

  return coalesce(broker_record.full_name, broker_record.email);
end;
$$;

revoke all on function public.transfer_lead_directly(uuid, uuid) from public, anon;
grant execute on function public.transfer_lead_directly(uuid, uuid) to authenticated;

-- Expired qualifications were previously left waiting for the generic 24-hour
-- fallback. This processor applies the existing 5-hour penalty immediately and
-- returns the lead to the eligible-property queue.
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
    from public.crm_leads as lead
    where lead.assignment_status = 'accepted'
      and lead.post_acceptance_qualification_deadline_at <= now()
      and lead.post_acceptance_qualification_completed_at is null
      and lead.post_acceptance_qualification_expired_at is null
    order by lead.post_acceptance_qualification_deadline_at, lead.id
    for update skip locked
  loop
    select coalesce(nullif(profile.full_name, ''), profile.email)
    into actor_name from public.profiles as profile where profile.id = lead_row.owner_id;

    update public.profiles as profile
    set lead_distribution_blocked_until = greatest(
          coalesce(profile.lead_distribution_blocked_until, now()), now()
        ) + interval '5 hours',
        lead_distribution_blocked_reason = 'Penalidade: qualificacao obrigatoria nao concluida',
        updated_at = now()
    where profile.id = lead_row.owner_id;

    update public.crm_leads as lead
    set assignment_status = 'pending',
        assignment_available_at = now() - interval '1 second',
        assignment_deadline_at = now() - interval '1 second',
        assignment_reminder_sent_at = null,
        stage = 'Aguardando atendimento',
        post_acceptance_qualification_expired_at = now(),
        updated_at = now()
    where lead.id = lead_row.id;

    update public.crm_notification_outbox as notification
    set delivery_status = 'cancelled'
    where notification.kind = 'qualification_reminder'
      and notification.recipient_id = lead_row.owner_id
      and notification.payload ->> 'leadId' = lead_row.id::text
      and notification.delivered_at is null;

    insert into public.crm_lead_activities (lead_id, stage, note, author_id, author_name)
    values (
      lead_row.id,
      'Qualificacao expirada',
      'Qualificacao obrigatoria nao concluida. Corretor bloqueado por 5 horas e lead devolvido a esteira.',
      lead_row.owner_id,
      coalesce(actor_name, 'Sistema')
    );
  end loop;

end;
$$;

revoke all on function public.process_expired_lead_qualifications() from public, anon, authenticated;
grant execute on function public.process_expired_lead_qualifications() to service_role;

-- Keep the cron entry point unchanged. The existing, battle-tested roulette
-- runs immediately after qualification expirations are converted to timeouts.
alter function public.process_expired_lead_assignments()
  rename to process_expired_lead_assignments_before_integrity;

create function public.process_expired_lead_assignments()
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  perform public.process_expired_lead_qualifications();
  perform public.process_expired_lead_assignments_before_integrity();
end;
$$;

revoke all on function public.process_expired_lead_assignments_before_integrity()
  from public, anon, authenticated;
revoke all on function public.process_expired_lead_assignments()
  from public, anon, authenticated;
grant execute on function public.process_expired_lead_assignments_before_integrity() to service_role;
grant execute on function public.process_expired_lead_assignments() to service_role;

-- Authenticated dashboard status. Blocked brokers stay out of the "next" list
-- and appear in a separate shared panel until the reason is resolved or time ends.
create or replace function public.list_lead_distribution_status()
returns table (
  id uuid,
  lead_type text,
  queue_position integer,
  broker_id uuid,
  full_name text,
  email text,
  is_blocked boolean,
  is_permanently_blocked boolean,
  blocked_until timestamptz,
  blocked_reason text
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select
    queue.id,
    queue.lead_type,
    queue.position,
    queue.broker_id,
    coalesce(nullif(trim(profile.full_name), ''), queue.broker_email, profile.email),
    profile.email,
    coalesce(profile.lead_distribution_blocked, false)
      or coalesce(profile.lead_distribution_blocked_until > now(), false),
    coalesce(profile.lead_distribution_blocked, false),
    profile.lead_distribution_blocked_until,
    profile.lead_distribution_blocked_reason
  from public.lead_distribution_queue as queue
  join public.profiles as profile on profile.id = queue.broker_id
  where auth.uid() is not null
  order by queue.lead_type, queue.position, queue.id;
$$;

revoke all on function public.list_lead_distribution_status() from public, anon;
grant execute on function public.list_lead_distribution_status() to authenticated;

-- Only Allyson can remove a financing process. The CRM lead is intentionally
-- preserved; process documents, attempts and history cascade with the process.
create or replace function public.delete_financing_process(p_process_id uuid)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  process_record record;
begin
  if not public.is_allyson_admin() then
    raise exception 'Somente Allyson pode excluir um cliente da aba de financiamentos.';
  end if;

  select process.id, process.lead_id, process.broker_id, lead.name as lead_name
  into process_record
  from public.crm_financing_processes as process
  join public.crm_leads as lead on lead.id = process.lead_id
  where process.id = p_process_id
  for update of process;
  if not found then raise exception 'Processo de financiamento nao encontrado.'; end if;

  perform public.append_crm_audit_event(
    process_record.broker_id,
    auth.uid(),
    'financing',
    'financing_process_deleted',
    'success',
    'crm_financing_process',
    process_record.id,
    null,
    now(),
    'Processo de financiamento removido por Allyson; o lead foi preservado.',
    jsonb_build_object('leadId', process_record.lead_id, 'leadName', process_record.lead_name),
    null,
    'financing-process-deleted:' || process_record.id::text
  );

  delete from public.crm_financing_processes as process
  where process.id = process_record.id;

  return process_record.lead_name;
end;
$$;

revoke all on function public.delete_financing_process(uuid) from public, anon;
grant execute on function public.delete_financing_process(uuid) to authenticated;

commit;

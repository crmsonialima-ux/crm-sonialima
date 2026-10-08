begin;

-- A direct transfer is a management override, not an automatic queue turn.
-- The marker is transaction-local and tied to both the lead and destination,
-- so the central guard remains strict for every other assignment path.
create or replace function public.enforce_lead_owner_integrity()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  owner_profile record;
  assignment_started boolean := false;
  property_target_changed boolean := false;
  allyson_direct_transfer boolean := false;
begin
  if new.property_catalog_id is null
     and nullif(trim(coalesce(new.property_interest, '')), '') is not null
     and upper(trim(new.property_interest)) <> 'NAO TEM IMOVEL DE INTERESSE AINDA' then
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
    property_target_changed := true;
  else
    property_target_changed := new.owner_id is distinct from old.owner_id
      or new.property_catalog_id is distinct from old.property_catalog_id
      or (
        new.assignment_status = 'accepted'
        and old.assignment_status is distinct from 'accepted'
      );
  end if;

  allyson_direct_transfer :=
    tg_op = 'UPDATE'
    and public.is_allyson_admin()
    and coalesce(current_setting('crm.allyson_direct_transfer_lead_id', true), '') = new.id::text
    and coalesce(current_setting('crm.allyson_direct_transfer_owner_id', true), '') = new.owner_id::text;

  if owner_profile.role = 'broker' then
    if new.property_catalog_id is not null
       and property_target_changed
       and not allyson_direct_transfer
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
      if not allyson_direct_transfer
         and (
           owner_profile.permanently_blocked
           or (owner_profile.blocked_until is not null and owner_profile.blocked_until > now())
         ) then
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
begin
  if not public.is_allyson_admin() then
    raise exception 'Somente Allyson pode transferir um lead diretamente.';
  end if;

  select lead.* into lead_record
  from public.crm_leads as lead
  where lead.id = p_lead_id
  for update;
  if not found then
    raise exception 'Lead nao encontrado.';
  end if;

  select profile.id, profile.full_name, profile.email
  into broker_record
  from public.profiles as profile
  where profile.id = p_owner_id
    and (
      profile.role = 'broker'
      or (
        profile.role = 'admin'
        and lower(trim(profile.email)) = 'unassigned-institutional@example.invalid'
      )
    );
  if not found then
    raise exception 'Corretor cadastrado nao encontrado.';
  end if;

  update public.lead_assignment_attempts as attempt
  set expired_at = coalesce(attempt.expired_at, now())
  where attempt.lead_id = lead_record.id
    and attempt.accepted_at is null
    and attempt.expired_at is null;

  delete from public.crm_notification_outbox as notification
  where notification.delivered_at is null
    and notification.payload ->> 'leadId' = lead_record.id::text
    and notification.kind in (
      'lead_assignment',
      'lead_direct_assignment',
      'qualification_reminder'
    );

  qualification_deadline := public.crm_add_lead_queue_minutes(now(), 120);
  perform set_config('crm.allyson_direct_transfer_lead_id', lead_record.id::text, true);
  perform set_config('crm.allyson_direct_transfer_owner_id', broker_record.id::text, true);

  update public.crm_leads as lead
  set owner_id = broker_record.id,
      assignment_status = 'accepted',
      assignment_available_at = null,
      assignment_deadline_at = now() + interval '24 hours',
      assignment_reminder_sent_at = null,
      stage = 'Em atendimento',
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

commit;

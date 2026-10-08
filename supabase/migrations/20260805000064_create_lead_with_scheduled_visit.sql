-- Cria um lead ja com a visita marcada, preservando a distribuicao atual.
-- A operacao inteira ocorre na mesma transacao e o trigger da Agenda cria
-- automaticamente o compromisso para o corretor responsavel.

create or replace function public.create_scheduled_visit_lead(
  p_name text,
  p_phone text,
  p_email text,
  p_property_interest text,
  p_channel text,
  p_notes text,
  p_lead_type text,
  p_desired_property_value numeric,
  p_desired_location text,
  p_owner_id uuid,
  p_visit_scheduled_at timestamptz
)
returns table (lead_id uuid, assigned_owner_id uuid, assigned_owner_name text)
language plpgsql
security definer
set search_path = public
as $$
declare
  created_lead record;
  creator_name text;
begin
  if auth.uid() is null then
    raise exception 'Sessao nao encontrada.';
  end if;

  if p_visit_scheduled_at is null then
    raise exception 'Informe a data e a hora da visita.';
  end if;

  if p_owner_id is not null then
    select * into created_lead
    from public.create_admin_assigned_lead(
      p_name,
      p_phone,
      p_email,
      p_property_interest,
      'Visita agendada',
      p_channel,
      p_notes,
      p_lead_type,
      p_desired_property_value,
      p_desired_location,
      p_owner_id
    );
  else
    select * into created_lead
    from public.create_distributed_lead(
      p_name,
      p_phone,
      p_email,
      p_property_interest,
      'Visita agendada',
      p_channel,
      p_notes,
      '',
      p_lead_type,
      p_desired_property_value,
      p_desired_location
    );
  end if;

  if created_lead.lead_id is null then
    raise exception 'Nao foi possivel criar o lead com a visita agendada.';
  end if;

  -- O gatilho geral de novos leads inicia a esteira de aceite. Para um lead
  -- que ja nasce com visita marcada, a atribuicao ja esta definida.
  update public.crm_leads
  set stage = 'Visita agendada',
      visit_scheduled_at = p_visit_scheduled_at,
      assignment_status = 'accepted',
      assignment_deadline_at = null
  where id = created_lead.lead_id;

  delete from public.lead_assignment_attempts as assignment_attempt
  where assignment_attempt.lead_id = created_lead.lead_id;

  delete from public.crm_notification_outbox
  where kind = 'lead_assignment'
    and payload ->> 'leadId' = created_lead.lead_id::text;

  select coalesce(nullif(full_name, ''), email, 'Usuario')
  into creator_name
  from public.profiles
  where id = auth.uid();

  insert into public.crm_lead_activities (
    lead_id,
    stage,
    note,
    author_id,
    author_name,
    scheduled_for
  ) values (
    created_lead.lead_id,
    'Visita agendada',
    nullif(trim(p_notes), ''),
    auth.uid(),
    coalesce(creator_name, 'Usuario'),
    p_visit_scheduled_at
  );

  insert into public.crm_notification_outbox (
    recipient_id,
    kind,
    title,
    body,
    url,
    payload
  ) values (
    created_lead.assigned_owner_id,
    'lead_visit_scheduled',
    'Nova visita agendada',
    'Visita com ' || trim(p_name) || ' em '
      || to_char(p_visit_scheduled_at at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || '.',
    '/agenda',
    jsonb_build_object(
      'leadId', created_lead.lead_id,
      'name', trim(p_name),
      'scheduledAt', p_visit_scheduled_at
    )
  );

  return query select
    created_lead.lead_id,
    created_lead.assigned_owner_id,
    created_lead.assigned_owner_name;
end;
$$;

revoke all on function public.create_scheduled_visit_lead(
  text, text, text, text, text, text, text, numeric, text, uuid, timestamptz
) from public, anon;

grant execute on function public.create_scheduled_visit_lead(
  text, text, text, text, text, text, text, numeric, text, uuid, timestamptz
) to authenticated;

-- Se a gravacao espelhada na planilha falhar, remove tambem o compromisso
-- tecnico criado nesta tentativa, evitando uma visita orfa na Agenda.
create or replace function public.rollback_unlinked_lead_creation(p_lead_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  previous_owner_id uuid;
begin
  select owner_id
  into previous_owner_id
  from public.crm_leads
  where id = p_lead_id
    and external_id is null
    and (created_by = auth.uid() or public.is_admin())
  for update;

  if previous_owner_id is null then
    raise exception 'Lead nao encontrado ou ja vinculado a planilha.';
  end if;

  delete from public.crm_notification_outbox
  where payload ->> 'leadId' = p_lead_id::text;

  delete from public.crm_agenda_entries
  where source_kind = 'lead_visit'
    and source_lead_id = p_lead_id;

  delete from public.crm_leads
  where id = p_lead_id;

  perform public.refresh_broker_visit_block(previous_owner_id);
end;
$$;

grant execute on function public.rollback_unlinked_lead_creation(uuid) to authenticated;

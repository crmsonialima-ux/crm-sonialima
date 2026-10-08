-- Mantem os documentos do imovel e os documentos da proposta em conjuntos
-- independentes. Cada rotina recalcula os nove anexos obrigatorios antes de
-- cada disparo e para de avisar assim que o respectivo conjunto estiver completo.

create or replace function public.process_property_document_reminders()
returns integer
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  property_row record;
  attached_count integer;
  pending_count integer;
  inserted_count integer;
  created_count integer := 0;
begin
  for property_row in
    select external_id, title, broker_id
    from public.crm_property_document_responsibilities
  loop
    select count(distinct split_part(split_part(name, '/', 2), '.', 1))
    into attached_count
    from storage.objects
    where bucket_id = 'property-documents'
      and name like property_row.external_id || '/%'
      and split_part(split_part(name, '/', 2), '.', 1) in (
        'certidao-onus', 'certidao-iptu', 'pgfn', 'tjdft', 'trf1-criminal',
        'trf1-civil', 'trt10', 'tst', 'sefaz-df'
      );

    pending_count := 9 - coalesce(attached_count, 0);
    if pending_count <= 0 then
      continue;
    end if;

    insert into public.crm_notification_outbox (
      recipient_id,
      kind,
      title,
      body,
      url,
      payload
    )
    select
      recipient.recipient_id,
      'property_document_reminder',
      'Documentos pendentes do imóvel',
      property_row.title || ' possui ' || pending_count ||
        ' documento(s) pendente(s). Anexe todos assim que possível.',
      '/imoveis',
      jsonb_build_object(
        'propertyId', property_row.external_id,
        'pendingDocuments', pending_count,
        'requiredDocuments', 9,
        'documentSet', 'property'
      )
    from (
      select property_row.broker_id as recipient_id
      where property_row.broker_id is not null
      union
      select profile.id
      from public.profiles as profile
      where profile.role = 'admin'
    ) as recipient;

    get diagnostics inserted_count = row_count;
    created_count := created_count + inserted_count;
  end loop;

  return created_count;
end;
$$;

create or replace function public.process_lead_proposal_document_reminders()
returns integer
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  lead_row record;
  attached_count integer;
  pending_count integer;
  inserted_count integer;
  created_count integer := 0;
begin
  for lead_row in
    select id, owner_id, name
    from public.crm_leads
    where stage = 'Proposta'
  loop
    select count(distinct split_part(split_part(name, '/', 2), '.', 1))
    into attached_count
    from storage.objects
    where bucket_id = 'lead-documents'
      and name like lead_row.id::text || '/%'
      and split_part(split_part(name, '/', 2), '.', 1) in (
        'certidao-onus', 'certidao-iptu', 'pgfn', 'tjdft', 'trf1-criminal',
        'trf1-civil', 'trt10', 'tst', 'sefaz-df'
      );

    pending_count := 9 - coalesce(attached_count, 0);
    if pending_count <= 0 then
      continue;
    end if;

    insert into public.crm_notification_outbox (
      recipient_id,
      kind,
      title,
      body,
      url,
      payload
    )
    select
      recipient.recipient_id,
      'lead_proposal_document_reminder',
      'Documentos pendentes da proposta',
      'A proposta de ' || lead_row.name || ' possui ' || pending_count ||
        ' documento(s) pendente(s). Os nove anexos da proposta devem ser enviados novamente.',
      '/leads',
      jsonb_build_object(
        'leadId', lead_row.id,
        'pendingDocuments', pending_count,
        'requiredDocuments', 9,
        'documentSet', 'proposal'
      )
    from (
      select lead_row.owner_id as recipient_id
      union
      select profile.id
      from public.profiles as profile
      where profile.role = 'admin'
    ) as recipient;

    get diagnostics inserted_count = row_count;
    created_count := created_count + inserted_count;
  end loop;

  return created_count;
end;
$$;

grant execute on function public.process_property_document_reminders() to service_role;
grant execute on function public.process_lead_proposal_document_reminders() to service_role;

-- Remove tanto os agendamentos antigos quanto os novos para que a migration
-- possa ser reaplicada sem duplicar lembretes.
do $$
declare
  scheduled_job record;
begin
  for scheduled_job in
    select jobid
    from cron.job
    where jobname in (
      'property-document-reminder-morning',
      'property-document-reminder-midday',
      'property-document-reminder-afternoon',
      'lead-proposal-document-reminder-daily',
      'lead-proposal-document-reminder-morning',
      'lead-proposal-document-reminder-midday',
      'lead-proposal-document-reminder-afternoon'
    )
  loop
    perform cron.unschedule(scheduled_job.jobid);
  end loop;
end;
$$;

-- O pg_cron usa UTC. Os horarios abaixo correspondem a 10:30, 13:30 e
-- 16:00 no horario de Brasilia.
select cron.schedule(
  'property-document-reminder-morning',
  '30 13 * * *',
  $$select public.process_property_document_reminders();$$
);

select cron.schedule(
  'property-document-reminder-midday',
  '30 16 * * *',
  $$select public.process_property_document_reminders();$$
);

select cron.schedule(
  'property-document-reminder-afternoon',
  '0 19 * * *',
  $$select public.process_property_document_reminders();$$
);

select cron.schedule(
  'lead-proposal-document-reminder-morning',
  '30 13 * * *',
  $$select public.process_lead_proposal_document_reminders();$$
);

select cron.schedule(
  'lead-proposal-document-reminder-midday',
  '30 16 * * *',
  $$select public.process_lead_proposal_document_reminders();$$
);

select cron.schedule(
  'lead-proposal-document-reminder-afternoon',
  '0 19 * * *',
  $$select public.process_lead_proposal_document_reminders();$$
);

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
    if pending_count <= 0 then continue; end if;

    insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
    values (
      lead_row.owner_id,
      'lead_proposal_document_reminder',
      'Documentos pendentes da proposta',
      'A proposta de ' || lead_row.name || ' possui ' || pending_count || ' documento(s) pendente(s).',
      '/leads',
      jsonb_build_object('leadId', lead_row.id, 'pendingDocuments', pending_count)
    );
    created_count := created_count + 1;
  end loop;
  return created_count;
end;
$$;

grant execute on function public.process_lead_proposal_document_reminders() to service_role;

-- 13:30 UTC equivale a 10:30 no horário de Brasília.
select cron.schedule(
  'lead-proposal-document-reminder-daily',
  '30 13 * * *',
  $$select public.process_lead_proposal_document_reminders();$$
);

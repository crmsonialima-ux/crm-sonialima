-- Sold properties no longer generate pending-document reminders.
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
    select catalog.external_id, catalog.title, capturer.broker_id as capturer_id
    from public.crm_property_catalog as catalog
    left join public.crm_property_capturer_assignments as capturer
      on capturer.property_id = catalog.external_id
    where lower(trim(coalesce(catalog.status, ''))) not in ('vendido', 'vendida')
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
    if pending_count <= 0 then continue; end if;

    insert into public.crm_notification_outbox(recipient_id, kind, title, body, url, payload)
    select recipient.recipient_id, 'property_document_reminder',
      'Documentos pendentes do imovel',
      property_row.title || ' possui ' || pending_count || ' documento(s) pendente(s). Anexe todos assim que possivel.',
      '/imoveis',
      jsonb_build_object('propertyId',property_row.external_id,'pendingDocuments',pending_count,'requiredDocuments',9,'documentSet','property')
    from (
      select property_row.capturer_id as recipient_id where property_row.capturer_id is not null
      union
      select profile.id from public.profiles profile
      where lower(trim(profile.email))='unassigned-institutional@example.invalid'
    ) recipient;
    get diagnostics inserted_count = row_count;
    created_count := created_count + inserted_count;
  end loop;
  return created_count;
end;
$$;

revoke all on function public.process_property_document_reminders()
  from public, anon, authenticated;
grant execute on function public.process_property_document_reminders() to service_role;

-- Remove reminders that may already be waiting in the outbox for a sold property.
delete from public.crm_notification_outbox as notification
using public.crm_property_catalog as catalog
where notification.kind = 'property_document_reminder'
  and notification.payload ->> 'propertyId' = catalog.external_id
  and lower(trim(coalesce(catalog.status, ''))) in ('vendido', 'vendida');

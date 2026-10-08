-- Documentos pendentes ficam no painel de validacao do Allyson, sem notificacao pessoal.
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
      recipient_id, kind, title, body, url, payload
    )
    select
      recipient.recipient_id,
      'property_document_reminder',
      'Documentos pendentes do imovel',
      property_row.title || ' possui ' || pending_count
        || ' documento(s) pendente(s). Anexe todos assim que possivel.',
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
        and lower(trim(profile.email)) <> 'crmsoniaallyson@gmail.com'
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
      recipient_id, kind, title, body, url, payload
    )
    select
      recipient.recipient_id,
      'lead_proposal_document_reminder',
      'Documentos pendentes da proposta',
      'A proposta de ' || lead_row.name || ' possui ' || pending_count
        || ' documento(s) pendente(s). Os nove anexos da proposta devem ser enviados novamente.',
      '/leads',
      jsonb_build_object(
        'leadId', lead_row.id,
        'pendingDocuments', pending_count,
        'requiredDocuments', 9,
        'documentSet', 'proposal'
      )
    from (
      select lead_row.owner_id as recipient_id
      where lead_row.owner_id is not null
      union
      select profile.id
      from public.profiles as profile
      where profile.role = 'admin'
        and lower(trim(profile.email)) <> 'crmsoniaallyson@gmail.com'
    ) as recipient;

    get diagnostics inserted_count = row_count;
    created_count := created_count + inserted_count;
  end loop;

  return created_count;
end;
$$;

-- Remove do sino do Allyson os lembretes documentais ja criados.
delete from public.crm_notification_outbox as notification
using public.profiles as profile
where notification.recipient_id = profile.id
  and lower(trim(profile.email)) = 'crmsoniaallyson@gmail.com'
  and notification.kind in (
    'property_document_reminder',
    'lead_proposal_document_reminder'
  );

-- Leitura dedicada evita que uma falha de RLS esconda propostas pendentes na Validacao.
create or replace function public.get_property_value_reviews_for_validation()
returns setof public.crm_property_value_reviews
language sql
security definer
set search_path = pg_catalog, public
as $$
  select review.*
  from public.crm_property_value_reviews as review
  where public.is_allyson_admin()
  order by
    case when review.approval_status = 'pending' then 0 else 1 end,
    review.requested_at desc
  limit 100;
$$;

revoke all on function public.process_property_document_reminders()
  from public, anon, authenticated;
grant execute on function public.process_property_document_reminders()
  to service_role;
revoke all on function public.process_lead_proposal_document_reminders()
  from public, anon, authenticated;
grant execute on function public.process_lead_proposal_document_reminders()
  to service_role;
revoke all on function public.get_property_value_reviews_for_validation()
  from public, anon;
grant execute on function public.get_property_value_reviews_for_validation()
  to authenticated;

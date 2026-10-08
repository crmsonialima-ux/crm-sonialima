-- The capturer is deliberately stored outside the property catalog and Sheets.
-- Creating this table does not update or assign any existing property.
create table if not exists public.crm_property_capturer_assignments (
  property_id text primary key references public.crm_property_document_responsibilities(external_id) on delete cascade,
  broker_id uuid not null references public.profiles(id) on delete restrict,
  broker_name text not null,
  set_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.crm_property_capturer_assignments enable row level security;
revoke all on public.crm_property_capturer_assignments from public, anon, authenticated;

drop policy if exists "Allyson and accesscrm read property capturers"
  on public.crm_property_capturer_assignments;
create policy "Allyson and accesscrm read property capturers"
  on public.crm_property_capturer_assignments
  for select to authenticated
  using (public.is_allyson_admin() or public.is_restricted_admin());

create or replace function public.get_property_capturer_assignments()
returns table (property_id text, broker_id uuid, broker_name text)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
begin
  if not (public.is_allyson_admin() or public.is_restricted_admin()) then
    raise exception 'Somente Allyson e acessocrm podem ver o corretor captador.';
  end if;

  return query
  select assignment.property_id, assignment.broker_id, assignment.broker_name
  from public.crm_property_capturer_assignments as assignment
  order by assignment.property_id;
end;
$$;

create or replace function public.set_property_capturer(
  p_property_id text,
  p_broker_id uuid
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  normalized_property_id text := nullif(trim(p_property_id), '');
  selected_broker_name text;
begin
  if not (public.is_allyson_admin() or public.is_restricted_admin()) then
    raise exception 'Somente Allyson e acessocrm podem selecionar o corretor captador.';
  end if;
  if normalized_property_id is null then
    raise exception 'Imovel invalido.';
  end if;
  if not exists (
    select 1 from public.crm_property_document_responsibilities
    where external_id = normalized_property_id
  ) then
    raise exception 'Imovel nao encontrado no catalogo de documentos.';
  end if;

  if p_broker_id is null then
    delete from public.crm_property_capturer_assignments
    where property_id = normalized_property_id;
    return;
  end if;

  select coalesce(nullif(trim(profile.full_name), ''), profile.email)
  into selected_broker_name
  from public.profiles as profile
  where profile.id = p_broker_id and profile.role = 'broker';

  if selected_broker_name is null then
    raise exception 'Corretor captador invalido.';
  end if;

  insert into public.crm_property_capturer_assignments (
    property_id, broker_id, broker_name, set_by
  ) values (
    normalized_property_id, p_broker_id, selected_broker_name, auth.uid()
  )
  on conflict (property_id) do update set
    broker_id = excluded.broker_id,
    broker_name = excluded.broker_name,
    set_by = excluded.set_by,
    updated_at = now();
end;
$$;

revoke all on function public.get_property_capturer_assignments()
  from public, anon;
grant execute on function public.get_property_capturer_assignments()
  to authenticated;
revoke all on function public.set_property_capturer(text, uuid)
  from public, anon;
grant execute on function public.set_property_capturer(text, uuid)
  to authenticated;

-- Pending property documents notify only the selected capturer and accesscrm.
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
    select responsibility.external_id, responsibility.title, capturer.broker_id as capturer_id
    from public.crm_property_document_responsibilities as responsibility
    left join public.crm_property_capturer_assignments as capturer
      on capturer.property_id = responsibility.external_id
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

    insert into public.crm_notification_outbox (
      recipient_id, kind, title, body, url, payload
    )
    select recipient.recipient_id,
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
      select property_row.capturer_id as recipient_id
      where property_row.capturer_id is not null
      union
      select profile.id
      from public.profiles as profile
      where lower(trim(profile.email)) = 'unassigned-institutional@example.invalid'
    ) as recipient;

    get diagnostics inserted_count = row_count;
    created_count := created_count + inserted_count;
  end loop;
  return created_count;
end;
$$;

-- Proposal documents notify only the lead owner and accesscrm.
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
    select id, owner_id, name from public.crm_leads where stage = 'Proposta'
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

    insert into public.crm_notification_outbox (
      recipient_id, kind, title, body, url, payload
    )
    select recipient.recipient_id,
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
      select lead_row.owner_id as recipient_id where lead_row.owner_id is not null
      union
      select profile.id
      from public.profiles as profile
      where lower(trim(profile.email)) = 'unassigned-institutional@example.invalid'
    ) as recipient;

    get diagnostics inserted_count = row_count;
    created_count := created_count + inserted_count;
  end loop;
  return created_count;
end;
$$;

revoke all on function public.process_property_document_reminders()
  from public, anon, authenticated;
grant execute on function public.process_property_document_reminders()
  to service_role;
revoke all on function public.process_lead_proposal_document_reminders()
  from public, anon, authenticated;
grant execute on function public.process_lead_proposal_document_reminders()
  to service_role;

-- Remove previously generated reminders from recipients that are no longer
-- eligible. This only cleans notifications; it does not update any property.
delete from public.crm_notification_outbox as notification
where notification.kind = 'property_document_reminder'
  and not exists (
    select 1 from public.profiles as profile
    where profile.id = notification.recipient_id
      and lower(trim(profile.email)) = 'unassigned-institutional@example.invalid'
  )
  and not exists (
    select 1 from public.crm_property_capturer_assignments as assignment
    where assignment.property_id = notification.payload ->> 'propertyId'
      and assignment.broker_id = notification.recipient_id
  );

delete from public.crm_notification_outbox as notification
where notification.kind = 'lead_proposal_document_reminder'
  and not exists (
    select 1 from public.profiles as profile
    where profile.id = notification.recipient_id
      and lower(trim(profile.email)) = 'unassigned-institutional@example.invalid'
  )
  and not exists (
    select 1 from public.crm_leads as lead
    where lead.id::text = notification.payload ->> 'leadId'
      and lead.owner_id = notification.recipient_id
  );

-- Include capturer changes in Allyson's permanent audit trail.
drop trigger if exists notify_allyson_user_action
  on public.crm_property_capturer_assignments;
create trigger notify_allyson_user_action
after insert or update or delete on public.crm_property_capturer_assignments
for each row execute function public.notify_allyson_of_user_action();

drop trigger if exists zz_enrich_allyson_user_action
  on public.crm_property_capturer_assignments;
create trigger zz_enrich_allyson_user_action
after update on public.crm_property_capturer_assignments
for each row execute function public.enrich_allyson_user_action_changes();

drop trigger if exists persist_crm_user_action_history
  on public.crm_property_capturer_assignments;
create trigger persist_crm_user_action_history
after insert or update or delete on public.crm_property_capturer_assignments
for each row execute function public.persist_crm_user_action_history();

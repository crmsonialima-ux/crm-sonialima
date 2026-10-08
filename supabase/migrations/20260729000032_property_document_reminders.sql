-- Responsável pelos documentos de cada imóvel sincronizado da planilha.
create table if not exists public.crm_property_document_responsibilities (
  external_id text primary key,
  title text not null,
  broker_id uuid references public.profiles(id) on delete set null,
  broker_name text,
  updated_at timestamptz not null default now()
);

alter table public.crm_property_document_responsibilities enable row level security;
grant select on public.crm_property_document_responsibilities to authenticated;
create policy "Users read property document responsibilities"
  on public.crm_property_document_responsibilities for select
  using (auth.uid() is not null);

create or replace function public.sync_property_document_responsibilities(p_properties jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  item jsonb;
  property_id text;
  responsible_id uuid;
  synced integer := 0;
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores podem sincronizar responsabilidades de imóveis.';
  end if;

  for item in select value from jsonb_array_elements(coalesce(p_properties, '[]'::jsonb)) loop
    property_id := nullif(trim(item ->> 'external_id'), '');
    if property_id is null then continue; end if;

    select id into responsible_id
    from public.profiles
    where role = 'broker'
      and lower(trim(full_name)) = lower(trim(coalesce(item ->> 'broker_name', '')))
    limit 1;

    insert into public.crm_property_document_responsibilities (external_id, title, broker_id, broker_name, updated_at)
    values (
      property_id,
      coalesce(nullif(trim(item ->> 'title'), ''), property_id),
      responsible_id,
      nullif(trim(item ->> 'broker_name'), ''),
      now()
    )
    on conflict (external_id) do update set
      title = excluded.title,
      broker_id = excluded.broker_id,
      broker_name = excluded.broker_name,
      updated_at = now();
    synced := synced + 1;
  end loop;
  return synced;
end;
$$;

-- Cria um aviso para cada imóvel que não possua todos os nove documentos obrigatórios.
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
  created_count integer := 0;
begin
  for property_row in
    select external_id, title, broker_id
    from public.crm_property_document_responsibilities
    where broker_id is not null
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

    insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
    values (
      property_row.broker_id,
      'property_document_reminder',
      'Documentos pendentes do imóvel',
      property_row.title || ' possui ' || pending_count || ' documento(s) pendente(s). Anexe-os assim que possível.',
      '/imoveis',
      jsonb_build_object('propertyId', property_row.external_id, 'pendingDocuments', pending_count)
    );
    created_count := created_count + 1;
  end loop;
  return created_count;
end;
$$;

grant execute on function public.sync_property_document_responsibilities(jsonb) to service_role;
grant execute on function public.process_property_document_reminders() to service_role;

-- O banco opera em UTC: 13:30 e 19:00 correspondem a 10:30 e 16:00 em Brasília.
select cron.schedule(
  'property-document-reminder-morning',
  '30 13 * * *',
  $$select public.process_property_document_reminders();$$
);

select cron.schedule(
  'property-document-reminder-afternoon',
  '0 19 * * *',
  $$select public.process_property_document_reminders();$$
);

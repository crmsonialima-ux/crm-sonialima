-- Notify Allyson about every meaningful CRM mutation made by another signed-in
-- user. System/background writes have no auth.uid() and are intentionally
-- ignored, as are Allyson's own actions.
create or replace function public.notify_allyson_of_user_action()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  actor_id uuid := auth.uid();
  allyson_id uuid;
  actor_label text;
  source_data jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  previous_data jsonb := case when tg_op = 'UPDATE' then to_jsonb(old) else '{}'::jsonb end;
  area_label text;
  action_label text;
  entity_label text;
  entity_id text;
  target_url text := '/';
  changed_fields jsonb := '[]'::jsonb;
begin
  if actor_id is null or public.is_allyson_admin() then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  select profile.id
  into allyson_id
  from public.profiles as profile
  where profile.role = 'admin'
    and lower(trim(profile.email)) = 'crmsoniaallyson@gmail.com'
  limit 1;

  if allyson_id is null then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  select coalesce(nullif(trim(profile.full_name), ''), profile.email, actor_id::text)
  into actor_label
  from public.profiles as profile
  where profile.id = actor_id;
  actor_label := coalesce(actor_label, actor_id::text);

  area_label := case tg_table_name
    when 'crm_leads' then 'lead'
    when 'crm_lead_activities' then 'andamento do lead'
    when 'crm_property_catalog' then 'imóvel'
    when 'crm_property_public_links' then 'link do imóvel'
    when 'crm_property_reviewability' then 'classificação do imóvel'
    when 'crm_property_value_reviews' then 'revisão de valor do imóvel'
    when 'crm_property_document_responsibilities' then 'responsável por documentos do imóvel'
    when 'crm_property_document_clearance_status' then 'documentação do imóvel'
    when 'crm_agenda_entries' then 'agenda'
    when 'crm_marketing_campaigns' then 'marketing'
    when 'crm_daily_broker_revenue' then 'preenchimento diário'
    when 'crm_portal_lead_integrations' then 'integração de portal'
    when 'crm_assignment_test_runs' then 'teste de distribuição'
    when 'crm_assignment_test_attempts' then 'tentativa de distribuição'
    when 'profiles' then 'acesso de usuário'
    else replace(tg_table_name, '_', ' ')
  end;

  target_url := case
    when tg_table_name in ('crm_leads', 'crm_lead_activities') then '/leads'
    when tg_table_name like 'crm_property_%' then '/imoveis'
    when tg_table_name = 'crm_agenda_entries' then '/agenda'
    when tg_table_name = 'crm_marketing_campaigns' then '/marketing'
    when tg_table_name = 'crm_daily_broker_revenue' then '/preenchimento-diario'
    when tg_table_name = 'profiles' then '/corretores'
    else '/'
  end;

  action_label := case tg_op
    when 'INSERT' then 'cadastrou'
    when 'UPDATE' then 'alterou'
    when 'DELETE' then 'excluiu'
  end;

  entity_id := coalesce(
    source_data ->> 'id',
    source_data ->> 'external_id',
    source_data ->> 'property_id',
    source_data ->> 'lead_id',
    source_data ->> 'broker_id'
  );
  entity_label := coalesce(
    nullif(source_data ->> 'name', ''),
    nullif(source_data ->> 'title', ''),
    nullif(source_data ->> 'full_name', ''),
    nullif(source_data ->> 'property_interest', ''),
    nullif(source_data ->> 'stage', ''),
    nullif(source_data ->> 'campaign_name', ''),
    entity_id
  );

  if tg_op = 'UPDATE' then
    select coalesce(jsonb_agg(field.key order by field.key), '[]'::jsonb)
    into changed_fields
    from jsonb_each(source_data) as field
    where field.key not in ('updated_at', 'created_at')
      and source_data -> field.key is distinct from previous_data -> field.key;

    if changed_fields = '[]'::jsonb then
      return new;
    end if;
  end if;

  insert into public.crm_notification_outbox (
    recipient_id,
    kind,
    title,
    body,
    url,
    payload
  ) values (
    allyson_id,
    'allyson_user_activity',
    initcap(area_label) || ' ' ||
      case tg_op when 'INSERT' then 'cadastrado' when 'UPDATE' then 'alterado' else 'excluído' end,
    actor_label || ' ' || action_label || ' ' || area_label ||
      case when entity_label is not null then ' · ' || entity_label else '' end || '.',
    target_url,
    jsonb_build_object(
      'actorId', actor_id,
      'actorName', actor_label,
      'operation', lower(tg_op),
      'table', tg_table_name,
      'entityId', entity_id,
      'entityLabel', entity_label,
      'changedFields', changed_fields
    )
  );

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

-- File uploads and removals live in the Storage schema instead of a public CRM
-- table, so they receive a dedicated audit notification.
create or replace function public.notify_allyson_of_crm_file_action()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, storage
as $$
declare
  actor_id uuid := auth.uid();
  allyson_id uuid;
  actor_label text;
  object_data jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  bucket_name text := object_data ->> 'bucket_id';
  object_name text := object_data ->> 'name';
  target_url text;
begin
  if bucket_name not in (
    'property-documents',
    'lead-documents',
    'agenda-protocols',
    'agenda-vitor-documents'
  ) or actor_id is null or public.is_allyson_admin() then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  select profile.id
  into allyson_id
  from public.profiles as profile
  where profile.role = 'admin'
    and lower(trim(profile.email)) = 'crmsoniaallyson@gmail.com'
  limit 1;
  if allyson_id is null then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  select coalesce(nullif(trim(profile.full_name), ''), profile.email, actor_id::text)
  into actor_label
  from public.profiles as profile
  where profile.id = actor_id;
  actor_label := coalesce(actor_label, actor_id::text);
  target_url := case
    when bucket_name = 'property-documents' then '/imoveis'
    when bucket_name = 'lead-documents' then '/leads'
    else '/agenda'
  end;

  insert into public.crm_notification_outbox (
    recipient_id, kind, title, body, url, payload
  ) values (
    allyson_id,
    'allyson_user_activity',
    case when tg_op = 'INSERT' then 'Documento enviado' else 'Documento excluído' end,
    actor_label || case when tg_op = 'INSERT' then ' enviou ' else ' excluiu ' end ||
      'um documento · ' || coalesce(object_name, bucket_name) || '.',
    target_url,
    jsonb_build_object(
      'actorId', actor_id,
      'actorName', actor_label,
      'operation', lower(tg_op),
      'bucket', bucket_name,
      'objectName', object_name
    )
  );

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

revoke all on function public.notify_allyson_of_crm_file_action()
  from public, anon, authenticated;

drop trigger if exists notify_allyson_crm_file_action on storage.objects;
create trigger notify_allyson_crm_file_action
after insert or delete on storage.objects
for each row execute function public.notify_allyson_of_crm_file_action();

revoke all on function public.notify_allyson_of_user_action()
  from public, anon, authenticated;

do $$
declare
  table_name text;
  tracked_tables constant text[] := array[
    'crm_leads',
    'crm_lead_activities',
    'crm_property_catalog',
    'crm_property_public_links',
    'crm_property_reviewability',
    'crm_property_value_reviews',
    'crm_property_document_responsibilities',
    'crm_property_document_clearance_status',
    'crm_agenda_entries',
    'crm_marketing_campaigns',
    'crm_daily_broker_revenue',
    'crm_portal_lead_integrations',
    'crm_assignment_test_runs',
    'crm_assignment_test_attempts',
    'profiles'
  ];
begin
  foreach table_name in array tracked_tables loop
    if to_regclass('public.' || table_name) is null then
      continue;
    end if;
    execute format('drop trigger if exists notify_allyson_user_action on public.%I', table_name);
    execute format(
      'create trigger notify_allyson_user_action after insert or update or delete on public.%I for each row execute function public.notify_allyson_of_user_action()',
      table_name
    );
  end loop;
end;
$$;

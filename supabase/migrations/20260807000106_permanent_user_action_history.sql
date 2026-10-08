-- Permanent, searchable history of every meaningful action made by a signed-in
-- CRM user other than Allyson. Notification dismissal never affects this table.
create table if not exists public.crm_user_action_history (
  id bigint generated always as identity primary key,
  -- Deliberately no foreign key: a historical actor must remain identifiable
  -- even when the corresponding profile no longer exists.
  actor_id uuid,
  actor_name text not null,
  actor_email text,
  operation text not null check (operation in ('insert', 'update', 'delete')),
  area text not null,
  source_table text not null,
  entity_id text,
  entity_label text,
  before_data jsonb not null default '{}'::jsonb,
  after_data jsonb not null default '{}'::jsonb,
  changes jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now()
);

create index if not exists crm_user_action_history_occurred_idx
  on public.crm_user_action_history (occurred_at desc, id desc);
create index if not exists crm_user_action_history_area_idx
  on public.crm_user_action_history (area, occurred_at desc);
create index if not exists crm_user_action_history_actor_idx
  on public.crm_user_action_history (actor_id, occurred_at desc);

alter table public.crm_user_action_history enable row level security;
revoke all on public.crm_user_action_history from public, anon, authenticated;
grant select on public.crm_user_action_history to authenticated;

drop policy if exists "Only Allyson reads permanent action history"
  on public.crm_user_action_history;
create policy "Only Allyson reads permanent action history"
  on public.crm_user_action_history
  for select to authenticated
  using (public.is_allyson_admin());

create or replace function public.redact_crm_history_data(p_data jsonb)
returns jsonb
language sql
immutable
set search_path = pg_catalog
as $$
  select coalesce(p_data, '{}'::jsonb) - array[
    'password', 'secret', 'token', 'access_token', 'refresh_token',
    'api_key', 'apikey', 'signing_secret', 'webhook_secret'
  ]::text[];
$$;

revoke all on function public.redact_crm_history_data(jsonb)
  from public, anon, authenticated;

create or replace function public.prevent_crm_history_mutation()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  raise exception 'O histórico permanente de ações não pode ser alterado ou excluído.';
end;
$$;

revoke all on function public.prevent_crm_history_mutation()
  from public, anon, authenticated;

drop trigger if exists prevent_crm_history_mutation
  on public.crm_user_action_history;
create trigger prevent_crm_history_mutation
before update or delete on public.crm_user_action_history
for each row execute function public.prevent_crm_history_mutation();

create or replace function public.persist_crm_user_action_history()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  current_actor_id uuid := auth.uid();
  actor_label text;
  actor_mail text;
  raw_before jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else '{}'::jsonb end;
  raw_after jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) else '{}'::jsonb end;
  safe_before jsonb;
  safe_after jsonb;
  changed_values jsonb := '{}'::jsonb;
  area_label text;
  record_id text;
  record_label text;
begin
  if current_actor_id is null or public.is_allyson_admin() then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  select
    coalesce(nullif(trim(profile.full_name), ''), profile.email, current_actor_id::text),
    profile.email
  into actor_label, actor_mail
  from public.profiles as profile
  where profile.id = current_actor_id;
  actor_label := coalesce(actor_label, current_actor_id::text);

  safe_before := public.redact_crm_history_data(raw_before);
  safe_after := public.redact_crm_history_data(raw_after);

  if tg_op = 'UPDATE' then
    select coalesce(
      jsonb_object_agg(
        field.key,
        jsonb_build_object(
          'before', safe_before -> field.key,
          'after', safe_after -> field.key
        ) order by field.key
      ),
      '{}'::jsonb
    )
    into changed_values
    from jsonb_each(safe_after) as field
    where field.key not in ('updated_at', 'created_at')
      and safe_after -> field.key is distinct from safe_before -> field.key;

    if changed_values = '{}'::jsonb then return new; end if;
  end if;

  area_label := case tg_table_name
    when 'crm_leads' then 'lead'
    when 'crm_lead_activities' then 'lead'
    when 'crm_property_catalog' then 'imóvel'
    when 'crm_property_public_links' then 'imóvel'
    when 'crm_property_reviewability' then 'imóvel'
    when 'crm_property_value_reviews' then 'imóvel'
    when 'crm_property_document_responsibilities' then 'imóvel'
    when 'crm_property_document_clearance_status' then 'imóvel'
    when 'crm_agenda_entries' then 'agenda'
    when 'crm_marketing_campaigns' then 'marketing'
    when 'crm_daily_broker_revenue' then 'preenchimento diário'
    when 'crm_portal_lead_integrations' then 'integração'
    when 'crm_assignment_test_runs' then 'distribuição'
    when 'crm_assignment_test_attempts' then 'distribuição'
    when 'profiles' then 'usuário'
    else replace(tg_table_name, '_', ' ')
  end;

  record_id := coalesce(
    safe_after ->> 'id', safe_before ->> 'id',
    safe_after ->> 'external_id', safe_before ->> 'external_id',
    safe_after ->> 'property_id', safe_before ->> 'property_id',
    safe_after ->> 'lead_id', safe_before ->> 'lead_id'
  );
  record_label := coalesce(
    nullif(safe_after ->> 'name', ''), nullif(safe_before ->> 'name', ''),
    nullif(safe_after ->> 'title', ''), nullif(safe_before ->> 'title', ''),
    nullif(safe_after ->> 'full_name', ''), nullif(safe_before ->> 'full_name', ''),
    nullif(safe_after ->> 'property_interest', ''), nullif(safe_before ->> 'property_interest', ''),
    nullif(safe_after ->> 'stage', ''), nullif(safe_before ->> 'stage', ''),
    record_id
  );

  insert into public.crm_user_action_history (
    actor_id, actor_name, actor_email, operation, area, source_table,
    entity_id, entity_label, before_data, after_data, changes
  ) values (
    current_actor_id, actor_label, actor_mail, lower(tg_op), area_label, tg_table_name,
    record_id, record_label, safe_before, safe_after, changed_values
  );

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

revoke all on function public.persist_crm_user_action_history()
  from public, anon, authenticated;

do $$
declare
  table_name text;
  tracked_tables constant text[] := array[
    'crm_leads', 'crm_lead_activities', 'crm_property_catalog',
    'crm_property_public_links', 'crm_property_reviewability',
    'crm_property_value_reviews', 'crm_property_document_responsibilities',
    'crm_property_document_clearance_status', 'crm_agenda_entries',
    'crm_marketing_campaigns', 'crm_daily_broker_revenue',
    'crm_portal_lead_integrations', 'crm_assignment_test_runs',
    'crm_assignment_test_attempts', 'profiles'
  ];
begin
  foreach table_name in array tracked_tables loop
    if to_regclass('public.' || table_name) is null then continue; end if;
    execute format('drop trigger if exists persist_crm_user_action_history on public.%I', table_name);
    execute format(
      'create trigger persist_crm_user_action_history after insert or update or delete on public.%I for each row execute function public.persist_crm_user_action_history()',
      table_name
    );
  end loop;
end;
$$;

create or replace function public.persist_crm_file_action_history()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, storage
as $$
declare
  current_actor_id uuid := auth.uid();
  actor_label text;
  actor_mail text;
  file_row jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  bucket text := file_row ->> 'bucket_id';
  area_label text;
begin
  if current_actor_id is null or public.is_allyson_admin() then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  if bucket not in (
    'property-documents', 'lead-documents', 'agenda-protocols',
    'agenda-vitor-documents'
  ) then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  select
    coalesce(nullif(trim(profile.full_name), ''), profile.email, current_actor_id::text),
    profile.email
  into actor_label, actor_mail
  from public.profiles as profile
  where profile.id = current_actor_id;

  area_label := case
    when bucket = 'property-documents' then 'imóvel'
    when bucket = 'lead-documents' then 'lead'
    else 'agenda'
  end;

  insert into public.crm_user_action_history (
    actor_id, actor_name, actor_email, operation, area, source_table,
    entity_id, entity_label, before_data, after_data, changes
  ) values (
    current_actor_id,
    coalesce(actor_label, current_actor_id::text),
    actor_mail,
    lower(tg_op),
    area_label,
    'storage.objects',
    file_row ->> 'id',
    file_row ->> 'name',
    case when tg_op = 'DELETE' then public.redact_crm_history_data(file_row) else '{}'::jsonb end,
    case when tg_op = 'INSERT' then public.redact_crm_history_data(file_row) else '{}'::jsonb end,
    '{}'::jsonb
  );

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

revoke all on function public.persist_crm_file_action_history()
  from public, anon, authenticated;

drop trigger if exists persist_crm_file_action_history on storage.objects;
create trigger persist_crm_file_action_history
after insert or delete on storage.objects
for each row execute function public.persist_crm_file_action_history();

create or replace function public.search_crm_user_action_history(
  p_query text default null,
  p_area text default null,
  p_limit integer default 100,
  p_offset integer default 0
)
returns setof public.crm_user_action_history
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  normalized_query text := nullif(trim(p_query), '');
  normalized_area text := nullif(trim(p_area), '');
begin
  if not public.is_allyson_admin() then
    raise exception 'Somente Allyson pode consultar o histórico permanente.';
  end if;
  return query
  select history.*
  from public.crm_user_action_history as history
  where (normalized_area is null or history.area = normalized_area)
    and (
      normalized_query is null
      or history.actor_name ilike '%' || normalized_query || '%'
      or coalesce(history.actor_email, '') ilike '%' || normalized_query || '%'
      or coalesce(history.entity_label, '') ilike '%' || normalized_query || '%'
      or coalesce(history.entity_id, '') ilike '%' || normalized_query || '%'
      or history.source_table ilike '%' || normalized_query || '%'
      or history.changes::text ilike '%' || normalized_query || '%'
    )
  order by history.occurred_at desc, history.id desc
  limit least(greatest(coalesce(p_limit, 100), 1), 500)
  offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

revoke all on function public.search_crm_user_action_history(text, text, integer, integer)
  from public, anon;
grant execute on function public.search_crm_user_action_history(text, text, integer, integer)
  to authenticated;

-- Enrich every user-generated UPDATE notification with field-level before and
-- after values. Trigger names are ordered alphabetically, so this runs after
-- notify_allyson_user_action has inserted the base notification.
create or replace function public.enrich_allyson_user_action_changes()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  actor_id uuid := auth.uid();
  previous_data jsonb := to_jsonb(old);
  current_data jsonb := to_jsonb(new);
  changes jsonb;
  notification_id uuid;
begin
  if actor_id is null or public.is_allyson_admin() then
    return new;
  end if;

  select coalesce(
    jsonb_object_agg(
      field.key,
      jsonb_build_object(
        'before', previous_data -> field.key,
        'after', current_data -> field.key
      )
      order by field.key
    ),
    '{}'::jsonb
  )
  into changes
  from jsonb_each(current_data) as field
  where field.key not in ('updated_at', 'created_at')
    and current_data -> field.key is distinct from previous_data -> field.key;

  if changes = '{}'::jsonb then
    return new;
  end if;

  select notification.id
  into notification_id
  from public.crm_notification_outbox as notification
  where notification.recipient_id = (
      select profile.id
      from public.profiles as profile
      where profile.role = 'admin'
        and lower(trim(profile.email)) = 'crmsoniaallyson@gmail.com'
      limit 1
    )
    and notification.kind = 'allyson_user_activity'
    and notification.payload ->> 'actorId' = actor_id::text
    and notification.payload ->> 'table' = tg_table_name
    and notification.payload ->> 'operation' = 'update'
    and notification.created_at >= transaction_timestamp()
  order by notification.created_at desc, notification.id desc
  limit 1;

  if notification_id is not null then
    update public.crm_notification_outbox
    set payload = payload || jsonb_build_object('changes', changes)
    where id = notification_id;
  end if;

  return new;
end;
$$;

revoke all on function public.enrich_allyson_user_action_changes()
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
    execute format('drop trigger if exists zz_enrich_allyson_user_action on public.%I', table_name);
    execute format(
      'create trigger zz_enrich_allyson_user_action after update on public.%I for each row execute function public.enrich_allyson_user_action_changes()',
      table_name
    );
  end loop;
end;
$$;

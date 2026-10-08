-- Expand Allyson's immutable validation history to every business entity that
-- can be changed by a signed-in CRM user. System delivery telemetry remains in
-- crm_audit_events and the notification-specific validation views.
do $$
declare
  table_name text;
  tracked_tables constant text[] := array[
    'profiles',
    'crm_leads',
    'crm_lead_activities',
    'lead_assignment_attempts',
    'lead_distribution_queue',
    'crm_lead_registration_reminders',
    'crm_property_catalog',
    'crm_deleted_properties',
    'crm_property_broker_access',
    'crm_property_capturer_assignments',
    'crm_property_portal_references',
    'crm_property_public_links',
    'crm_property_reviewability',
    'crm_property_value_reviews',
    'crm_property_document_responsibilities',
    'crm_property_document_clearance_status',
    'crm_property_clearance_status',
    'crm_property_match_notifications',
    'crm_agenda_entries',
    'crm_agenda_entry_participants',
    'crm_marketing_campaigns',
    'crm_daily_broker_revenue',
    'crm_portal_lead_integrations',
    'crm_external_lead_receipts',
    'crm_assignment_test_runs',
    'crm_assignment_test_attempts',
    'push_subscriptions'
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

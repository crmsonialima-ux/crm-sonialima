-- Ferramenta temporaria, exclusiva do service_role, para o reset operacional solicitado.
create or replace function public.reset_crm_operational_data()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if auth.role() <> 'service_role' then
    raise exception 'Operacao exclusiva do service_role.';
  end if;

  truncate table
    public.crm_notification_delivery_attempts,
    public.crm_audit_events,
    public.crm_notification_outbox,
    public.crm_assignment_test_attempts,
    public.crm_assignment_test_runs,
    public.crm_agenda_requester_notification_events,
    public.crm_agenda_entries,
    public.crm_daily_broker_revenue,
    public.crm_external_lead_receipts,
    public.crm_lead_registration_reminders,
    public.crm_lead_activities,
    public.lead_assignment_attempts,
    public.crm_property_match_notifications,
    public.crm_leads,
    public.crm_property_value_reviews,
    public.crm_property_reviewability,
    public.crm_property_public_links,
    public.crm_property_document_clearance_status,
    public.crm_property_portal_references,
    public.crm_property_broker_access,
    public.crm_property_document_responsibilities,
    public.crm_property_catalog,
    public.crm_whatsapp_inbound_events
  restart identity cascade;

  update public.profiles
  set lead_distribution_blocked = false,
      lead_distribution_blocked_reason = null,
      lead_distribution_blocked_at = null;

  return jsonb_build_object(
    'ok', true,
    'resetAt', now(),
    'preservedProfiles', (select count(*) from public.profiles),
    'preservedQueues', (select count(*) from public.lead_distribution_queue),
    'preservedIntegrations', (select count(*) from public.crm_portal_lead_integrations)
  );
end;
$$;

revoke all on function public.reset_crm_operational_data()
  from public, anon, authenticated;
grant execute on function public.reset_crm_operational_data()
  to service_role;

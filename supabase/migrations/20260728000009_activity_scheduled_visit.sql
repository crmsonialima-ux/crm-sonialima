alter table public.crm_lead_activities
  add column if not exists scheduled_for timestamptz;

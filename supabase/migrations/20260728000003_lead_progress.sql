-- Dados operacionais do funil de atendimento para cada lead.
alter table public.crm_leads
  add column if not exists visit_scheduled_at timestamptz,
  add column if not exists visit_completed_at timestamptz,
  add column if not exists proposal_at timestamptz;

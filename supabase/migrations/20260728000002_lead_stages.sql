-- Novo padrão de estágio para leads criados no CRM.
alter table public.crm_leads
  alter column stage set default 'Em atendimento';

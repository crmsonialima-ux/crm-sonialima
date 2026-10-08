-- Permite que a tela administrativa consulte o status das integrações.
-- A RLS existente continua restringindo a leitura dos usuários ao admin.
grant select on table public.crm_portal_lead_integrations to authenticated;

-- As Edge Functions usam service_role para verificar se o recebimento está ativo.
grant select on table public.crm_portal_lead_integrations to service_role;

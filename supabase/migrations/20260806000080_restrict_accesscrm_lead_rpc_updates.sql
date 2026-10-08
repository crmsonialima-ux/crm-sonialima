-- Impede que funcoes SECURITY DEFINER contornem a restricao de edicao de leads.
-- O cadastro (INSERT) continua permitido; somente alteracoes em registros existentes
-- sao bloqueadas para unassigned-institutional@example.invalid.
create or replace function public.prevent_restricted_admin_lead_update()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if public.is_restricted_admin() then
    raise exception 'Seu acesso administrativo nao permite editar leads.';
  end if;
  return null;
end;
$$;

drop trigger if exists crm_leads_restrict_accesscrm_update
  on public.crm_leads;
create trigger crm_leads_restrict_accesscrm_update
before update on public.crm_leads
for each statement
execute function public.prevent_restricted_admin_lead_update();

revoke all on function public.prevent_restricted_admin_lead_update()
  from public, anon, authenticated;

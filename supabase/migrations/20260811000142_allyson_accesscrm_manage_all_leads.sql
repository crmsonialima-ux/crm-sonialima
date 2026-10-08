begin;

-- Remove o bloqueio legado que impedia o acesso CRM de atualizar qualquer lead.
drop trigger if exists crm_leads_restrict_accesscrm_update on public.crm_leads;

drop policy if exists "Full admins update every lead; brokers update their own without reassigning" on public.crm_leads;
create policy "Allyson and access CRM edit all leads; brokers update their own"
on public.crm_leads for update to authenticated
using (
  public.is_allyson_admin()
  or public.is_restricted_admin()
  or (not public.is_admin() and owner_id=auth.uid())
)
with check (
  public.is_allyson_admin()
  or public.is_restricted_admin()
  or (not public.is_admin() and owner_id=auth.uid())
);

drop policy if exists "Only full admins can delete leads" on public.crm_leads;
create policy "Only Allyson and access CRM delete leads"
on public.crm_leads for delete to authenticated
using (public.is_allyson_admin() or public.is_restricted_admin());

-- Autoriza tambem a transferencia direta pelo acesso CRM, mantendo todas as
-- travas operacionais da funcao atual.
do $$
declare definition text;
begin
  select pg_get_functiondef('public.transfer_lead_directly(uuid,uuid)'::regprocedure) into definition;
  if position('if not public.is_allyson_admin() then' in definition)=0 then
    raise exception 'Validacao da transferencia direta nao encontrada.';
  end if;
  definition:=replace(definition,
    'if not public.is_allyson_admin() then',
    'if not (public.is_allyson_admin() or public.is_restricted_admin()) then');
  definition:=replace(definition,
    'Somente Allyson pode transferir um lead diretamente.',
    'Somente Allyson e acesso CRM podem transferir um lead diretamente.');
  execute definition;
end $$;

commit;

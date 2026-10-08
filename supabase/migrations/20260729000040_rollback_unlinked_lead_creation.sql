-- Evita lead parcial no CRM caso o Google Apps Script rejeite a gravacao na planilha.
create or replace function public.rollback_unlinked_lead_creation(p_lead_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  previous_owner_id uuid;
begin
  select owner_id
  into previous_owner_id
  from public.crm_leads
  where id = p_lead_id
    and external_id is null
    and (created_by = auth.uid() or public.is_admin())
  for update;

  if previous_owner_id is null then
    raise exception 'Lead nao encontrado ou ja vinculado a planilha.';
  end if;

  delete from public.crm_notification_outbox
  where payload ->> 'leadId' = p_lead_id::text;

  delete from public.crm_leads
  where id = p_lead_id;

  perform public.refresh_broker_visit_block(previous_owner_id);
end;
$$;

grant execute on function public.rollback_unlinked_lead_creation(uuid) to authenticated;

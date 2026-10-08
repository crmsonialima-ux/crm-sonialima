-- Exclusão administrativa limpa dependências e recalcula o bloqueio do corretor dono do lead.
create or replace function public.delete_crm_lead(p_lead_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  previous_owner_id uuid;
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores podem excluir leads.';
  end if;

  select owner_id
  into previous_owner_id
  from public.crm_leads
  where id = p_lead_id
  for update;

  if previous_owner_id is null then
    raise exception 'Lead nao encontrado.';
  end if;

  -- Notificações usam payload JSON, portanto não possuem chave estrangeira para cascade.
  delete from public.crm_notification_outbox
  where payload ->> 'leadId' = p_lead_id::text;

  -- As relações com FK (atividades, tentativas e matches) são removidas por cascade.
  delete from public.crm_leads
  where id = p_lead_id;

  -- Se o bloqueio era causado somente por este lead, o corretor volta à fila imediatamente.
  perform public.refresh_broker_visit_block(previous_owner_id);
end;
$$;

grant execute on function public.delete_crm_lead(uuid) to authenticated;

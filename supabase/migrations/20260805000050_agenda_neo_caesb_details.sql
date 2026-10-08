-- Dados obrigatórios para demandas NEO Energia e Caesb.
alter table public.crm_agenda_entries
  add column if not exists demand_client_name text,
  add column if not exists demand_property_address text,
  add column if not exists demand_service text;

create or replace function public.create_service_agenda_entry(
  p_category public.agenda_category,
  p_scheduled_at timestamptz,
  p_client_name text,
  p_property_address text,
  p_service text,
  p_target_user_id uuid
)
returns uuid language plpgsql security definer set search_path = public as $$
declare derley uuid; entry_id uuid; summary text;
begin
  if auth.uid() is null then raise exception 'Sessão não encontrada.'; end if;
  if p_category not in ('neo_energia', 'caesb') then raise exception 'Categoria inválida para esta demanda.'; end if;
  select id into derley from public.profiles where lower(email) = 'unassigned-agenda@example.invalid' limit 1;
  if not public.is_admin() and p_target_user_id <> auth.uid() and p_target_user_id <> derley then
    raise exception 'Você só pode adicionar compromissos para si ou para Derley.';
  end if;
  if p_scheduled_at is null
    or nullif(trim(p_client_name), '') is null
    or nullif(trim(p_property_address), '') is null
    or nullif(trim(p_service), '') is null then
    raise exception 'Informe data, hora, cliente, endereço do imóvel e serviço.';
  end if;
  summary := 'Cliente: ' || trim(p_client_name) || E'\nImóvel: ' || trim(p_property_address) || E'\nServiço: ' || trim(p_service);
  insert into public.crm_agenda_entries (
    category, scheduled_at, observation, target_user_id, created_by,
    demand_client_name, demand_property_address, demand_service
  ) values (
    p_category, p_scheduled_at, summary, p_target_user_id, auth.uid(),
    trim(p_client_name), trim(p_property_address), trim(p_service)
  ) returning id into entry_id;
  if p_target_user_id <> auth.uid() then
    insert into public.crm_notification_outbox(recipient_id, kind, title, body, url, payload)
    values (p_target_user_id, 'agenda_new_demand', 'Nova demanda na Agenda', summary, '/agenda', jsonb_build_object('agendaId', entry_id));
  end if;
  return entry_id;
end;
$$;

grant execute on function public.create_service_agenda_entry(public.agenda_category,timestamptz,text,text,text,uuid) to authenticated;

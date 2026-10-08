-- Every authenticated CRM user can see Allyson as an Agenda target and submit
-- regular, NEO Energia or Caesb demands to his calendar. Cartorio keeps its
-- dedicated Derley workflow.
create or replace function public.list_agenda_profiles()
returns table (id uuid, full_name text, email text, role text)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select profile.id, profile.full_name, profile.email, profile.role::text
  from public.profiles as profile
  where (
    profile.role = 'broker'
    and exists (
      select 1 from public.lead_distribution_queue as queue
      where queue.broker_id = profile.id and queue.lead_type = 'Venda'
    )
    and exists (
      select 1 from public.lead_distribution_queue as queue
      where queue.broker_id = profile.id and queue.lead_type = 'Aluguel'
    )
  ) or (
    profile.role = 'admin'
    and lower(trim(profile.email)) = 'crmsoniaallyson@gmail.com'
  )
  order by
    case when lower(trim(profile.email)) = 'crmsoniaallyson@gmail.com' then 0 else 1 end,
    profile.full_name,
    profile.email;
$$;

revoke all on function public.list_agenda_profiles() from public, anon;
grant execute on function public.list_agenda_profiles() to authenticated;

create or replace function public.create_agenda_entry(
  p_category public.agenda_category,
  p_scheduled_at timestamptz,
  p_observation text,
  p_target_user_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  derley_id uuid;
  allyson_id uuid;
  entry_id uuid;
begin
  select id into derley_id from public.profiles
  where lower(trim(email)) = 'unassigned-agenda@example.invalid' limit 1;
  select id into allyson_id from public.profiles
  where role = 'admin' and lower(trim(email)) = 'crmsoniaallyson@gmail.com' limit 1;

  if auth.uid() is null then raise exception 'Sessão não encontrada.'; end if;
  if not public.is_admin()
     and p_target_user_id <> auth.uid()
     and p_target_user_id <> derley_id
     and p_target_user_id <> allyson_id then
    raise exception 'Você só pode adicionar compromissos para si, Derley ou Allyson.';
  end if;
  if p_scheduled_at is null or nullif(trim(p_observation), '') is null then
    raise exception 'Informe data, hora e observação.';
  end if;

  insert into public.crm_agenda_entries (
    category, scheduled_at, observation, target_user_id, created_by
  ) values (
    p_category, p_scheduled_at, trim(p_observation), p_target_user_id, auth.uid()
  ) returning id into entry_id;

  if p_target_user_id <> auth.uid() then
    insert into public.crm_notification_outbox (
      recipient_id, kind, title, body, url, payload
    ) values (
      p_target_user_id, 'agenda_new_demand', 'Nova demanda na Agenda',
      trim(p_observation), '/agenda', jsonb_build_object('agendaId', entry_id)
    );
  end if;
  return entry_id;
end;
$$;

create or replace function public.create_service_agenda_entry(
  p_category public.agenda_category,
  p_scheduled_at timestamptz,
  p_client_name text,
  p_property_address text,
  p_service text,
  p_target_user_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  derley_id uuid;
  allyson_id uuid;
  entry_id uuid;
  summary text;
begin
  if auth.uid() is null then raise exception 'Sessão não encontrada.'; end if;
  if p_category not in ('neo_energia', 'caesb') then
    raise exception 'Categoria inválida para esta demanda.';
  end if;
  select id into derley_id from public.profiles
  where lower(trim(email)) = 'unassigned-agenda@example.invalid' limit 1;
  select id into allyson_id from public.profiles
  where role = 'admin' and lower(trim(email)) = 'crmsoniaallyson@gmail.com' limit 1;

  if not public.is_admin()
     and p_target_user_id <> auth.uid()
     and p_target_user_id <> derley_id
     and p_target_user_id <> allyson_id then
    raise exception 'Você só pode adicionar compromissos para si, Derley ou Allyson.';
  end if;
  if p_scheduled_at is null
    or nullif(trim(p_client_name), '') is null
    or nullif(trim(p_property_address), '') is null
    or nullif(trim(p_service), '') is null then
    raise exception 'Informe data, hora, cliente, endereço do imóvel e serviço.';
  end if;

  summary := 'Cliente: ' || trim(p_client_name) || E'\nImóvel: ' ||
    trim(p_property_address) || E'\nServiço: ' || trim(p_service);
  insert into public.crm_agenda_entries (
    category, scheduled_at, observation, target_user_id, created_by,
    demand_client_name, demand_property_address, demand_service
  ) values (
    p_category, p_scheduled_at, summary, p_target_user_id, auth.uid(),
    trim(p_client_name), trim(p_property_address), trim(p_service)
  ) returning id into entry_id;

  if p_target_user_id <> auth.uid() then
    insert into public.crm_notification_outbox (
      recipient_id, kind, title, body, url, payload
    ) values (
      p_target_user_id, 'agenda_new_demand', 'Nova demanda na Agenda',
      summary, '/agenda', jsonb_build_object('agendaId', entry_id)
    );
  end if;
  return entry_id;
end;
$$;

revoke all on function public.create_agenda_entry(
  public.agenda_category, timestamptz, text, uuid
) from public, anon;
grant execute on function public.create_agenda_entry(
  public.agenda_category, timestamptz, text, uuid
) to authenticated;

revoke all on function public.create_service_agenda_entry(
  public.agenda_category, timestamptz, text, text, text, uuid
) from public, anon;
grant execute on function public.create_service_agenda_entry(
  public.agenda_category, timestamptz, text, text, text, uuid
) to authenticated;

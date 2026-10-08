-- Cada usuario gerencia somente demandas criadas por ele para a propria agenda.
-- Allyson conserva a administracao completa de todas as agendas.
create or replace function public.is_allyson_admin()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1
    from public.profiles as profile
    where profile.id = auth.uid()
      and profile.role = 'admin'
      and lower(trim(profile.email)) = 'crmsoniaallyson@gmail.com'
  );
$$;

revoke all on function public.is_allyson_admin() from public, anon;
grant execute on function public.is_allyson_admin() to authenticated, service_role;

create or replace function public.can_manage_agenda_entry(p_entry_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select public.is_allyson_admin()
    or exists (
      select 1
      from public.crm_agenda_entries as entry
      where entry.id = p_entry_id
        and entry.created_by = auth.uid()
        and entry.target_user_id = auth.uid()
    );
$$;

revoke all on function public.can_manage_agenda_entry(uuid) from public, anon;
grant execute on function public.can_manage_agenda_entry(uuid) to authenticated, service_role;

create or replace function public.update_agenda_entry(
  p_id uuid,
  p_category public.agenda_category,
  p_scheduled_at timestamptz,
  p_target_user_id uuid,
  p_observation text default null,
  p_client_name text default null,
  p_property_address text default null,
  p_cartorio_name text default null,
  p_service text default null
)
returns public.crm_agenda_entries
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  current_entry public.crm_agenda_entries;
  updated_entry public.crm_agenda_entries;
  summary text;
  derley_id uuid;
begin
  select * into current_entry
  from public.crm_agenda_entries
  where id = p_id
  for update;

  if not found then
    raise exception 'Demanda nao encontrada.';
  end if;

  if not public.can_manage_agenda_entry(p_id) then
    raise exception 'Voce pode alterar apenas demandas criadas por voce para a sua propria agenda.';
  end if;

  if not public.is_allyson_admin() and p_target_user_id <> auth.uid() then
    raise exception 'Voce nao pode transferir uma demanda para outra pessoa.';
  end if;

  if p_scheduled_at is null then
    raise exception 'Informe data e hora.';
  end if;

  if p_category = 'cartorio' then
    select profile.id into derley_id
    from public.profiles as profile
    where lower(trim(profile.email)) = 'unassigned-agenda@example.invalid'
    limit 1;

    if derley_id is null or p_target_user_id <> derley_id then
      raise exception 'Demandas de Cartorio devem permanecer na agenda do Derley.';
    end if;
    if nullif(trim(coalesce(p_client_name, '')), '') is null
       or nullif(trim(coalesce(p_property_address, '')), '') is null
       or nullif(trim(coalesce(p_cartorio_name, '')), '') is null
       or nullif(trim(coalesce(p_service, '')), '') is null then
      raise exception 'Informe cliente, imovel, cartorio e servico.';
    end if;
    summary := 'Cliente: ' || trim(p_client_name)
      || E'\nImovel: ' || trim(p_property_address)
      || E'\nCartorio: ' || trim(p_cartorio_name)
      || E'\nServico: ' || trim(p_service);
  elsif p_category in ('neo_energia', 'caesb') then
    if nullif(trim(coalesce(p_client_name, '')), '') is null
       or nullif(trim(coalesce(p_property_address, '')), '') is null
       or nullif(trim(coalesce(p_service, '')), '') is null then
      raise exception 'Informe cliente, imovel e servico.';
    end if;
    summary := 'Cliente: ' || trim(p_client_name)
      || E'\nImovel: ' || trim(p_property_address)
      || E'\nServico: ' || trim(p_service);
  else
    if nullif(trim(coalesce(p_observation, '')), '') is null then
      raise exception 'Informe a observacao ou motivo da demanda.';
    end if;
    summary := trim(p_observation);
  end if;

  update public.crm_agenda_entries
  set category = p_category,
      scheduled_at = p_scheduled_at,
      target_user_id = p_target_user_id,
      observation = summary,
      cartorio_client_name = case when p_category = 'cartorio' then trim(p_client_name) else null end,
      cartorio_property_address = case when p_category = 'cartorio' then trim(p_property_address) else null end,
      cartorio_name = case when p_category = 'cartorio' then trim(p_cartorio_name) else null end,
      cartorio_service = case when p_category = 'cartorio' then trim(p_service) else null end,
      demand_client_name = case when p_category in ('neo_energia', 'caesb') then trim(p_client_name) else null end,
      demand_property_address = case when p_category in ('neo_energia', 'caesb') then trim(p_property_address) else null end,
      demand_service = case when p_category in ('neo_energia', 'caesb') then trim(p_service) else null end,
      reminder_sent_at = case
        when scheduled_at is distinct from p_scheduled_at then null
        else reminder_sent_at
      end,
      updated_at = now()
  where id = p_id
  returning * into updated_entry;

  return updated_entry;
end;
$$;

revoke all on function public.update_agenda_entry(
  uuid,
  public.agenda_category,
  timestamptz,
  uuid,
  text,
  text,
  text,
  text,
  text
) from public, anon;
grant execute on function public.update_agenda_entry(
  uuid,
  public.agenda_category,
  timestamptz,
  uuid,
  text,
  text,
  text,
  text,
  text
) to authenticated;

create or replace function public.delete_agenda_entry(p_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.can_manage_agenda_entry(p_id) then
    raise exception 'Voce pode excluir apenas demandas criadas por voce para a sua propria agenda.';
  end if;

  delete from public.crm_agenda_entries
  where id = p_id;

  if not found then
    raise exception 'Demanda nao encontrada.';
  end if;
end;
$$;

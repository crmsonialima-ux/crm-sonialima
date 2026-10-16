begin;

-- crmallyson permanece administrador, mas tambem e corretor operacional.
-- Os dois RPCs abaixo precisam aceitar seu UUID mesmo que o role continue admin.
create or replace function public.sync_property_broker_access(
  p_property_id text,
  p_broker_names text[]
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  normalized_property_id text := nullif(trim(p_property_id), '');
  normalized_broker_names text[] := coalesce(p_broker_names, '{}'::text[]);
  crmallyson_id constant uuid := '37094db7-2457-48f2-8573-40c887e547e5';
begin
  if not public.can_manage_property_brokers() then
    raise exception 'Somente crmallyson pode alterar os corretores responsaveis.';
  end if;
  if normalized_property_id is null then
    raise exception 'Identificador do imovel e obrigatorio.';
  end if;
  if cardinality(normalized_broker_names) = 0 then
    raise exception 'Selecione ao menos um corretor responsavel.';
  end if;

  delete from public.crm_property_broker_access
  where property_id = normalized_property_id;

  insert into public.crm_property_broker_access (property_id, broker_id)
  select distinct normalized_property_id, profile.id
  from public.profiles as profile
  where (profile.role = 'broker' and profile.full_name = any(normalized_broker_names))
     or (profile.id = crmallyson_id and 'crmallyson' = any(normalized_broker_names))
     or (
       lower(trim(profile.email)) = 'unassigned-institutional@example.invalid'
       and 'SoniaLima' = any(normalized_broker_names)
     );

  if (select count(*) from public.crm_property_broker_access where property_id = normalized_property_id)
     <> cardinality(normalized_broker_names) then
    raise exception 'Um ou mais corretores selecionados nao foram encontrados.';
  end if;

  update public.crm_property_catalog
  set brokers = array_to_string(normalized_broker_names, ', '), updated_at = now()
  where external_id = normalized_property_id;
  if not found then
    raise exception 'Imovel nao encontrado.';
  end if;
end;
$$;

create or replace function public.set_property_capturers(
  p_property_id text,
  p_selections text[]
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  normalized_property_id text := nullif(trim(p_property_id), '');
  normalized_selections text[];
  selection text;
  selected_profile public.profiles%rowtype;
  selected_ids uuid[] := '{}'::uuid[];
  crmallyson_id constant uuid := '37094db7-2457-48f2-8573-40c887e547e5';
begin
  if not public.can_manage_property_brokers() then
    raise exception 'Somente crmallyson pode selecionar os captadores.';
  end if;
  if normalized_property_id is null or not exists (
    select 1 from public.crm_property_catalog where external_id = normalized_property_id
  ) then
    raise exception 'Imovel nao encontrado no catalogo.';
  end if;

  select array_agg(trim(item) order by ordinal)
  into normalized_selections
  from unnest(coalesce(p_selections, '{}'::text[])) with ordinality as input(item, ordinal)
  where nullif(trim(item), '') is not null;

  if coalesce(cardinality(normalized_selections), 0) not between 1 and 2 then
    raise exception 'Selecione um ou dois captadores.';
  end if;
  if cardinality(normalized_selections) = 2 and normalized_selections[1] = normalized_selections[2] then
    raise exception 'Escolha dois captadores diferentes.';
  end if;

  foreach selection in array normalized_selections loop
    selected_profile := null;
    begin
      select profile.* into selected_profile
      from public.profiles as profile
      where profile.id = case
          when selection = '__sonialima__' then (
            select institutional.id from public.profiles as institutional
            where lower(trim(institutional.email)) = 'unassigned-institutional@example.invalid'
            limit 1
          )
          else selection::uuid
        end
        and (
          profile.role = 'broker'
          or profile.id = crmallyson_id
          or (profile.role = 'admin' and lower(trim(profile.email)) = 'unassigned-institutional@example.invalid')
        );
    exception when invalid_text_representation then
      raise exception 'Captador invalido.';
    end;

    if selected_profile.id is null then raise exception 'Captador invalido.'; end if;
    if selected_profile.id = any(selected_ids) then raise exception 'Escolha dois captadores diferentes.'; end if;
    selected_ids := array_append(selected_ids, selected_profile.id);
  end loop;

  delete from public.crm_property_capturer_assignments
  where property_id = normalized_property_id;

  insert into public.crm_property_capturer_assignments (
    property_id, broker_id, broker_name, is_institutional, set_by
  )
  select
    normalized_property_id,
    profile.id,
    case
      when profile.id = crmallyson_id then 'crmallyson'
      when lower(trim(profile.email)) = 'unassigned-institutional@example.invalid' then 'SoniaLima'
      else coalesce(nullif(trim(profile.full_name), ''), profile.email)
    end,
    lower(trim(profile.email)) = 'unassigned-institutional@example.invalid',
    auth.uid()
  from public.profiles as profile
  where profile.id = any(selected_ids);
end;
$$;

revoke all on function public.sync_property_broker_access(text, text[]) from public, anon;
grant execute on function public.sync_property_broker_access(text, text[]) to authenticated, service_role;
revoke all on function public.set_property_capturers(text, text[]) from public, anon;
grant execute on function public.set_property_capturers(text, text[]) to authenticated, service_role;

commit;

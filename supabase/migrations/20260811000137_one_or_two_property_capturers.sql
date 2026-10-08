begin;

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
begin
  if not (public.is_allyson_admin() or public.is_restricted_admin()) then
    raise exception 'Somente Allyson e acesso CRM podem selecionar os captadores.';
  end if;
  if normalized_property_id is null or not exists (
    select 1
    from public.crm_property_catalog as catalog
    where catalog.external_id = normalized_property_id
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
  if cardinality(normalized_selections) = 2
     and normalized_selections[1] = normalized_selections[2] then
    raise exception 'Escolha dois captadores diferentes.';
  end if;

  foreach selection in array normalized_selections loop
    selected_profile := null;
    if selection = '__sonialima__' then
      select profile.*
      into selected_profile
      from public.profiles as profile
      where profile.role = 'admin'
        and lower(trim(profile.email)) = 'unassigned-institutional@example.invalid';
    else
      begin
        select profile.*
        into selected_profile
        from public.profiles as profile
        where profile.id = selection::uuid
          and profile.role = 'broker';
      exception when invalid_text_representation then
        raise exception 'Captador invalido.';
      end;
    end if;

    if selected_profile.id is null then
      raise exception 'Captador invalido.';
    end if;
    if selected_profile.id = any(selected_ids) then
      raise exception 'Escolha dois captadores diferentes.';
    end if;
    selected_ids := array_append(selected_ids, selected_profile.id);
  end loop;

  delete from public.crm_property_capturer_assignments as assignment
  where assignment.property_id = normalized_property_id;

  insert into public.crm_property_capturer_assignments (
    property_id, broker_id, broker_name, is_institutional, set_by
  )
  select
    normalized_property_id,
    profile.id,
    case
      when lower(trim(profile.email)) = 'unassigned-institutional@example.invalid' then 'SoniaLima'
      else coalesce(nullif(trim(profile.full_name), ''), profile.email)
    end,
    false,
    auth.uid()
  from public.profiles as profile
  where profile.id = any(selected_ids);
end;
$$;

revoke all on function public.set_property_capturers(text, text[])
  from public, anon;
grant execute on function public.set_property_capturers(text, text[])
  to authenticated;

commit;

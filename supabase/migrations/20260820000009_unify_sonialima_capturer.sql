-- SoniaLima é o perfil institucional acessocrm. O front-end sempre envia o
-- UUID desse perfil; por isso as duas RPCs de captação devem aceitá-lo como
-- captador, embora ele tenha papel administrativo no cadastro de perfis.
begin;

do $$
declare
  current_definition text;
  updated_definition text;
begin
  select pg_get_functiondef(
    'public.submit_property_authorization_phase1(text,jsonb,jsonb,uuid)'::regprocedure
  ) into current_definition;

  if current_definition is null then
    raise exception 'RPC de submissão inicial de imóvel não encontrada.';
  end if;

  updated_definition := regexp_replace(
    current_definition,
    'AND[[:space:]]+(profile[.])?role[[:space:]]*=[[:space:]]*''broker''',
    'AND (role = ''broker'' OR (role = ''admin'' AND lower(trim(email)) = ''unassigned-institutional@example.invalid''))',
    'g'
  );

  -- A função pode já ter sido atualizada em instalações anteriores. Nesse
  -- caso não a reescrevemos; a RPC de edição abaixo continua normalizando o
  -- mesmo perfil institucional.
  if updated_definition is distinct from current_definition then
    execute updated_definition;
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
begin
  if not public.can_manage_property_brokers() then
    raise exception 'Somente Allyson pode selecionar os captadores.';
  end if;

  if normalized_property_id is null or not exists (
    select 1
    from public.crm_property_catalog as catalog
    where catalog.external_id = normalized_property_id
  ) then
    raise exception 'Imóvel não encontrado no catálogo.';
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
    begin
      select profile.*
      into selected_profile
      from public.profiles as profile
      where profile.id = case
            when selection = '__sonialima__' then (
              select institutional.id
              from public.profiles as institutional
              where lower(trim(institutional.email)) = 'unassigned-institutional@example.invalid'
              limit 1
            )
            else selection::uuid
          end
        and (
          profile.role = 'broker'
          or (
            profile.role = 'admin'
            and lower(trim(profile.email)) = 'unassigned-institutional@example.invalid'
          )
        );
    exception when invalid_text_representation then
      raise exception 'Captador inválido.';
    end;

    if selected_profile.id is null then
      raise exception 'Captador inválido.';
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
    lower(trim(profile.email)) = 'unassigned-institutional@example.invalid',
    auth.uid()
  from public.profiles as profile
  where profile.id = any(selected_ids);
end;
$$;

revoke all on function public.submit_property_authorization_phase1(text, jsonb, jsonb, uuid)
  from public, anon;
grant execute on function public.submit_property_authorization_phase1(text, jsonb, jsonb, uuid)
  to authenticated, service_role;

revoke all on function public.set_property_capturers(text, text[]) from public, anon;
grant execute on function public.set_property_capturers(text, text[]) to authenticated, service_role;

commit;

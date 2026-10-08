begin;

-- SoniaLima passa a representar o perfil acessocrm como captador real.
update public.crm_property_capturer_assignments as assignment
set broker_id = access_profile.id,
    broker_name = 'SoniaLima',
    is_institutional = false,
    updated_at = now()
from public.profiles as access_profile
where assignment.is_institutional
  and lower(trim(access_profile.email)) = 'unassigned-institutional@example.invalid';

delete from public.crm_property_capturer_assignments as assignment
where assignment.broker_id is null;

alter table public.crm_property_capturer_assignments
  drop constraint if exists crm_property_capturer_assignments_mode_check;
alter table public.crm_property_capturer_assignments
  alter column broker_id set not null;
alter table public.crm_property_capturer_assignments
  drop constraint if exists crm_property_capturer_assignments_pkey;
alter table public.crm_property_capturer_assignments
  add constraint crm_property_capturer_assignments_pkey primary key (property_id, broker_id);

-- Imoveis que tinham um captador individual recebem SoniaLima como segundo
-- captador, preservando integralmente a selecao que ja existia.
insert into public.crm_property_capturer_assignments (
  property_id, broker_id, broker_name, is_institutional, set_by
)
select
  assignment.property_id,
  access_profile.id,
  'SoniaLima',
  false,
  assignment.set_by
from public.crm_property_capturer_assignments as assignment
join public.profiles as access_profile
  on lower(trim(access_profile.email)) = 'unassigned-institutional@example.invalid'
where assignment.broker_id <> access_profile.id
  and not exists (
    select 1
    from public.crm_property_capturer_assignments as existing
    where existing.property_id = assignment.property_id
      and existing.broker_id = access_profile.id
  )
on conflict do nothing;

drop function if exists public.get_property_capturer_assignments();
create function public.get_property_capturer_assignments()
returns table (property_id text, broker_id text, broker_name text)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
begin
  if not (public.is_allyson_admin() or public.is_restricted_admin()) then
    raise exception 'Somente Allyson e acesso CRM podem ver os captadores.';
  end if;

  return query
  select
    assignment.property_id,
    case
      when lower(trim(profile.email)) = 'unassigned-institutional@example.invalid'
        then '__sonialima__'
      else assignment.broker_id::text
    end,
    case
      when lower(trim(profile.email)) = 'unassigned-institutional@example.invalid'
        then 'SoniaLima'
      else assignment.broker_name
    end
  from public.crm_property_capturer_assignments as assignment
  join public.profiles as profile on profile.id = assignment.broker_id
  order by assignment.property_id,
    case when lower(trim(profile.email)) = 'unassigned-institutional@example.invalid' then 1 else 0 end,
    assignment.created_at;
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
  if not (public.is_allyson_admin() or public.is_restricted_admin()) then
    raise exception 'Somente Allyson e acesso CRM podem selecionar os captadores.';
  end if;
  if normalized_property_id is null or not exists (
    select 1 from public.crm_property_catalog as catalog
    where catalog.external_id = normalized_property_id
  ) then
    raise exception 'Imovel nao encontrado no catalogo.';
  end if;

  select array_agg(trim(item) order by ordinal)
  into normalized_selections
  from unnest(coalesce(p_selections, '{}'::text[])) with ordinality as input(item, ordinal)
  where nullif(trim(item), '') is not null;

  if coalesce(cardinality(normalized_selections), 0) <> 2
     or normalized_selections[1] = normalized_selections[2] then
    raise exception 'Selecione exatamente dois captadores diferentes.';
  end if;

  foreach selection in array normalized_selections loop
    if selection = '__sonialima__' then
      select profile.* into selected_profile
      from public.profiles as profile
      where profile.role = 'admin'
        and lower(trim(profile.email)) = 'unassigned-institutional@example.invalid';
    else
      begin
        select profile.* into selected_profile
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
      raise exception 'Selecione dois captadores diferentes.';
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

-- As funcoes antigas de selecao unica deixam de ser acessiveis pelo aplicativo.
revoke all on function public.set_property_capturer(text, uuid)
  from public, anon, authenticated;
revoke all on function public.set_property_capturer_selection(text, text)
  from public, anon, authenticated;
revoke all on function public.get_property_capturer_assignments()
  from public, anon;
grant execute on function public.get_property_capturer_assignments()
  to authenticated;
revoke all on function public.set_property_capturers(text, text[])
  from public, anon;
grant execute on function public.set_property_capturers(text, text[])
  to authenticated;

create or replace function public.process_property_document_reminders()
returns integer
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  property_row record;
  attached_count integer;
  pending_count integer;
  inserted_count integer;
  created_count integer := 0;
begin
  for property_row in
    select catalog.external_id, catalog.title
    from public.crm_property_catalog as catalog
    where lower(trim(coalesce(catalog.status, ''))) not in ('vendido', 'vendida')
      and lower(trim(translate(
        coalesce(catalog.purpose, ''),
        'Ã§Ã£Ã¡Ã Ã¢Ã©ÃªÃ­Ã³Ã´ÃµÃº',
        'caaaaeeiooou'
      ))) not in ('locacao', 'aluguel')
      and exists (
        select 1
        from public.crm_property_capturer_assignments as assignment
        where assignment.property_id = catalog.external_id
      )
  loop
    select count(distinct split_part(split_part(object.name, '/', 2), '.', 1))
    into attached_count
    from storage.objects as object
    where object.bucket_id = 'property-documents'
      and object.name like property_row.external_id || '/%'
      and split_part(split_part(object.name, '/', 2), '.', 1) in (
        'certidao-onus', 'certidao-iptu', 'pgfn', 'tjdft', 'trf1-criminal',
        'trf1-civil', 'trt10', 'tst', 'sefaz-df'
      );

    pending_count := 9 - coalesce(attached_count, 0);
    if pending_count <= 0 then
      continue;
    end if;

    insert into public.crm_notification_outbox (
      recipient_id, kind, title, body, url, payload
    )
    select
      recipient.id,
      'property_document_reminder',
      'Documentos pendentes do imovel',
      property_row.title || ' possui ' || pending_count
        || ' documento(s) pendente(s). Anexe todos assim que possivel.',
      '/imoveis',
      jsonb_build_object(
        'propertyId', property_row.external_id,
        'pendingDocuments', pending_count,
        'requiredDocuments', 9,
        'documentSet', 'property'
      )
    from (
      select assignment.broker_id as id
      from public.crm_property_capturer_assignments as assignment
      where assignment.property_id = property_row.external_id
      union
      select profile.id
      from public.profiles as profile
      where lower(trim(profile.email)) = 'unassigned-institutional@example.invalid'
    ) as recipient;

    get diagnostics inserted_count = row_count;
    created_count := created_count + inserted_count;
  end loop;

  return created_count;
end;
$$;

revoke all on function public.process_property_document_reminders()
  from public, anon, authenticated;
grant execute on function public.process_property_document_reminders()
  to service_role;

commit;

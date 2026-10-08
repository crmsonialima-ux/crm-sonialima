-- Institutional capturer mode keeps all existing property assignments intact.
alter table public.crm_property_capturer_assignments
  alter column broker_id drop not null;
alter table public.crm_property_capturer_assignments
  add column if not exists is_institutional boolean not null default false;

alter table public.crm_property_capturer_assignments
  drop constraint if exists crm_property_capturer_assignments_mode_check;
alter table public.crm_property_capturer_assignments
  add constraint crm_property_capturer_assignments_mode_check check (
    (is_institutional and broker_id is null)
    or (not is_institutional and broker_id is not null)
  );

drop function if exists public.get_property_capturer_assignments();
create function public.get_property_capturer_assignments()
returns table (property_id text, broker_id text, broker_name text)
language plpgsql stable security definer
set search_path = pg_catalog, public
as $$
begin
  if not (public.is_allyson_admin() or public.is_restricted_admin()) then
    raise exception 'Somente Allyson e acessocrm podem ver o corretor captador.';
  end if;
  return query
  select assignment.property_id,
    case when assignment.is_institutional then '__sonialima__'
      else assignment.broker_id::text end,
    case when assignment.is_institutional then 'SoniaLima'
      else assignment.broker_name end
  from public.crm_property_capturer_assignments assignment
  order by assignment.property_id;
end;
$$;

create or replace function public.set_property_capturer_selection(
  p_property_id text,
  p_selection text
)
returns void language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  normalized_property_id text := nullif(trim(p_property_id), '');
  normalized_selection text := nullif(trim(p_selection), '');
  selected_broker_id uuid;
  selected_broker_name text;
begin
  if not (public.is_allyson_admin() or public.is_restricted_admin()) then
    raise exception 'Somente Allyson e acessocrm podem selecionar o corretor captador.';
  end if;
  if normalized_property_id is null or not exists (
    select 1 from public.crm_property_document_responsibilities
    where external_id = normalized_property_id
  ) then raise exception 'Imovel invalido.'; end if;

  if normalized_selection is null then
    delete from public.crm_property_capturer_assignments
    where property_id = normalized_property_id;
    return;
  end if;

  if normalized_selection = '__sonialima__' then
    insert into public.crm_property_capturer_assignments(
      property_id, broker_id, broker_name, is_institutional, set_by
    ) values (normalized_property_id, null, 'SoniaLima', true, auth.uid())
    on conflict (property_id) do update set broker_id=null, broker_name='SoniaLima',
      is_institutional=true, set_by=excluded.set_by, updated_at=now();
    return;
  end if;

  begin selected_broker_id := normalized_selection::uuid;
  exception when invalid_text_representation then raise exception 'Corretor captador invalido.';
  end;
  select coalesce(nullif(trim(profile.full_name), ''), profile.email)
    into selected_broker_name from public.profiles profile
    where profile.id=selected_broker_id and profile.role='broker';
  if selected_broker_name is null then raise exception 'Corretor captador invalido.'; end if;

  insert into public.crm_property_capturer_assignments(
    property_id, broker_id, broker_name, is_institutional, set_by
  ) values (normalized_property_id, selected_broker_id, selected_broker_name, false, auth.uid())
  on conflict (property_id) do update set broker_id=excluded.broker_id,
    broker_name=excluded.broker_name, is_institutional=false,
    set_by=excluded.set_by, updated_at=now();
end;
$$;

revoke all on function public.get_property_capturer_assignments() from public, anon;
grant execute on function public.get_property_capturer_assignments() to authenticated;
revoke all on function public.set_property_capturer_selection(text, text) from public, anon;
grant execute on function public.set_property_capturer_selection(text, text) to authenticated;

-- The existing business-hours scheduler invokes this function three times daily.
create or replace function public.process_property_document_reminders()
returns integer language plpgsql security definer
set search_path = public, storage
as $$
declare property_row record; attached_count integer; pending_count integer;
  inserted_count integer; created_count integer := 0;
begin
  for property_row in
    select catalog.external_id, catalog.title, capturer.broker_id as capturer_id,
      coalesce(capturer.is_institutional, false) as is_institutional
    from public.crm_property_catalog catalog
    left join public.crm_property_capturer_assignments capturer
      on capturer.property_id=catalog.external_id
    where lower(trim(coalesce(catalog.status, ''))) not in ('vendido','vendida')
  loop
    select count(distinct split_part(split_part(name, '/', 2), '.', 1))
      into attached_count from storage.objects
      where bucket_id='property-documents' and name like property_row.external_id || '/%'
      and split_part(split_part(name, '/', 2), '.', 1) in (
        'certidao-onus','certidao-iptu','pgfn','tjdft','trf1-criminal',
        'trf1-civil','trt10','tst','sefaz-df');
    pending_count := 9-coalesce(attached_count,0);
    if pending_count <= 0 then continue; end if;

    insert into public.crm_notification_outbox(recipient_id,kind,title,body,url,payload)
    select recipient_id, 'property_document_reminder', 'Documentos pendentes do imovel',
      property_row.title || ' possui ' || pending_count || ' documento(s) pendente(s). Anexe todos assim que possivel.',
      '/imoveis', jsonb_build_object('propertyId',property_row.external_id,
        'pendingDocuments',pending_count,'requiredDocuments',9,'documentSet','property')
    from (
      select access.broker_id as recipient_id
      from public.crm_property_broker_access access
      join public.profiles profile on profile.id=access.broker_id and profile.role='broker'
      where property_row.is_institutional and access.property_id=property_row.external_id
      union
      select property_row.capturer_id where not property_row.is_institutional
        and property_row.capturer_id is not null
      union
      select profile.id from public.profiles profile
        where lower(trim(profile.email))='unassigned-institutional@example.invalid'
    ) recipients;
    get diagnostics inserted_count=row_count;
    created_count := created_count+inserted_count;
  end loop;
  return created_count;
end;
$$;

revoke all on function public.process_property_document_reminders()
  from public, anon, authenticated;
grant execute on function public.process_property_document_reminders() to service_role;

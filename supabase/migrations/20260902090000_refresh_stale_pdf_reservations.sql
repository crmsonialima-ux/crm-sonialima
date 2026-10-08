begin;

create or replace function public.reserve_property_authorization_pdf(p_property_id text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_is_authorized boolean := false;
  v_next_version integer;
  v_storage_path text;
  v_res_id uuid;
  v_existing_reserved public.crm_property_authorization_pdfs%rowtype;
begin
  if exists (
    select 1
    from public.crm_property_authorizations
    where property_id = p_property_id
      and submitted_by = auth.uid()
  ) then
    v_is_authorized := true;
  elsif exists (
    select 1
    from public.crm_property_capturer_assignments
    where property_id = p_property_id
      and broker_id = auth.uid()
  ) then
    v_is_authorized := true;
  elsif exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and role = 'admin'
      and (
        email ilike 'crmsoniaallyson@gmail.com'
        or email ilike 'unassigned-institutional@example.invalid'
      )
  ) then
    v_is_authorized := true;
  end if;

  if not v_is_authorized then
    raise exception 'Não autorizado a gerar PDF para este imóvel.';
  end if;

  if not exists (
    select 1
    from public.crm_property_authorizations
    where property_id = p_property_id
      and modalidade in ('Com exclusividade', 'Termo sem exclusividade')
  ) then
    raise exception 'A modalidade deste imóvel não possui termo de autorização para gerar.';
  end if;

  perform pg_advisory_xact_lock(hashtext('reserve_pdf:' || p_property_id));

  perform 1
  from public.crm_property_authorizations
  where property_id = p_property_id
  for update;

  select *
  into v_existing_reserved
  from public.crm_property_authorization_pdfs
  where property_id = p_property_id
    and status = 'RESERVED'
  order by version_number desc
  limit 1
  for update;

  if found then
    if v_existing_reserved.generated_by <> auth.uid() then
      raise exception 'Geração em andamento por outro usuário.';
    end if;

    -- A reserva pode ter enviado o arquivo e falhado antes da finalização.
    -- Nunca reutilize o caminho anterior: o Storage bloqueia sobrescritas.
    v_storage_path := p_property_id
      || '/pdfs/v'
      || v_existing_reserved.version_number
      || '_'
      || replace(gen_random_uuid()::text, '-', '')
      || '.pdf';

    update public.crm_property_authorization_pdfs
    set storage_path = v_storage_path
    where id = v_existing_reserved.id;

    return jsonb_build_object(
      'id', v_existing_reserved.id,
      'version', v_existing_reserved.version_number,
      'storage_path', v_storage_path
    );
  end if;

  select coalesce(max(version_number), 0) + 1
  into v_next_version
  from public.crm_property_authorization_pdfs
  where property_id = p_property_id;

  v_storage_path := p_property_id
    || '/pdfs/v'
    || v_next_version
    || '_'
    || replace(gen_random_uuid()::text, '-', '')
    || '.pdf';

  insert into public.crm_property_authorization_pdfs (
    property_id,
    generated_by,
    version_number,
    storage_path,
    status
  ) values (
    p_property_id,
    auth.uid(),
    v_next_version,
    v_storage_path,
    'RESERVED'
  )
  returning id into v_res_id;

  return jsonb_build_object(
    'id', v_res_id,
    'version', v_next_version,
    'storage_path', v_storage_path
  );
end;
$$;

revoke all on function public.reserve_property_authorization_pdf(text) from public, anon;
grant execute on function public.reserve_property_authorization_pdf(text) to authenticated;

commit;

-- Todos os acessos autenticados podem definir Consta/Nada consta por documento.
create or replace function public.set_property_document_clearance_status(
  p_property_id text,
  p_document_id text,
  p_status text
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if auth.uid() is null then
    raise exception 'Sessao nao encontrada.';
  end if;

  if p_document_id not in (
    'certidao-onus',
    'certidao-iptu',
    'pgfn',
    'tjdft',
    'trf1-criminal',
    'trf1-civil',
    'trt10',
    'tst',
    'sefaz-df'
  ) then
    raise exception 'Documento invalido.';
  end if;

  if nullif(trim(coalesce(p_status, '')), '') is null then
    delete from public.crm_property_document_clearance_status
    where property_id = p_property_id
      and document_id = p_document_id;
    return;
  end if;

  if p_status not in ('Nada consta', 'Consta') then
    raise exception 'Status invalido.';
  end if;

  insert into public.crm_property_document_clearance_status (
    property_id,
    document_id,
    status,
    updated_by,
    updated_at
  ) values (
    p_property_id,
    p_document_id,
    p_status,
    auth.uid(),
    now()
  )
  on conflict (property_id, document_id) do update set
    status = excluded.status,
    updated_by = excluded.updated_by,
    updated_at = excluded.updated_at;
end;
$$;

revoke all on function public.set_property_document_clearance_status(text, text, text)
  from public, anon;
grant execute on function public.set_property_document_clearance_status(text, text, text)
  to authenticated;

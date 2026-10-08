begin;

create or replace function public.finalize_property_authorization_pdf(
  p_property_id text,
  p_version integer,
  p_storage_path text
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_started_at timestamptz;
  v_res public.crm_property_authorization_pdfs%rowtype;
begin
  if not public.can_access_property_authorization(p_property_id, auth.uid()) then
    raise exception 'Não autorizado a finalizar PDF para este imóvel.';
  end if;

  if not exists (
    select 1
    from public.crm_property_authorizations
    where property_id = p_property_id
      and modalidade in ('Com exclusividade', 'Termo sem exclusividade')
  ) then
    raise exception 'A modalidade deste imóvel não possui termo de autorização para finalizar.';
  end if;

  if not exists (
    select 1
    from storage.objects
    where bucket_id = 'property-authorizations'
      and name = p_storage_path
      and lower(coalesce(metadata->>'mimetype', '')) = 'application/pdf'
  ) then
    raise exception 'Arquivo PDF válido não encontrado no storage.';
  end if;

  if p_storage_path not like p_property_id || '/pdfs/v' || p_version || '\_%' escape '\' then
    raise exception 'Caminho de armazenamento inválido ou não corresponde à versão.';
  end if;

  if right(lower(p_storage_path), 4) <> '.pdf' then
    raise exception 'O arquivo deve possuir extensão .pdf.';
  end if;

  select *
  into v_res
  from public.crm_property_authorization_pdfs
  where property_id = p_property_id
    and version_number = p_version
    and storage_path = p_storage_path
  for update;

  if not found then
    raise exception 'Reserva não encontrada.';
  end if;

  if v_res.status <> 'RESERVED' then
    raise exception 'Reserva inválida ou já finalizada.';
  end if;

  if v_res.generated_by <> auth.uid() then
    raise exception 'Somente o criador da reserva pode finalizá-la.';
  end if;

  update public.crm_property_authorization_pdfs
  set status = 'FINALIZED', generated_at = now()
  where id = v_res.id;

  select authorization_started_at
  into v_started_at
  from public.crm_property_authorizations
  where property_id = p_property_id;

  if v_started_at is null then
    update public.crm_property_authorizations
    set authorization_started_at = now(), updated_at = now()
    where property_id = p_property_id;
  end if;
end;
$$;

revoke all on function public.finalize_property_authorization_pdf(text, integer, text) from public, anon;
grant execute on function public.finalize_property_authorization_pdf(text, integer, text) to authenticated;

commit;

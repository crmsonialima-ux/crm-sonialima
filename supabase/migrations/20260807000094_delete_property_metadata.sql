-- Remove os vínculos operacionais de um imóvel excluído da planilha.
-- Os arquivos no Storage e as notificações já entregues são preservados como histórico.
create or replace function public.delete_property_metadata(p_property_id text)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  normalized_property_id text := nullif(trim(p_property_id), '');
begin
  if not public.is_allyson_admin() then
    raise exception 'Apenas crmsoniaallyson@gmail.com pode excluir imóveis.';
  end if;

  if normalized_property_id is null then
    raise exception 'Identificador do imóvel é obrigatório.';
  end if;

  delete from public.crm_property_document_clearance_status
  where property_id = normalized_property_id;

  delete from public.crm_property_portal_references
  where property_id = normalized_property_id;

  delete from public.crm_property_broker_access
  where property_id = normalized_property_id;

  delete from public.crm_property_public_links
  where property_id = normalized_property_id;

  delete from public.crm_property_value_reviews
  where property_id = normalized_property_id;

  delete from public.crm_property_reviewability
  where property_id = normalized_property_id;

  delete from public.crm_property_document_responsibilities
  where external_id = normalized_property_id;

  -- As FKs do catálogo removem matches e desvinculam leads recebidos dos portais.
  delete from public.crm_property_catalog
  where external_id = normalized_property_id;
end;
$$;

revoke all on function public.delete_property_metadata(text)
  from public, anon;
grant execute on function public.delete_property_metadata(text)
  to authenticated, service_role;

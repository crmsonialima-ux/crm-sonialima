begin;

-- Replaces the temporary global deletion block with the original restricted
-- workflow: only Allyson may permanently remove a property and its linked data.
drop trigger if exists trg_prevent_property_deletion on public.crm_property_catalog;

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
    raise exception 'Apenas Allyson pode excluir imoveis.';
  end if;
  if normalized_property_id is null then
    raise exception 'Identificador do imovel e obrigatorio.';
  end if;
  if not exists (
    select 1 from public.crm_property_catalog where external_id = normalized_property_id
  ) then
    raise exception 'Imovel nao encontrado.';
  end if;

  insert into public.crm_deleted_properties (external_id, deleted_by, deleted_at)
  values (normalized_property_id, auth.uid(), now())
  on conflict (external_id) do update
    set deleted_by = excluded.deleted_by,
        deleted_at = excluded.deleted_at;

  delete from storage.objects
  where bucket_id = 'property-authorizations'
    and name like normalized_property_id || '/%';

  delete from public.crm_property_authorization_pdfs where property_id = normalized_property_id;
  delete from public.crm_authorization_reminders_log where property_id = normalized_property_id;
  delete from public.crm_property_authorizations where property_id = normalized_property_id;
  delete from public.crm_property_capturer_assignments where property_id = normalized_property_id;
  delete from public.crm_property_document_clearance_status where property_id = normalized_property_id;
  delete from public.crm_property_portal_references where property_id = normalized_property_id;
  delete from public.crm_property_broker_access where property_id = normalized_property_id;
  delete from public.crm_property_public_links where property_id = normalized_property_id;
  delete from public.crm_property_value_reviews where property_id = normalized_property_id;
  delete from public.crm_property_reviewability where property_id = normalized_property_id;
  delete from public.crm_property_document_responsibilities where external_id = normalized_property_id;
  delete from public.crm_property_match_notifications where property_external_id = normalized_property_id;
  delete from public.crm_property_catalog where external_id = normalized_property_id;
end;
$$;

revoke all on function public.delete_property_metadata(text) from public, anon;
grant execute on function public.delete_property_metadata(text) to authenticated, service_role;

commit;

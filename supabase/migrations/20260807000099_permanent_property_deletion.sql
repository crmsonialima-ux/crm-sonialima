-- Deleted properties must never be recreated by legacy synchronization jobs.
create table if not exists public.crm_deleted_properties (
  external_id text primary key,
  deleted_by uuid references public.profiles(id) on delete set null,
  deleted_at timestamptz not null default now()
);

alter table public.crm_deleted_properties enable row level security;
revoke all on public.crm_deleted_properties from public, anon, authenticated;
grant select on public.crm_deleted_properties to service_role;

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

  insert into public.crm_deleted_properties (external_id, deleted_by, deleted_at)
  values (normalized_property_id, auth.uid(), now())
  on conflict (external_id) do update
    set deleted_by = excluded.deleted_by, deleted_at = excluded.deleted_at;

  delete from public.crm_property_document_clearance_status where property_id = normalized_property_id;
  delete from public.crm_property_portal_references where property_id = normalized_property_id;
  delete from public.crm_property_broker_access where property_id = normalized_property_id;
  delete from public.crm_property_public_links where property_id = normalized_property_id;
  delete from public.crm_property_value_reviews where property_id = normalized_property_id;
  delete from public.crm_property_reviewability where property_id = normalized_property_id;
  delete from public.crm_property_document_responsibilities where external_id = normalized_property_id;
  delete from public.crm_property_catalog where external_id = normalized_property_id;
end;
$$;

revoke all on function public.delete_property_metadata(text) from public, anon;
grant execute on function public.delete_property_metadata(text) to authenticated, service_role;

-- This RPC formerly imported the Google Sheet. Supabase is now the source of truth.
create or replace function public.sync_property_catalog(p_properties jsonb)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  return 0;
end;
$$;

revoke all on function public.sync_property_catalog(jsonb) from public, anon, authenticated;
grant execute on function public.sync_property_catalog(jsonb) to service_role;

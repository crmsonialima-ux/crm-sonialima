create or replace function public.block_deleted_property_reinsertion()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if exists (
    select 1 from public.crm_deleted_properties
    where external_id = new.external_id
  ) then
    raise exception 'Este imóvel foi excluído permanentemente.';
  end if;
  return new;
end;
$$;

revoke all on function public.block_deleted_property_reinsertion() from public, anon, authenticated;

drop trigger if exists block_deleted_property_reinsertion on public.crm_property_catalog;
create trigger block_deleted_property_reinsertion
before insert on public.crm_property_catalog
for each row execute function public.block_deleted_property_reinsertion();

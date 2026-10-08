begin;

create or replace function public.delete_crm_sale(p_sale_id uuid)
returns text
language plpgsql
security definer
set search_path=pg_catalog,public,storage
as $$
declare
  sale_row public.crm_sales%rowtype;
  actor_email text;
begin
  select lower(trim(email)) into actor_email
  from public.profiles
  where id=auth.uid();

  if actor_email <> 'crmsoniaallyson@gmail.com' then
    raise exception 'Somente Allyson pode excluir um lancamento de venda.';
  end if;

  select * into sale_row
  from public.crm_sales
  where id=p_sale_id
  for update;

  if not found then
    raise exception 'Lancamento de venda nao encontrado.';
  end if;

  -- Financial data, agenda tasks and delivery-document records use
  -- ON DELETE CASCADE. Storage objects themselves are intentionally managed
  -- by the Storage API rather than direct SQL.
  delete from public.crm_sales
  where id=p_sale_id;

  return sale_row.buyer_name;
end;
$$;

revoke all on function public.delete_crm_sale(uuid) from public,anon;
grant execute on function public.delete_crm_sale(uuid) to authenticated;

commit;

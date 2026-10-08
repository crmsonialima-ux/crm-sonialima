begin;

-- Mantem clientes que ainda estejam com o modulo anterior em cache funcionando
-- durante a atualizacao: sem parametro, a RPC usa a competencia atual.
create or replace function public.get_capture_ranking_rows()
returns table (
  broker_id uuid,
  broker_name text,
  broker_email text,
  property_id text,
  cadastrado_em timestamptz,
  event_date date,
  event_kind text,
  titulo text,
  endereco text,
  valor numeric,
  status text,
  classificacao text,
  sold_from_daily boolean
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select *
  from public.get_capture_ranking_rows(current_date);
$$;

revoke all on function public.get_capture_ranking_rows() from public, anon;
grant execute on function public.get_capture_ranking_rows() to authenticated, service_role;

commit;

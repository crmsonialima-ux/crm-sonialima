-- Corretores veem o ranking por quantidade de negÃ³cios, sem receber valores de comissÃ£o.
begin;

drop policy if exists "Authenticated users read daily broker revenue" on public.crm_daily_broker_revenue;
create policy "Admins read all daily revenue; brokers read their own"
  on public.crm_daily_broker_revenue for select to authenticated
  using (public.is_admin() or broker_id = auth.uid());

create or replace function public.get_sales_ranking(
  p_start date,
  p_end date
)
returns table (
  broker_id uuid,
  broker_name text,
  vendas integer,
  faturamento numeric
)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  viewer_is_admin boolean;
begin
  if auth.uid() is null then
    raise exception 'UsuÃ¡rio nÃ£o autenticado.';
  end if;
  if p_start is null or p_end is null or p_start >= p_end then
    raise exception 'PerÃ­odo invÃ¡lido para o ranking.';
  end if;

  viewer_is_admin := public.is_admin();

  return query
  select
    revenue.broker_id,
    coalesce(nullif(trim(revenue.broker_name), ''), 'Corretor') as broker_name,
    count(*)::integer as vendas,
    case when viewer_is_admin then coalesce(sum(revenue.amount), 0) else null end as faturamento
  from public.crm_daily_broker_revenue as revenue
  where revenue.kind = 'venda'
    and revenue.occurred_on >= p_start
    and revenue.occurred_on < p_end
  group by revenue.broker_id, revenue.broker_name
  order by count(*) desc, broker_name;
end;
$$;

revoke all on function public.get_sales_ranking(date, date) from public;
grant execute on function public.get_sales_ranking(date, date) to authenticated;

commit;

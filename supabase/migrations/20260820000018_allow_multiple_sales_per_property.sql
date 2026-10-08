-- Um mesmo imóvel pode ter lançamentos de venda distintos para corretores distintos.
begin;

drop index if exists public.crm_daily_broker_revenue_one_sale_per_property_idx;

create unique index if not exists crm_daily_broker_revenue_one_sale_per_property_broker_idx
  on public.crm_daily_broker_revenue(property_id, broker_id)
  where kind = 'venda' and property_id is not null and broker_id is not null;

commit;

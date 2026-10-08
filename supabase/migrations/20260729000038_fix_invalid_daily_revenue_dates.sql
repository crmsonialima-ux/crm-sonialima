-- Corrige registros gerados antes da validação de ano com quatro dígitos.
-- Mantém a data escolhida em todos os registros válidos.
update public.crm_daily_broker_revenue
set occurred_on = created_at::date
where occurred_on < date '2000-01-01'
   or occurred_on > current_date + interval '1 year';

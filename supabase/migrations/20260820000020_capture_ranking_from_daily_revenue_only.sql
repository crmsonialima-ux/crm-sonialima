-- O ranking de captação passa a ter uma única fonte de verdade:
-- os lançamentos de venda registrados no Preenchimento diário.
-- A aba Imóveis não concede mais 7, 5 ou 3 pontos.
begin;

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
  with period as (
    select
      date_trunc('year', current_date)::date as starts_on,
      (date_trunc('year', current_date) + interval '1 year')::date as ends_on
  ),
  eligible_profiles as (
    select
      profile.id,
      case
        when lower(trim(profile.email)) = 'unassigned-institutional@example.invalid' then 'SoniaLima'
        else coalesce(nullif(trim(profile.full_name), ''), profile.email)
      end::text as display_name,
      profile.email::text as email
    from public.profiles as profile
    where lower(trim(profile.email)) <> 'crmsoniaallyson@gmail.com'
      and (
        profile.role = 'broker'
        or lower(trim(profile.email)) = 'unassigned-institutional@example.invalid'
      )
  ),
  scored_sales as (
    -- Dois vendedores podem ser lançados no mesmo imóvel, mas a captação
    -- vale uma vez. O lançamento diário mais recente define o captador.
    select distinct on (revenue.property_id)
      revenue.property_id,
      revenue.property_title,
      revenue.capturer_id,
      revenue.vgv,
      revenue.occurred_on,
      revenue.created_at
    from public.crm_daily_broker_revenue as revenue
    cross join period
    where revenue.kind = 'venda'
      and revenue.property_id is not null
      and revenue.capturer_id is not null
      and revenue.occurred_on >= period.starts_on
      and revenue.occurred_on < period.ends_on
    order by revenue.property_id, revenue.occurred_on desc, revenue.created_at desc, revenue.id desc
  ),
  ranking_events as (
    select
      sale.capturer_id as broker_id,
      sale.property_id,
      sale.created_at as cadastrado_em,
      sale.occurred_on as event_date,
      'sale'::text as event_kind,
      coalesce(nullif(trim(sale.property_title), ''), 'Imóvel sem identificação')::text as titulo,
      null::text as endereco,
      sale.vgv as valor,
      'Vendido'::text as status,
      'Venda registrada no Preenchimento diário'::text as classificacao,
      true as sold_from_daily
    from scored_sales as sale
  )
  select
    profile.id,
    profile.display_name,
    profile.email,
    event.property_id,
    event.cadastrado_em,
    event.event_date,
    event.event_kind,
    event.titulo,
    event.endereco,
    event.valor,
    event.status,
    event.classificacao,
    coalesce(event.sold_from_daily, false)
  from eligible_profiles as profile
  left join ranking_events as event
    on event.broker_id = profile.id
  order by profile.display_name, event.event_date nulls last, event.property_id;
$$;

revoke all on function public.get_capture_ranking_rows() from public, anon;
grant execute on function public.get_capture_ranking_rows() to authenticated, service_role;

commit;

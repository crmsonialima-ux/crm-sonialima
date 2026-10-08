-- Imóveis antigos passam a entrar no ranking anual quando Allyson preencher
-- ou alterar a classificação. A data da classificação é a competência da
-- captação para o ranking; a data original de cadastro continua disponível
-- apenas como informação do imóvel.
begin;

alter table public.crm_property_catalog
  add column if not exists sonialima_exclusivity_set_at timestamptz;

-- Os imóveis já classificados fazem parte do quadro atual e precisam entrar
-- no ranking deste ano sem exigir que Allyson preencha tudo novamente.
update public.crm_property_catalog
set sonialima_exclusivity_set_at = now()
where sonialima_exclusivity_control is not null
  and sonialima_exclusivity_set_at is null;

create or replace function public.protect_sonialima_exclusivity()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if new.sonialima_exclusivity_control is distinct from old.sonialima_exclusivity_control then
    if not exists (
      select 1
      from public.profiles
      where id = auth.uid()
        and role = 'admin'
        and lower(trim(email)) = 'crmsoniaallyson@gmail.com'
    ) then
      raise exception 'Somente Allyson pode definir a classificação do imóvel.';
    end if;
    new.sonialima_exclusivity_set_at := now();
  end if;
  return new;
end;
$$;

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
  year_sales as (
    select distinct on (revenue.property_id, revenue.capturer_id)
      revenue.property_id,
      revenue.capturer_id,
      revenue.occurred_on
    from public.crm_daily_broker_revenue as revenue
    cross join period
    where revenue.kind = 'venda'
      and revenue.property_id is not null
      and revenue.capturer_id is not null
      and revenue.occurred_on >= period.starts_on
      and revenue.occurred_on < period.ends_on
    order by revenue.property_id, revenue.capturer_id, revenue.occurred_on desc, revenue.created_at desc
  ),
  capture_events as (
    select
      assignment.broker_id,
      catalog.external_id as property_id,
      coalesce(catalog.entered_at, catalog.created_at) as cadastrado_em,
      (coalesce(
        catalog.sonialima_exclusivity_set_at,
        catalog.entered_at,
        catalog.created_at
      ) at time zone 'America/Sao_Paulo')::date as event_date,
      'capture'::text as event_kind,
      catalog.title as titulo,
      catalog.address as endereco,
      catalog.value as valor,
      catalog.status as status,
      catalog.sonialima_exclusivity_control as classificacao,
      false as sold_from_daily
    from public.crm_property_capturer_assignments as assignment
    join public.crm_property_catalog as catalog
      on catalog.external_id = assignment.property_id
    cross join period
    where (coalesce(
      catalog.sonialima_exclusivity_set_at,
      catalog.entered_at,
      catalog.created_at
    ) at time zone 'America/Sao_Paulo')::date >= period.starts_on
      and (coalesce(
        catalog.sonialima_exclusivity_set_at,
        catalog.entered_at,
        catalog.created_at
      ) at time zone 'America/Sao_Paulo')::date < period.ends_on
      and not exists (
        select 1
        from year_sales as sale
        where sale.property_id = assignment.property_id
          and sale.capturer_id = assignment.broker_id
      )
  ),
  sale_events as (
    select
      sale.capturer_id as broker_id,
      catalog.external_id as property_id,
      coalesce(catalog.entered_at, catalog.created_at) as cadastrado_em,
      sale.occurred_on as event_date,
      'sale'::text as event_kind,
      catalog.title as titulo,
      catalog.address as endereco,
      catalog.value as valor,
      'Vendido'::text as status,
      catalog.sonialima_exclusivity_control as classificacao,
      true as sold_from_daily
    from year_sales as sale
    join public.crm_property_catalog as catalog
      on catalog.external_id = sale.property_id
  ),
  ranking_events as (
    select * from capture_events
    union all
    select * from sale_events
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

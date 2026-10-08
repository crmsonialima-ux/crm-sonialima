-- A aba Imóveis volta a participar do ranking somente por decisão explícita
-- de Allyson, imóvel por imóvel.
begin;

alter table public.crm_property_catalog
  add column if not exists capture_ranking_enabled boolean not null default false,
  add column if not exists capture_ranking_enabled_at timestamptz;

create or replace function public.protect_property_capture_ranking_flag()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if (
    new.capture_ranking_enabled is distinct from old.capture_ranking_enabled
    or new.capture_ranking_enabled_at is distinct from old.capture_ranking_enabled_at
  )
  and current_user not in ('postgres', 'service_role', 'supabase_admin')
  and not public.is_allyson_admin() then
    raise exception 'Somente Allyson pode definir a pontuação de captação do imóvel.';
  end if;
  return new;
end;
$$;

drop trigger if exists protect_property_capture_ranking_flag on public.crm_property_catalog;
create trigger protect_property_capture_ranking_flag
before update on public.crm_property_catalog
for each row execute function public.protect_property_capture_ranking_flag();

create or replace function public.set_property_capture_ranking_enabled(
  p_property_id text,
  p_enabled boolean
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.is_allyson_admin() then
    raise exception 'Somente Allyson pode alterar a pontuação de captação.';
  end if;

  update public.crm_property_catalog
  set
    capture_ranking_enabled = coalesce(p_enabled, false),
    capture_ranking_enabled_at = case when coalesce(p_enabled, false) then now() else null end,
    updated_at = now()
  where external_id = p_property_id;

  if not found then
    raise exception 'Imóvel não encontrado.';
  end if;
end;
$$;

revoke all on function public.set_property_capture_ranking_enabled(text, boolean) from public, anon;
grant execute on function public.set_property_capture_ranking_enabled(text, boolean) to authenticated, service_role;

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
  daily_sales as (
    -- Uma captação recebe no máximo 10 pontos, mesmo com vendas para dois
    -- corretores diferentes. O lançamento diário mais recente é a referência.
    select distinct on (revenue.property_id)
      revenue.property_id,
      revenue.capturer_id,
      revenue.property_title,
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
  property_capture_events as (
    -- Pontua 7, 5 ou 3 somente quando Allyson ativou o imóvel e ele ainda
    -- não possui lançamento de venda no Preenchimento diário.
    select
      assignment.broker_id,
      catalog.external_id as property_id,
      coalesce(catalog.entered_at, catalog.created_at) as cadastrado_em,
      (coalesce(
        catalog.capture_ranking_enabled_at,
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
    from public.crm_property_catalog as catalog
    join public.crm_property_capturer_assignments as assignment
      on assignment.property_id = catalog.external_id
    cross join period
    where catalog.capture_ranking_enabled
      and catalog.sonialima_exclusivity_control is not null
      and (coalesce(
        catalog.capture_ranking_enabled_at,
        catalog.sonialima_exclusivity_set_at,
        catalog.entered_at,
        catalog.created_at
      ) at time zone 'America/Sao_Paulo')::date >= period.starts_on
      and (coalesce(
        catalog.capture_ranking_enabled_at,
        catalog.sonialima_exclusivity_set_at,
        catalog.entered_at,
        catalog.created_at
      ) at time zone 'America/Sao_Paulo')::date < period.ends_on
      and not exists (
        select 1 from daily_sales as sale where sale.property_id = catalog.external_id
      )
  ),
  daily_sale_events as (
    select
      sale.capturer_id as broker_id,
      sale.property_id,
      sale.created_at as cadastrado_em,
      sale.occurred_on as event_date,
      'sale'::text as event_kind,
      coalesce(nullif(trim(sale.property_title), ''), catalog.title, 'Imóvel sem identificação') as titulo,
      catalog.address as endereco,
      sale.vgv as valor,
      'Vendido'::text as status,
      'Venda registrada no Preenchimento diário'::text as classificacao,
      true as sold_from_daily
    from daily_sales as sale
    left join public.crm_property_catalog as catalog
      on catalog.external_id = sale.property_id
  ),
  ranking_events as (
    select * from property_capture_events
    union all
    select * from daily_sale_events
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

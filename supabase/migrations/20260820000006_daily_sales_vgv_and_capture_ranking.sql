begin;

-- A venda diaria passa a guardar o imovel, o captador escolhido e o VGV.
-- As colunas permanecem anulaveis para preservar os lancamentos historicos.
alter table public.crm_daily_broker_revenue
  add column if not exists property_id text,
  add column if not exists property_title text,
  add column if not exists capturer_id uuid,
  add column if not exists capturer_name text,
  add column if not exists vgv numeric;

alter table public.crm_daily_broker_revenue
  drop constraint if exists crm_daily_broker_revenue_property_id_fkey,
  add constraint crm_daily_broker_revenue_property_id_fkey
    foreign key (property_id)
    references public.crm_property_catalog(external_id)
    on delete set null,
  drop constraint if exists crm_daily_broker_revenue_capturer_id_fkey,
  add constraint crm_daily_broker_revenue_capturer_id_fkey
    foreign key (capturer_id)
    references public.profiles(id)
    on delete set null,
  drop constraint if exists crm_daily_broker_revenue_vgv_positive,
  add constraint crm_daily_broker_revenue_vgv_positive
    check (vgv is null or vgv > 0),
  drop constraint if exists crm_daily_broker_revenue_sale_details_required,
  add constraint crm_daily_broker_revenue_sale_details_required
    check (
      kind <> 'venda'
      or (
        property_id is not null
        and nullif(trim(property_title), '') is not null
        and capturer_id is not null
        and nullif(trim(capturer_name), '') is not null
        and vgv is not null
        and vgv > 0
      )
    ) not valid;

-- Um imovel vendido pode gerar VGV e dez pontos uma unica vez.
create unique index if not exists crm_daily_broker_revenue_one_sale_per_property_idx
  on public.crm_daily_broker_revenue(property_id)
  where kind = 'venda' and property_id is not null;

create index if not exists crm_daily_broker_revenue_capturer_idx
  on public.crm_daily_broker_revenue(capturer_id)
  where kind = 'venda';

-- A interface antiga gravava Allyson com o nome comercial SoniaLima. Corrige
-- somente esses registros inequivocos para o perfil institucional correto.
update public.crm_daily_broker_revenue as revenue
set broker_id = institutional.id
from public.profiles as allyson
join public.profiles as institutional
  on lower(trim(institutional.email)) = 'unassigned-institutional@example.invalid'
where revenue.broker_id = allyson.id
  and lower(trim(allyson.email)) = 'crmsoniaallyson@gmail.com'
  and lower(trim(revenue.broker_name)) = 'sonialima';

create or replace function public.canonicalize_daily_broker_revenue()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  canonical_broker_name text;
  canonical_capturer_name text;
  canonical_property_title text;
begin
  select case
      when lower(trim(profile.email)) = 'unassigned-institutional@example.invalid' then 'SoniaLima'
      else coalesce(nullif(trim(profile.full_name), ''), profile.email)
    end
  into canonical_broker_name
  from public.profiles as profile
  where profile.id = new.broker_id
    and (
      profile.role = 'broker'
      or (
        profile.role = 'admin'
        and lower(trim(profile.email)) = 'unassigned-institutional@example.invalid'
      )
    );

  if canonical_broker_name is null then
    raise exception 'Selecione um corretor de venda ou locacao valido.';
  end if;

  new.broker_name := canonical_broker_name;

  if new.kind = 'venda' then
    new.property_id := nullif(trim(new.property_id), '');

    if new.property_id is null or new.capturer_id is null or new.vgv is null or new.vgv <= 0 then
      raise exception 'Venda exige imovel, corretor captador e VGV maior que zero.';
    end if;

    select catalog.title
    into canonical_property_title
    from public.crm_property_catalog as catalog
    where catalog.external_id = new.property_id;

    if canonical_property_title is null then
      raise exception 'Imovel selecionado nao foi encontrado.';
    end if;

    select case
        when lower(trim(profile.email)) = 'unassigned-institutional@example.invalid' then 'SoniaLima'
        else coalesce(nullif(trim(profile.full_name), ''), profile.email)
      end
    into canonical_capturer_name
    from public.profiles as profile
    where profile.id = new.capturer_id
      and (
        profile.role = 'broker'
        or (
          profile.role = 'admin'
          and lower(trim(profile.email)) = 'unassigned-institutional@example.invalid'
        )
      );

    if canonical_capturer_name is null then
      raise exception 'Selecione um corretor captador valido.';
    end if;

    if not exists (
      select 1
      from public.crm_property_capturer_assignments as assignment
      where assignment.property_id = new.property_id
        and assignment.broker_id = new.capturer_id
    ) then
      raise exception 'O captador selecionado nao esta vinculado a este imovel.';
    end if;

    new.property_title := canonical_property_title;
    new.capturer_name := canonical_capturer_name;
  else
    new.property_id := null;
    new.property_title := null;
    new.capturer_id := null;
    new.capturer_name := null;
    new.vgv := null;
  end if;

  return new;
end;
$$;

revoke all on function public.canonicalize_daily_broker_revenue()
  from public, anon, authenticated;

drop trigger if exists canonicalize_daily_broker_revenue
  on public.crm_daily_broker_revenue;
create trigger canonicalize_daily_broker_revenue
before insert or update on public.crm_daily_broker_revenue
for each row execute function public.canonicalize_daily_broker_revenue();

-- Somente Allyson pode editar um lancamento ja existente.
grant update on table public.crm_daily_broker_revenue to authenticated;

drop policy if exists "Allyson updates daily broker revenue"
  on public.crm_daily_broker_revenue;
create policy "Allyson updates daily broker revenue"
  on public.crm_daily_broker_revenue
  for update
  to authenticated
  using (public.is_allyson_admin())
  with check (public.is_allyson_admin());

-- O ranking recebe um marcador explicito da venda diaria. Assim um status
-- legado do catalogo nunca concede dez pontos sozinho.
drop function if exists public.get_capture_ranking_rows();
create function public.get_capture_ranking_rows()
returns table (
  broker_id uuid,
  broker_name text,
  broker_email text,
  property_id text,
  cadastrado_em timestamptz,
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
  with eligible_profiles as (
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
    select
      revenue.property_id,
      revenue.capturer_id,
      revenue.created_at
    from public.crm_daily_broker_revenue as revenue
    where revenue.kind = 'venda'
      and revenue.property_id is not null
      and revenue.capturer_id is not null
  ),
  captured_properties as (
    -- O captador escolhido no preenchimento diario recebe o registro vendido.
    select
      sale.capturer_id as broker_id,
      catalog.external_id as property_id,
      coalesce(catalog.entered_at, catalog.created_at, sale.created_at) as cadastrado_em,
      catalog.title as titulo,
      catalog.address as endereco,
      catalog.value as valor,
      'Vendido'::text as status,
      catalog.sonialima_exclusivity_control as classificacao,
      true as sold_from_daily
    from daily_sales as sale
    join public.crm_property_catalog as catalog
      on catalog.external_id = sale.property_id

    union all

    -- Outros captadores vinculados continuam com a pontuacao normal do imovel.
    -- O mesmo captador da venda e retirado daqui para nao duplicar o imovel.
    select
      assignment.broker_id,
      catalog.external_id,
      coalesce(catalog.entered_at, catalog.created_at),
      catalog.title,
      catalog.address,
      catalog.value,
      catalog.status,
      catalog.sonialima_exclusivity_control,
      false
    from public.crm_property_capturer_assignments as assignment
    join public.crm_property_catalog as catalog
      on catalog.external_id = assignment.property_id
    where not exists (
      select 1
      from daily_sales as sale
      where sale.property_id = assignment.property_id
        and sale.capturer_id = assignment.broker_id
    )
  )
  select
    profile.id,
    profile.display_name,
    profile.email,
    capture.property_id,
    capture.cadastrado_em,
    capture.titulo,
    capture.endereco,
    capture.valor,
    capture.status,
    capture.classificacao,
    coalesce(capture.sold_from_daily, false)
  from eligible_profiles as profile
  left join captured_properties as capture
    on capture.broker_id = profile.id
  order by profile.display_name, capture.cadastrado_em nulls last, capture.property_id;
$$;

revoke all on function public.get_capture_ranking_rows() from public, anon;
grant execute on function public.get_capture_ranking_rows() to authenticated, service_role;

commit;

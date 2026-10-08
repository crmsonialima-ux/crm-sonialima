begin;

-- Keep unknown client/delivery information visibly incomplete. No old sale
-- creates an agenda handover until an operator supplies the missing facts.
alter table public.crm_sales
  alter column expected_delivery_at drop not null,
  add column if not exists property_id text references public.crm_property_catalog(external_id),
  add column if not exists property_title text,
  add column if not exists legacy_daily_revenue_id uuid unique references public.crm_daily_broker_revenue(id),
  add column if not exists legacy_incomplete boolean not null default false;

insert into public.crm_sales (
  seller_id,capturer_id,capturer_name,buyer_name,property_id,property_title,
  property_address,sold_on,expected_delivery_at,has_financing,created_by,
  created_at,updated_at,financial_submitted_at,legacy_daily_revenue_id,legacy_incomplete
)
select
  revenue.broker_id,revenue.capturer_id,coalesce(nullif(revenue.capturer_name,''),'Não informado'),
  '',revenue.property_id,coalesce(catalog.title,revenue.property_title),
  coalesce(nullif(catalog.address,''),nullif(revenue.property_title,''),'Imóvel sem endereço'),
  revenue.occurred_on,null,false,revenue.created_by,revenue.created_at,revenue.created_at,
  revenue.created_at,revenue.id,true
from public.crm_daily_broker_revenue revenue
left join public.crm_property_catalog catalog on catalog.external_id=revenue.property_id
where revenue.kind='venda'
  and not exists (
    select 1 from public.crm_sales existing
    where existing.legacy_daily_revenue_id=revenue.id
  )
  and not exists (
    select 1 from public.crm_sales existing
    where existing.seller_id=revenue.broker_id and existing.sold_on=revenue.occurred_on
      and existing.property_id=revenue.property_id and existing.property_id is not null
  );

insert into public.crm_sale_financials(sale_id,purchase_price,commission_amount,submitted_at,submitted_by)
select sale.id,revenue.vgv,revenue.amount,revenue.created_at,revenue.created_by
from public.crm_sales sale
join public.crm_daily_broker_revenue revenue on revenue.id=sale.legacy_daily_revenue_id
where revenue.vgv is not null and revenue.amount is not null
on conflict(sale_id) do nothing;

-- The old table remains an archival source for rentals, but commissions from
-- historic sales are no longer exposed to brokers through direct SELECT.
drop policy if exists "Admins read all daily revenue; brokers read their own"
  on public.crm_daily_broker_revenue;
create policy "Financial admins read old revenue; brokers read own rentals"
on public.crm_daily_broker_revenue for select to authenticated using (
  (kind='aluguel' and broker_id=auth.uid())
  or exists (select 1 from public.profiles p where p.id=auth.uid()
    and lower(p.email) in ('crmsoniaallyson@gmail.com','unassigned-institutional@example.invalid'))
);
revoke insert,update,delete on public.crm_daily_broker_revenue from authenticated;

-- Reuse the existing ranking rules with the consolidated sales as their source.
create view public.crm_sales_revenue_projection as
select sale.id,sale.sold_on as occurred_on,'venda'::text as kind,
  financial.commission_amount as amount,sale.seller_id as broker_id,
  coalesce(nullif(profile.full_name,''),profile.email) as broker_name,
  sale.property_id,coalesce(sale.property_title,catalog.title,sale.property_address) as property_title,
  sale.capturer_id,sale.capturer_name,financial.purchase_price as vgv,sale.created_at
from public.crm_sales sale
join public.profiles profile on profile.id=sale.seller_id
left join public.crm_sale_financials financial on financial.sale_id=sale.id
left join public.crm_property_catalog catalog on catalog.external_id=sale.property_id;
revoke all on public.crm_sales_revenue_projection from public,anon,authenticated;

do $$ declare definition text; begin
  select pg_get_functiondef('public.get_sales_ranking(date,date)'::regprocedure) into definition;
  if position('from public.crm_daily_broker_revenue as revenue' in definition)=0
     or position('viewer_is_admin := public.is_admin();' in definition)=0 then
    raise exception 'Unexpected sales ranking definition';
  end if;
  definition:=replace(definition,'from public.crm_daily_broker_revenue as revenue',
    'from public.crm_sales_revenue_projection as revenue');
  definition:=replace(definition,'viewer_is_admin := public.is_admin();',
    $guard$viewer_is_admin := exists (select 1 from public.profiles p where p.id=auth.uid()
      and lower(p.email) in ('crmsoniaallyson@gmail.com','unassigned-institutional@example.invalid'));$guard$);
  execute definition;

  select pg_get_functiondef('public.get_capture_ranking_rows()'::regprocedure) into definition;
  if position('from public.crm_daily_broker_revenue as revenue' in definition)=0
     or position('event.valor,' in definition)=0 then
    raise exception 'Unexpected capture ranking definition';
  end if;
  definition:=replace(definition,'from public.crm_daily_broker_revenue as revenue',
    'from public.crm_sales_revenue_projection as revenue');
  definition:=replace(definition,'event.valor,',
    $guard$case when event.event_kind='sale' and not exists (
      select 1 from public.profiles p where p.id=auth.uid()
      and lower(p.email) in ('crmsoniaallyson@gmail.com','unassigned-institutional@example.invalid')
    ) then null else event.valor end,$guard$);
  execute definition;

  select pg_get_functiondef('public.process_crm_sale_automation()'::regprocedure) into definition;
  if position('for s in select * from public.crm_sales loop' in definition)=0 then
    raise exception 'Unexpected sale automation definition';
  end if;
  definition:=replace(definition,'for s in select * from public.crm_sales loop',
    'for s in select * from public.crm_sales where not legacy_incomplete and expected_delivery_at is not null loop');
  execute definition;
end $$;

-- Keep the existing save RPC for validation/financial locking, then attach the
-- catalog property in the same transaction.
create or replace function public.save_crm_sale_with_property(
  p_sale_id uuid,p_property_id text,p_values jsonb
) returns uuid language plpgsql security definer set search_path=pg_catalog,public as $$
declare saved_id uuid; property public.crm_property_catalog;
begin
  select * into property from public.crm_property_catalog where external_id=p_property_id;
  if not found then raise exception 'Selecione um imóvel cadastrado.'; end if;
  if nullif(trim(p_values->>'buyer_name'),'') is null then
    raise exception 'Informe o nome do comprador para completar a venda.';
  end if;
  if nullif(p_values->>'buyer_phone','') is not null
     and length(regexp_replace(p_values->>'buyer_phone','\D','','g')) not in (10,11) then
    raise exception 'Informe telefone com DDD e 10 ou 11 dígitos.';
  end if;
  saved_id:=public.save_crm_sale(p_sale_id,p_values);
  update public.crm_sales set property_id=p_property_id,property_title=property.title,
    property_address=coalesce(nullif(property.address,''),property.title,property.external_id),
    legacy_incomplete=false,updated_at=now() where id=saved_id;
  return saved_id;
end; $$;
revoke all on function public.save_crm_sale_with_property(uuid,text,jsonb) from public,anon;
grant execute on function public.save_crm_sale_with_property(uuid,text,jsonb) to authenticated;
revoke execute on function public.save_crm_sale(uuid,jsonb) from authenticated;

-- Rentals had no records at migration time, but their simple daily entry
-- remains available inside the sales report for future transactions.
create or replace function public.save_crm_rental(
  p_date date,p_broker_id uuid,p_amount numeric
) returns uuid language plpgsql security definer set search_path=pg_catalog,public as $$
declare actor public.profiles; broker public.profiles; saved_id uuid;
begin
  select * into actor from public.profiles where id=auth.uid();
  if lower(actor.email) not in ('crmsoniaallyson@gmail.com','unassigned-institutional@example.invalid') then
    raise exception 'Somente Allyson e AcessoCRM podem registrar locações.';
  end if;
  select * into broker from public.profiles where id=p_broker_id and role='broker';
  if not found or p_date is null or p_amount is null or p_amount<=0 then
    raise exception 'Informe data, corretor e faturamento da locação.';
  end if;
  insert into public.crm_daily_broker_revenue(occurred_on,kind,amount,broker_id,broker_name,created_by)
  values(p_date,'aluguel',p_amount,p_broker_id,
    coalesce(nullif(broker.full_name,''),broker.email),auth.uid()) returning id into saved_id;
  return saved_id;
end; $$;
revoke all on function public.save_crm_rental(date,uuid,numeric) from public,anon;
grant execute on function public.save_crm_rental(date,uuid,numeric) to authenticated;

commit;

create table if not exists public.crm_daily_broker_revenue (
  id uuid primary key default gen_random_uuid(),
  occurred_on date not null,
  kind text not null check (kind in ('venda', 'aluguel')),
  amount numeric not null check (amount > 0),
  broker_id uuid not null references public.profiles(id),
  broker_name text not null,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);
alter table public.crm_daily_broker_revenue enable row level security;
grant select, insert on public.crm_daily_broker_revenue to authenticated;
create policy "Authenticated users read daily broker revenue" on public.crm_daily_broker_revenue for select using (auth.uid() is not null);
create policy "Admins insert daily broker revenue" on public.crm_daily_broker_revenue for insert with check (public.is_admin() and created_by = auth.uid());

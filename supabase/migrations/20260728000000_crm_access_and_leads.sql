-- Perfis, níveis de acesso e leads privados do CRM.
-- Execute esta migration no SQL Editor do projeto Supabase antes de usar o módulo.

create type public.crm_role as enum ('admin', 'broker');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  email text not null default '',
  role public.crm_role not null default 'broker',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.crm_leads (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text,
  email text,
  property_interest text,
  stage text not null default 'Lead',
  channel text,
  budget numeric not null default 0,
  notes text,
  owner_id uuid not null references public.profiles(id),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index crm_leads_owner_id_idx on public.crm_leads(owner_id);
create index crm_leads_created_at_idx on public.crm_leads(created_at desc);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, email)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data ->> 'full_name', ''), split_part(new.email, '@', 1)),
    coalesce(new.email, '')
  )
  on conflict (id) do update set
    email = excluded.email,
    full_name = case when profiles.full_name = '' then excluded.full_name else profiles.full_name end,
    updated_at = now();
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- Cria perfis para usuários já existentes; todos começam como corretores.
insert into public.profiles (id, full_name, email)
select
  id,
  coalesce(nullif(raw_user_meta_data ->> 'full_name', ''), split_part(email, '@', 1)),
  coalesce(email, '')
from auth.users
on conflict (id) do nothing;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer set search_path = public
as $$
  select exists (
    select 1
    from public.profiles
    where id = auth.uid() and role = 'admin'
  );
$$;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute procedure public.set_updated_at();

create trigger crm_leads_set_updated_at
  before update on public.crm_leads
  for each row execute procedure public.set_updated_at();

alter table public.profiles enable row level security;
alter table public.crm_leads enable row level security;

-- RLS define quais linhas cada usuário vê; estes grants permitem que usuários
-- autenticados cheguem às tabelas para que as policies sejam aplicadas.
grant usage on schema public to authenticated;
grant select, update on public.profiles to authenticated;
grant select, insert, update, delete on public.crm_leads to authenticated;

create policy "Profiles can be read by their owner or admins"
  on public.profiles for select
  using (id = auth.uid() or public.is_admin());

create policy "Admins can manage profiles"
  on public.profiles for update
  using (public.is_admin())
  with check (public.is_admin());

create policy "Admins read every lead; brokers read their own"
  on public.crm_leads for select
  using (public.is_admin() or owner_id = auth.uid());

create policy "Authenticated users create leads for themselves; admins can assign"
  on public.crm_leads for insert
  with check (
    created_by = auth.uid()
    and (public.is_admin() or owner_id = auth.uid())
  );

create policy "Admins update every lead; brokers update their own without reassigning"
  on public.crm_leads for update
  using (public.is_admin() or owner_id = auth.uid())
  with check (public.is_admin() or owner_id = auth.uid());

create policy "Only admins can delete leads"
  on public.crm_leads for delete
  using (public.is_admin());

-- Após localizar o ID da sua conta administradora, promova-a uma única vez:
-- update public.profiles set role = 'admin' where email = 'seu-email@empresa.com';

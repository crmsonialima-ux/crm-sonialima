-- Make Supabase the primary store for the remaining spreadsheet-backed CRM data.

alter table public.crm_property_catalog
  add column if not exists code text,
  add column if not exists wimoveis_code text,
  add column if not exists dfimoveis_code text,
  add column if not exists property_type text,
  add column if not exists rental_value numeric not null default 0,
  add column if not exists brokers text,
  add column if not exists owner_name text,
  add column if not exists owner_phone text,
  add column if not exists status text not null default 'Ativo',
  add column if not exists has_photos boolean not null default false,
  add column if not exists has_video boolean not null default false,
  add column if not exists is_advertised boolean not null default false,
  add column if not exists entered_at timestamptz,
  add column if not exists source_updated_at timestamptz,
  add column if not exists capture_origin text,
  add column if not exists notes text;

create unique index if not exists crm_property_catalog_code_unique
  on public.crm_property_catalog (lower(btrim(code)))
  where nullif(btrim(code), '') is not null;
create unique index if not exists crm_property_catalog_wimoveis_code_unique
  on public.crm_property_catalog (lower(btrim(wimoveis_code)))
  where nullif(btrim(wimoveis_code), '') is not null;
create unique index if not exists crm_property_catalog_dfimoveis_code_unique
  on public.crm_property_catalog (lower(btrim(dfimoveis_code)))
  where nullif(btrim(dfimoveis_code), '') is not null;
create index if not exists crm_property_catalog_status_idx
  on public.crm_property_catalog (status, updated_at desc);

drop policy if exists "Authenticated users create properties" on public.crm_property_catalog;
create policy "Authenticated users create properties"
  on public.crm_property_catalog for insert to authenticated
  with check (auth.uid() is not null);
drop policy if exists "Authenticated users update properties" on public.crm_property_catalog;
create policy "Authenticated users update properties"
  on public.crm_property_catalog for update to authenticated
  using (auth.uid() is not null) with check (auth.uid() is not null);
grant insert, update on public.crm_property_catalog to authenticated;

alter table public.crm_leads
  add column if not exists commission numeric not null default 0;
create index if not exists crm_leads_dashboard_idx
  on public.crm_leads (owner_id, stage, updated_at desc);

create table if not exists public.crm_marketing_campaigns (
  id uuid primary key default gen_random_uuid(),
  campaign_date date not null default current_date,
  name text not null,
  channel text,
  objective text,
  status text not null default 'Ativa',
  invested numeric not null default 0,
  leads_generated integer not null default 0,
  visits_generated integer not null default 0,
  deals_closed integer not null default 0,
  revenue numeric not null default 0,
  responsible text,
  notes text,
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.crm_marketing_campaigns enable row level security;
drop policy if exists "Authenticated users view marketing" on public.crm_marketing_campaigns;
create policy "Authenticated users view marketing"
  on public.crm_marketing_campaigns for select to authenticated using (true);
drop policy if exists "Full admins manage marketing" on public.crm_marketing_campaigns;
create policy "Full admins manage marketing"
  on public.crm_marketing_campaigns for all to authenticated
  using (public.is_admin() and not public.is_restricted_admin())
  with check (public.is_admin() and not public.is_restricted_admin());
grant select, insert, update, delete on public.crm_marketing_campaigns to authenticated;
create index if not exists crm_marketing_campaigns_date_idx
  on public.crm_marketing_campaigns (campaign_date desc);

create index if not exists crm_notification_outbox_recipient_active_idx
  on public.crm_notification_outbox (recipient_id, created_at desc)
  where dismissed_at is null;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public'
      and tablename = 'crm_property_catalog'
  ) then alter publication supabase_realtime add table public.crm_property_catalog; end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public'
      and tablename = 'crm_marketing_campaigns'
  ) then alter publication supabase_realtime add table public.crm_marketing_campaigns; end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public'
      and tablename = 'crm_notification_outbox'
  ) then alter publication supabase_realtime add table public.crm_notification_outbox; end if;
end $$;

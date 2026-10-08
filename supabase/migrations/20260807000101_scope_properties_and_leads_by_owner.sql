-- Brokers only see properties explicitly assigned to them. Administrators keep
-- the complete managerial view. SECURITY DEFINER avoids recursive RLS checks.
create or replace function public.can_read_property(p_property_id text)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select public.is_admin()
    or exists (
      select 1
      from public.crm_property_broker_access as access
      where access.property_id = p_property_id
        and access.broker_id = auth.uid()
    );
$$;

revoke all on function public.can_read_property(text) from public, anon;
grant execute on function public.can_read_property(text) to authenticated, service_role;

drop policy if exists "Authenticated users read property catalog"
  on public.crm_property_catalog;
drop policy if exists "Admins and assigned brokers read property catalog"
  on public.crm_property_catalog;
create policy "Admins and assigned brokers read property catalog"
  on public.crm_property_catalog
  for select to authenticated
  using (public.can_read_property(external_id));

drop policy if exists "Authenticated users read property broker access"
  on public.crm_property_broker_access;
drop policy if exists "Admins and brokers read relevant property access"
  on public.crm_property_broker_access;
create policy "Admins and brokers read relevant property access"
  on public.crm_property_broker_access
  for select to authenticated
  using (public.is_admin() or broker_id = auth.uid());

-- Recreate the lead policy explicitly so later migrations cannot leave a broad
-- read rule behind: brokers only receive the lead currently owned by them.
drop policy if exists "Admins read every lead; brokers read their own"
  on public.crm_leads;
drop policy if exists "Admins read all leads; brokers read only assigned leads"
  on public.crm_leads;
create policy "Admins read all leads; brokers read only assigned leads"
  on public.crm_leads
  for select to authenticated
  using (public.is_admin() or owner_id = auth.uid());

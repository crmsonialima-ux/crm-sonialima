-- Creating properties is restricted to Allyson at the database boundary.
drop policy if exists "Authenticated users create properties" on public.crm_property_catalog;
create policy "Only Allyson creates properties"
  on public.crm_property_catalog for insert to authenticated
  with check (public.is_allyson_admin());

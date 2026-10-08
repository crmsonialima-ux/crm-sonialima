-- Fix permission denied on crm_property_capturer_assignments
grant select on public.crm_property_capturer_assignments to authenticated;

-- Allow capturers to read their own assignments so they can upload/read their property authorizations
drop policy if exists "Capturers read own assignments" on public.crm_property_capturer_assignments;
create policy "Capturers read own assignments"
  on public.crm_property_capturer_assignments
  for select to authenticated
  using (broker_id = auth.uid());

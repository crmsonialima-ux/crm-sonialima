-- The only pre-existing user in this new project is its full administrator.
update public.profiles
set role = 'admin',
    is_validator = true,
    full_name = 'Administrador',
    updated_at = now()
where id = '37094db7-2457-48f2-8573-40c887e547e5'::uuid
  and lower(email) = 'crmsoniaallyson@gmail.com';

-- Restore grants after the authorization tables have been created.
grant all on public.crm_property_authorizations to authenticated;
grant all on public.crm_property_authorization_pdfs to authenticated;
grant all on public.crm_authorization_reminders_log to authenticated;

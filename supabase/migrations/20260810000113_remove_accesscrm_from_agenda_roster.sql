-- The operational accesscrm account keeps its CRM permissions but does not
-- participate in the shared agenda roster.
create or replace function public.list_agenda_profiles()
returns table (id uuid, full_name text, email text, role text)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select profile.id, profile.full_name, profile.email, profile.role::text
  from public.profiles as profile
  where profile.role in ('admin', 'broker')
    and lower(trim(profile.email)) <> 'unassigned-institutional@example.invalid'
  order by profile.full_name nulls last, profile.email;
$$;

revoke all on function public.list_agenda_profiles() from public, anon;
grant execute on function public.list_agenda_profiles() to authenticated;

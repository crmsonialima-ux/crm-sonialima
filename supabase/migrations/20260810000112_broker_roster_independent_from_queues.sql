-- Team membership is independent from lead-distribution queue participation.
-- A broker can be excluded from rental distribution and remain visible in CRM.
create or replace function public.list_broker_profiles()
returns table (id uuid, full_name text, email text, role text)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select profile.id, profile.full_name, profile.email, profile.role::text
  from public.profiles as profile
  where profile.role = 'broker'
  order by profile.full_name, profile.email;
$$;

revoke all on function public.list_broker_profiles() from public, anon;
grant execute on function public.list_broker_profiles() to authenticated;

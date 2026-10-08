begin;

-- The administrator account is stable even when its login/profile email changes.
-- Keep the admin role requirement so the UUID alone never grants privileges.
create or replace function public.is_allyson_admin()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1
    from public.profiles as profile
    where profile.id = auth.uid()
      and profile.id = '37094db7-2457-48f2-8573-40c887e547e5'::uuid
      and profile.role = 'admin'
  );
$$;

commit;

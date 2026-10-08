begin;

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
      and profile.role = 'admin'
      and lower(trim(profile.email)) = 'crmsoniaallyson@gmail.com'
  );
$$;

commit;

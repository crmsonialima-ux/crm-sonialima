-- Permite que usuários autenticados escolham apenas corretores registrados,
-- sem expor a tabela profiles diretamente para outros corretores.
create or replace function public.list_broker_profiles()
returns table (id uuid, full_name text, email text, role text)
language sql
security definer
set search_path = public
as $$
  select profiles.id, profiles.full_name, profiles.email, profiles.role
  from public.profiles
  where profiles.role = 'broker'
  order by profiles.full_name, profiles.email;
$$;

revoke all on function public.list_broker_profiles() from public;
grant execute on function public.list_broker_profiles() to authenticated;

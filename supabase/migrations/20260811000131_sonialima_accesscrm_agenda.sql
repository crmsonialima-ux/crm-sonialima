begin;

-- O perfil operacional acessocrm representa a agenda institucional SoniaLima.
-- Ele volta ao roster da agenda sem alterar suas demais permissoes no CRM.
create or replace function public.list_agenda_profiles()
returns table (id uuid, full_name text, email text, role text)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select
    profile.id,
    case
      when lower(trim(profile.email)) = 'unassigned-institutional@example.invalid' then 'SoniaLima'
      else profile.full_name
    end as full_name,
    profile.email,
    profile.role::text
  from public.profiles as profile
  where profile.role in ('admin', 'broker')
  order by
    case when lower(trim(profile.email)) = 'unassigned-institutional@example.invalid' then 0 else 1 end,
    profile.full_name nulls last,
    profile.email;
$$;

revoke all on function public.list_agenda_profiles() from public, anon;
grant execute on function public.list_agenda_profiles() to authenticated;

commit;

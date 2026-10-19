begin;

-- O administrador supremo e um responsavel comercial valido para selecoes
-- manuais, mas conserva seu papel administrativo no cadastro de perfis.
create or replace function public.list_broker_profiles()
returns table (id uuid, full_name text, email text, role text)
language sql stable security definer set search_path = pg_catalog, public as $$
  select
    profile.id,
    case
      when lower(trim(profile.email)) = 'crmsoniaallyson@gmail.com' then 'crmallyson'
      when lower(trim(profile.email)) = 'unassigned-institutional@example.invalid' then 'SoniaLima'
      else profile.full_name
    end,
    profile.email,
    profile.role::text
  from public.profiles as profile
  where profile.role = 'broker'
     or (
       profile.role = 'admin'
       and lower(trim(profile.email)) in (
         'crmsoniaallyson@gmail.com',
         'unassigned-institutional@example.invalid'
       )
     )
  order by 2, profile.email;
$$;

-- A transferencia direta deve aceitar o perfil real do Allyson, alem dos
-- corretores e do perfil institucional SoniaLima.
do $$
declare
  definition text;
  current_target_check text :=
    'profile.role = ''broker'' or public.is_accesscrm_profile(profile.id)';
begin
  select pg_get_functiondef('public.transfer_lead_directly(uuid,uuid)'::regprocedure)
  into definition;

  if position(current_target_check in definition) = 0 then
    raise exception 'Validacao de responsavel esperada nao encontrada em transfer_lead_directly.';
  end if;

  definition := replace(
    definition,
    current_target_check,
    current_target_check ||
      ' or lower(trim(profile.email)) = ''crmsoniaallyson@gmail.com'''
  );
  execute definition;
end;
$$;

revoke all on function public.list_broker_profiles() from public, anon;
grant execute on function public.list_broker_profiles() to authenticated;

commit;

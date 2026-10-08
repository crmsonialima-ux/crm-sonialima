begin;

create or replace function public.set_initial_property_capturer(
  p_property_id text,
  p_capturer_id uuid
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  registration_phase text;
  submitted_by uuid;
  selected_profile record;
begin
  if not exists (
    select 1 from public.profiles
    where id = auth.uid() and role in ('admin', 'broker')
  ) then
    raise exception 'Nao autorizado.';
  end if;

  select catalog.registration_phase into registration_phase
  from public.crm_property_catalog as catalog
  where catalog.external_id = p_property_id;
  if not found then raise exception 'Imovel nao encontrado.'; end if;
  if registration_phase is distinct from 'PENDING' then
    raise exception 'Imovel nao esta na fase inicial PENDING.';
  end if;

  select property_auth.submitted_by into submitted_by
  from public.crm_property_authorizations as property_auth
  where property_auth.property_id = p_property_id;
  if submitted_by is null or submitted_by <> auth.uid() then
    raise exception 'Apenas o autor original da ficha pode definir o captador inicial.';
  end if;

  if exists (
    select 1 from public.crm_property_capturer_assignments
    where property_id = p_property_id
  ) then
    raise exception 'Captador ja foi definido e nao pode ser alterado por esta via.';
  end if;

  select
    profile.id,
    coalesce(nullif(trim(profile.full_name), ''), profile.email) as display_name,
    lower(trim(profile.email)) = 'unassigned-institutional@example.invalid' as institutional
  into selected_profile
  from public.profiles as profile
  where profile.id = p_capturer_id
    and (
      profile.role = 'broker'
      or (profile.role = 'admin' and lower(trim(profile.email)) = 'unassigned-institutional@example.invalid')
    );
  if not found then raise exception 'Captador invalido.'; end if;

  insert into public.crm_property_capturer_assignments (
    property_id, broker_id, broker_name, is_institutional, set_by
  ) values (
    p_property_id,
    selected_profile.id,
    case when selected_profile.institutional then 'SoniaLima' else selected_profile.display_name end,
    selected_profile.institutional,
    auth.uid()
  );
end;
$$;

revoke all on function public.set_initial_property_capturer(text, uuid) from public, anon;
grant execute on function public.set_initial_property_capturer(text, uuid) to authenticated;

commit;

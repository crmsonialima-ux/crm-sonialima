begin;

create or replace function public.get_property_capturer_assignments()
returns table (property_id text, broker_id text, broker_name text)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
begin
  if auth.uid() is null then
    raise exception 'Entre no CRM para ver os captadores.';
  end if;

  return query
  select
    assignment.property_id,
    case
      when lower(trim(profile.email)) = 'unassigned-institutional@example.invalid'
        then '__sonialima__'
      else assignment.broker_id::text
    end,
    case
      when lower(trim(profile.email)) = 'unassigned-institutional@example.invalid'
        then 'SoniaLima'
      else assignment.broker_name
    end
  from public.crm_property_capturer_assignments as assignment
  join public.profiles as profile on profile.id = assignment.broker_id
  order by assignment.property_id,
    case when lower(trim(profile.email)) = 'unassigned-institutional@example.invalid' then 1 else 0 end,
    assignment.created_at;
end;
$$;

revoke all on function public.get_property_capturer_assignments()
  from public, anon;
grant execute on function public.get_property_capturer_assignments()
  to authenticated;

commit;

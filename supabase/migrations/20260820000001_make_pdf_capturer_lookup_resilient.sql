begin;

-- The PDF must use the saved capturer whenever one exists. Older/partial phase-1
-- records may not have an assignment because a previous RPC failed after the
-- authorization was created; for those records, the authorization submitter is
-- the only authoritative fallback available to generate the document.
create or replace function public.get_property_capturer_details(p_property_id text)
returns table(name text)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.can_access_property_authorization(p_property_id, auth.uid()) then
    raise exception 'Acesso negado.';
  end if;

  return query
  select case
    when lower(trim(profile.email)) = 'unassigned-institutional@example.invalid' then 'SoniaLima'
    else coalesce(nullif(trim(assignment.broker_name), ''), nullif(trim(profile.full_name), ''), profile.email)
  end::text
  from public.crm_property_capturer_assignments as assignment
  join public.profiles as profile on profile.id = assignment.broker_id
  where assignment.property_id = p_property_id
  order by assignment.created_at asc
  limit 1;

  if found then return; end if;

  return query
  select case
    when lower(trim(profile.email)) = 'unassigned-institutional@example.invalid' then 'SoniaLima'
    else coalesce(nullif(trim(profile.full_name), ''), profile.email)
  end::text
  from public.crm_property_authorizations as auth_record
  join public.profiles as profile on profile.id = auth_record.submitted_by
  where auth_record.property_id = p_property_id
  limit 1;
end;
$$;

revoke all on function public.get_property_capturer_details(text) from public, anon;
grant execute on function public.get_property_capturer_details(text) to authenticated, service_role;

commit;

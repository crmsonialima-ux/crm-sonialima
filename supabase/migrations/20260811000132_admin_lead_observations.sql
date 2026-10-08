begin;

create or replace function public.add_administrative_lead_observation(
  p_lead_id uuid,
  p_note text
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  actor public.profiles%rowtype;
  activity_id uuid;
begin
  select profile.* into actor
  from public.profiles as profile
  where profile.id = auth.uid();

  if not found
     or actor.role <> 'admin'
     or lower(trim(actor.email)) not in (
       'crmsoniaallyson@gmail.com',
       'unassigned-institutional@example.invalid'
     ) then
    raise exception 'Somente Allyson e acesso CRM podem adicionar esta observacao.';
  end if;

  if nullif(trim(p_note), '') is null then
    raise exception 'Informe a observacao.';
  end if;

  if not exists (select 1 from public.crm_leads where id = p_lead_id) then
    raise exception 'Lead nao encontrado.';
  end if;

  insert into public.crm_lead_activities (
    lead_id,
    stage,
    note,
    author_id,
    author_name
  )
  values (
    p_lead_id,
    'Observacao',
    trim(p_note),
    actor.id,
    coalesce(nullif(trim(actor.full_name), ''), actor.email)
  )
  returning id into activity_id;

  return activity_id;
end;
$$;

revoke all on function public.add_administrative_lead_observation(uuid, text)
  from public, anon;
grant execute on function public.add_administrative_lead_observation(uuid, text)
  to authenticated;

commit;

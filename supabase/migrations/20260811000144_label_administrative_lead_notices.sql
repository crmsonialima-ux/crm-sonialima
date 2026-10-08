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
  display_author text;
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
    raise exception 'Somente Allyson e SoniaLima podem adicionar esta observação.';
  end if;

  if nullif(trim(p_note), '') is null then
    raise exception 'Informe a observação.';
  end if;

  if not exists (select 1 from public.crm_leads where id = p_lead_id) then
    raise exception 'Lead não encontrado.';
  end if;

  display_author := case lower(trim(actor.email))
    when 'crmsoniaallyson@gmail.com' then 'Allyson'
    else 'SoniaLima'
  end;

  insert into public.crm_lead_activities (
    lead_id, stage, note, author_id, author_name
  )
  values (
    p_lead_id, 'Observação', trim(p_note), actor.id, display_author
  )
  returning id into activity_id;

  return activity_id;
end;
$$;

-- Padroniza também os avisos administrativos já existentes no histórico.
update public.crm_lead_activities as activity
set
  stage = 'Observação',
  author_name = case lower(trim(profile.email))
    when 'crmsoniaallyson@gmail.com' then 'Allyson'
    when 'unassigned-institutional@example.invalid' then 'SoniaLima'
    else activity.author_name
  end
from public.profiles as profile
where activity.author_id = profile.id
  and public.crm_normalize_property_match_text(activity.stage) = 'observacao'
  and lower(trim(profile.email)) in (
    'crmsoniaallyson@gmail.com',
    'unassigned-institutional@example.invalid'
  );

revoke all on function public.add_administrative_lead_observation(uuid, text)
  from public, anon;
grant execute on function public.add_administrative_lead_observation(uuid, text)
  to authenticated;

commit;

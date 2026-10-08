begin;

-- O aviso usado no teste foi salvo no campo antigo do lead. Move-o para o
-- histórico administrável para que também possa ser editado ou apagado.
insert into public.crm_lead_activities (
  lead_id, stage, note, author_id, author_name
)
select
  lead.id, 'Observação', lead.notes, profile.id, 'Allyson'
from public.crm_leads as lead
join public.profiles as profile
  on lower(trim(profile.email)) = 'crmsoniaallyson@gmail.com'
where lead.notes ilike '%#testeallyson01%'
  and not exists (
    select 1 from public.crm_lead_activities as activity
    where activity.lead_id = lead.id
      and activity.note = lead.notes
      and public.crm_normalize_property_match_text(activity.stage) = 'observacao'
  );

update public.crm_leads
set notes = null
where notes ilike '%#testeallyson01%';

create or replace function public.edit_administrative_lead_observation(
  p_activity_id uuid,
  p_note text
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if not exists (
    select 1 from public.profiles as profile
    where profile.id = auth.uid()
      and profile.role = 'admin'
      and lower(trim(profile.email)) in (
        'crmsoniaallyson@gmail.com', 'unassigned-institutional@example.invalid'
      )
  ) then
    raise exception 'Somente Allyson e SoniaLima podem editar este aviso.';
  end if;

  if nullif(trim(p_note), '') is null then
    raise exception 'Informe o texto do aviso.';
  end if;

  update public.crm_lead_activities as activity
  set note = trim(p_note)
  where activity.id = p_activity_id
    and public.crm_normalize_property_match_text(activity.stage) = 'observacao';

  if not found then
    raise exception 'Aviso administrativo não encontrado.';
  end if;
end;
$$;

create or replace function public.delete_administrative_lead_observation(
  p_activity_id uuid
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if not exists (
    select 1 from public.profiles as profile
    where profile.id = auth.uid()
      and profile.role = 'admin'
      and lower(trim(profile.email)) in (
        'crmsoniaallyson@gmail.com', 'unassigned-institutional@example.invalid'
      )
  ) then
    raise exception 'Somente Allyson e SoniaLima podem apagar este aviso.';
  end if;

  delete from public.crm_lead_activities as activity
  where activity.id = p_activity_id
    and public.crm_normalize_property_match_text(activity.stage) = 'observacao';

  if not found then
    raise exception 'Aviso administrativo não encontrado.';
  end if;
end;
$$;

revoke all on function public.edit_administrative_lead_observation(uuid, text)
  from public, anon;
grant execute on function public.edit_administrative_lead_observation(uuid, text)
  to authenticated;
revoke all on function public.delete_administrative_lead_observation(uuid)
  from public, anon;
grant execute on function public.delete_administrative_lead_observation(uuid)
  to authenticated;

commit;

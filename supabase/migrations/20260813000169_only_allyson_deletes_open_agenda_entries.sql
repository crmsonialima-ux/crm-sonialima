begin;

create or replace function public.delete_agenda_entry(p_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  current_entry public.crm_agenda_entries;
  actor_name text;
begin
  if not public.is_allyson_admin() then
    raise exception 'Somente Allyson pode excluir demandas da agenda.';
  end if;

  select * into current_entry
  from public.crm_agenda_entries
  where id = p_id
  for update;

  if not found then
    raise exception 'Demanda nao encontrada.';
  end if;
  delete from public.crm_agenda_entries where id = p_id;

  if current_entry.source_kind = 'lead_visit'
     and current_entry.source_lead_id is not null then
    update public.crm_leads
    set stage = 'Em atendimento',
        visit_scheduled_at = null,
        updated_at = now()
    where id = current_entry.source_lead_id
      and visit_scheduled_at = current_entry.scheduled_at;

    if found then
      select coalesce(nullif(trim(full_name), ''), email, 'Allyson')
      into actor_name
      from public.profiles
      where id = auth.uid();

      insert into public.crm_lead_activities(
        lead_id, stage, note, author_id, author_name
      ) values (
        current_entry.source_lead_id,
        'Em atendimento',
        'Visita agendada excluida da agenda.',
        auth.uid(),
        coalesce(actor_name, 'Allyson')
      );
    end if;
  end if;
end;
$$;

revoke all on function public.delete_agenda_entry(uuid) from public, anon;
grant execute on function public.delete_agenda_entry(uuid) to authenticated;

commit;

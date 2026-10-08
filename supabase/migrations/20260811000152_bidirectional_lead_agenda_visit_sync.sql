begin;

drop function if exists public.register_agenda_lead_visit_progress(uuid, text, text);

create function public.register_agenda_lead_visit_progress(
  p_entry_id uuid,
  p_stage text,
  p_note text,
  p_visit_property_captured boolean default null
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  agenda_entry public.crm_agenda_entries;
  lead_record public.crm_leads;
  actor_name text;
  registered_at timestamptz := now();
  normalized_note text := nullif(trim(coalesce(p_note, '')), '');
  activity_note text;
  preserved_stage boolean;
begin
  if p_stage not in ('Visita realizada', 'Proposta') then
    raise exception 'Selecione Visita realizada ou Proposta.';
  end if;
  if normalized_note is null then
    raise exception 'Descreva o que aconteceu na visita.';
  end if;
  if p_stage = 'Visita realizada' and p_visit_property_captured is null then
    raise exception 'Informe se algum imovel do cliente foi captado durante a visita.';
  end if;

  select * into agenda_entry
  from public.crm_agenda_entries
  where id = p_entry_id
  for update;

  if not found then raise exception 'Compromisso nao encontrado.'; end if;
  if agenda_entry.source_kind is distinct from 'lead_visit'
     or agenda_entry.source_lead_id is null then
    raise exception 'Este compromisso nao esta vinculado a uma visita de lead.';
  end if;
  if not public.is_admin()
     and agenda_entry.target_user_id is distinct from auth.uid()
     and not exists (
       select 1 from public.crm_agenda_entry_participants participant
       where participant.entry_id = agenda_entry.id
         and participant.user_id = auth.uid()
     ) then
    raise exception 'Somente os envolvidos na visita podem registrar o retorno.';
  end if;

  select * into lead_record
  from public.crm_leads
  where id = agenda_entry.source_lead_id
  for update;
  if not found then raise exception 'Lead vinculado nao encontrado.'; end if;

  preserved_stage := lead_record.stage in ('Proposta', 'Nao teve interesse', 'Não teve interesse', 'Standby');

  update public.crm_leads
  set stage = case
        when p_stage = 'Visita realizada' and preserved_stage then lead_record.stage
        else p_stage
      end,
      assignment_deadline_at = null,
      visit_completed_at = case
        when p_stage = 'Visita realizada' then coalesce(visit_completed_at, registered_at)
        else visit_completed_at
      end,
      visit_property_captured = case
        when p_stage = 'Visita realizada' then p_visit_property_captured
        else visit_property_captured
      end,
      proposal_at = case
        when p_stage = 'Proposta' then coalesce(proposal_at, registered_at)
        else proposal_at
      end,
      updated_at = registered_at
  where id = lead_record.id;

  select coalesce(nullif(trim(profile.full_name), ''), profile.email, 'Usuario')
  into actor_name from public.profiles profile where profile.id = auth.uid();

  activity_note := normalized_note;
  if p_stage = 'Visita realizada' then
    activity_note := activity_note || E'\nImovel do cliente captado durante a visita: '
      || case when p_visit_property_captured then 'Sim' else 'Nao' end || '.';
  end if;

  insert into public.crm_lead_activities(
    lead_id, stage, note, author_id, author_name
  ) values (
    lead_record.id, p_stage, activity_note, auth.uid(), coalesce(actor_name, 'Usuario')
  );

end;
$$;

revoke all on function public.register_agenda_lead_visit_progress(uuid, text, text, boolean)
  from public, anon;
grant execute on function public.register_agenda_lead_visit_progress(uuid, text, text, boolean)
  to authenticated;

create or replace function public.sync_lead_activity_to_agenda()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  linked_entry_id uuid;
  lead_record public.crm_leads;
begin
  select entry.id into linked_entry_id
  from public.crm_agenda_entries entry
  where entry.source_kind = 'lead_visit'
    and entry.source_lead_id = new.lead_id
  order by entry.scheduled_at desc
  limit 1;

  if linked_entry_id is null and new.stage = 'Visita realizada' then
    select * into lead_record from public.crm_leads where id = new.lead_id;
    begin
      insert into public.crm_agenda_entries(
        category, scheduled_at, observation, target_user_id, created_by,
        source_kind, source_lead_id
      ) values (
        'observacao',
        coalesce(lead_record.visit_scheduled_at, lead_record.visit_completed_at, new.created_at),
        'Visita realizada — ' || coalesce(nullif(trim(lead_record.name), ''), 'Cliente sem nome'),
        lead_record.owner_id,
        coalesce(new.author_id, lead_record.created_by, lead_record.owner_id),
        'lead_visit',
        new.lead_id
      ) returning id into linked_entry_id;
    exception when exclusion_violation or unique_violation then
      linked_entry_id := null;
    end;
  end if;

  if linked_entry_id is not null then
    update public.crm_agenda_entries
    set feedback_at = new.created_at,
        feedback_note = coalesce(new.note, new.stage),
        feedback_by = new.author_id,
        feedback_history = coalesce(feedback_history, '[]'::jsonb)
          || jsonb_build_array(jsonb_build_object(
            'at', new.created_at,
            'note', new.note,
            'stage', new.stage,
            'by', new.author_id,
            'source', 'lead'
          )),
        updated_at = now()
    where id = linked_entry_id;
  end if;

  return new;
end;
$$;

revoke all on function public.sync_lead_activity_to_agenda()
  from public, anon, authenticated;

drop trigger if exists crm_lead_activities_sync_to_agenda on public.crm_lead_activities;
create trigger crm_lead_activities_sync_to_agenda
after insert on public.crm_lead_activities
for each row execute function public.sync_lead_activity_to_agenda();

commit;

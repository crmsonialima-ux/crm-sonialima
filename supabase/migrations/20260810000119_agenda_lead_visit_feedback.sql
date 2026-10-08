-- A visit linked to a lead can be completed directly from the Agenda. The
-- lead update, permanent activity and agenda feedback are committed together.
create or replace function public.register_agenda_lead_visit_progress(
  p_entry_id uuid,
  p_stage text,
  p_note text
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
begin
  if p_stage not in ('Visita realizada', 'Proposta') then
    raise exception 'Selecione Visita realizada ou Proposta.';
  end if;
  if normalized_note is null then
    raise exception 'Descreva o que aconteceu na visita.';
  end if;

  select * into agenda_entry
  from public.crm_agenda_entries
  where id = p_entry_id
  for update;

  if not found then
    raise exception 'Compromisso nao encontrado.';
  end if;
  if agenda_entry.source_kind is distinct from 'lead_visit'
     or agenda_entry.source_lead_id is null then
    raise exception 'Este compromisso nao esta vinculado a uma visita de lead.';
  end if;
  if not public.is_admin()
     and agenda_entry.target_user_id is distinct from auth.uid()
     and not exists (
       select 1
       from public.crm_agenda_entry_participants participant
       where participant.entry_id = agenda_entry.id
         and participant.user_id = auth.uid()
     ) then
    raise exception 'Somente os envolvidos na visita podem registrar o feedback.';
  end if;

  select * into lead_record
  from public.crm_leads
  where id = agenda_entry.source_lead_id
  for update;
  if not found then
    raise exception 'Lead vinculado nao encontrado.';
  end if;

  update public.crm_leads
  set stage = p_stage,
      assignment_deadline_at = null,
      visit_completed_at = coalesce(visit_completed_at, registered_at),
      proposal_at = case
        when p_stage = 'Proposta' then coalesce(proposal_at, registered_at)
        else proposal_at
      end,
      updated_at = registered_at
  where id = lead_record.id;

  select coalesce(nullif(trim(profile.full_name), ''), profile.email, 'Usuario')
  into actor_name
  from public.profiles profile
  where profile.id = auth.uid();

  insert into public.crm_lead_activities(
    lead_id,
    stage,
    note,
    author_id,
    author_name
  ) values (
    lead_record.id,
    p_stage,
    normalized_note,
    auth.uid(),
    coalesce(actor_name, 'Usuario')
  );

  update public.crm_agenda_entries
  set feedback_at = registered_at,
      feedback_note = normalized_note,
      feedback_by = auth.uid(),
      feedback_history = coalesce(feedback_history, '[]'::jsonb)
        || jsonb_build_array(jsonb_build_object(
          'at', registered_at,
          'note', normalized_note,
          'stage', p_stage,
          'by', auth.uid()
        )),
      updated_at = registered_at
  where id = agenda_entry.id;
end;
$$;

revoke all on function public.register_agenda_lead_visit_progress(uuid, text, text)
  from public, anon;
grant execute on function public.register_agenda_lead_visit_progress(uuid, text, text)
  to authenticated;

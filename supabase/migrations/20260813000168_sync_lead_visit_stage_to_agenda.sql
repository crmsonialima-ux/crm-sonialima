begin;

-- A agenda deve refletir a etapa do lead mesmo quando a alteracao nao gera
-- uma atividade no cliente (importacao, RPC ou qualquer outra tela).
create or replace function public.sync_lead_visit_stage_to_agenda()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  completed_at timestamptz := coalesce(new.visit_completed_at, now());
begin
  if new.stage = 'Visita realizada'
     and old.stage is distinct from 'Visita realizada' then
    update public.crm_agenda_entries as entry
    set feedback_at = coalesce(entry.feedback_at, completed_at),
        feedback_note = coalesce(entry.feedback_note, 'Visita realizada'),
        feedback_by = coalesce(entry.feedback_by, auth.uid(), new.owner_id),
        feedback_history = case
          when entry.feedback_at is not null then coalesce(entry.feedback_history, '[]'::jsonb)
          else coalesce(entry.feedback_history, '[]'::jsonb)
            || jsonb_build_array(jsonb_build_object(
              'at', completed_at,
              'note', 'Visita realizada',
              'stage', 'Visita realizada',
              'by', coalesce(auth.uid(), new.owner_id),
              'source', 'lead'
            ))
        end,
        updated_at = now()
    where entry.id = (
      select candidate.id
      from public.crm_agenda_entries as candidate
      where candidate.source_kind = 'lead_visit'
        and candidate.source_lead_id = new.id
      order by candidate.scheduled_at desc
      limit 1
    );
  end if;

  return new;
end;
$$;

revoke all on function public.sync_lead_visit_stage_to_agenda()
  from public, anon, authenticated;

drop trigger if exists crm_leads_sync_visit_stage_to_agenda on public.crm_leads;
create trigger crm_leads_sync_visit_stage_to_agenda
after update of stage on public.crm_leads
for each row execute function public.sync_lead_visit_stage_to_agenda();

-- Repara visitas ja marcadas como realizadas no lead que ainda aparecem como
-- agendadas na agenda.
with latest_entries as (
  select distinct on (entry.source_lead_id)
    entry.id,
    entry.source_lead_id
  from public.crm_agenda_entries as entry
  where entry.source_kind = 'lead_visit'
    and entry.source_lead_id is not null
  order by entry.source_lead_id, entry.scheduled_at desc
)
update public.crm_agenda_entries as entry
set feedback_at = coalesce(entry.feedback_at, lead.visit_completed_at, lead.updated_at, now()),
    feedback_note = coalesce(entry.feedback_note, 'Visita realizada'),
    feedback_by = coalesce(entry.feedback_by, lead.owner_id),
    feedback_history = case
      when entry.feedback_at is not null then coalesce(entry.feedback_history, '[]'::jsonb)
      else coalesce(entry.feedback_history, '[]'::jsonb)
        || jsonb_build_array(jsonb_build_object(
          'at', coalesce(lead.visit_completed_at, lead.updated_at, now()),
          'note', 'Visita realizada',
          'stage', 'Visita realizada',
          'by', lead.owner_id,
          'source', 'lead_backfill'
        ))
    end,
    updated_at = now()
from latest_entries
join public.crm_leads as lead on lead.id = latest_entries.source_lead_id
where entry.id = latest_entries.id
  and lead.stage = 'Visita realizada'
  and entry.feedback_at is null;

commit;

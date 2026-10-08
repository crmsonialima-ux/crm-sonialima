begin;

-- Move the current open agenda entry instead of leaving the old appointment
-- behind and creating a second one when a scheduled visit is rescheduled.
create or replace function public.move_rescheduled_lead_visit_agenda_entry()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if lower(trim(coalesce(old.stage, ''))) = 'visita agendada'
     and lower(trim(coalesce(new.stage, ''))) = 'visita agendada'
     and old.visit_scheduled_at is not null
     and new.visit_scheduled_at is not null
     and old.visit_scheduled_at is distinct from new.visit_scheduled_at then
    update public.crm_agenda_entries as entry
    set scheduled_at = new.visit_scheduled_at,
        feedback_at = null,
        feedback_note = null,
        feedback_by = null,
        updated_at = now()
    where entry.source_kind = 'lead_visit'
      and entry.source_lead_id = new.id
      and entry.scheduled_at = old.visit_scheduled_at
      and entry.feedback_at is null;
  end if;
  return new;
end;
$$;

drop trigger if exists crm_leads_move_rescheduled_visit_agenda_entry on public.crm_leads;
create trigger crm_leads_move_rescheduled_visit_agenda_entry
before update of stage, visit_scheduled_at on public.crm_leads
for each row execute function public.move_rescheduled_lead_visit_agenda_entry();

create or replace function public.reschedule_lead_visit(
  p_lead_id uuid,
  p_scheduled_at timestamptz,
  p_visit_executor_ids uuid[] default null
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  lead_record public.crm_leads%rowtype;
  executor_ids uuid[];
begin
  if auth.uid() is null then raise exception 'Sessao nao encontrada.'; end if;
  if p_scheduled_at is null or p_scheduled_at <= now() then
    raise exception 'Escolha um novo horario futuro para a visita.';
  end if;

  select lead.* into lead_record
  from public.crm_leads as lead
  where lead.id = p_lead_id
  for update;

  if not found then raise exception 'Lead nao encontrado.'; end if;
  if not public.is_allyson_admin()
     and (public.is_admin() or lead_record.owner_id <> auth.uid()) then
    raise exception 'Voce so pode remarcar visitas dos seus proprios leads.';
  end if;
  if lower(trim(coalesce(lead_record.stage, ''))) <> 'visita agendada'
     or lead_record.visit_scheduled_at is null then
    raise exception 'Este lead nao possui uma visita agendada para remarcar.';
  end if;

  if lower(trim(coalesce(lead_record.lead_type::text, ''))) = 'aluguel' then
    executor_ids := array(
      select selected.executor_id
      from unnest(coalesce(p_visit_executor_ids, '{}'::uuid[]))
        with ordinality as selected(executor_id, position)
      where selected.executor_id is not null
      group by selected.executor_id
      order by min(selected.position)
    );
    if cardinality(executor_ids) = 0 then
      raise exception 'Selecione ao menos um corretor para realizar a visita de aluguel.';
    end if;
  else
    executor_ids := '{}'::uuid[];
  end if;

  update public.crm_leads as lead
  set stage = 'Visita agendada',
      visit_scheduled_at = p_scheduled_at,
      visit_executor_id = case
        when lower(trim(coalesce(lead_record.lead_type::text, ''))) = 'aluguel'
          then executor_ids[1]
        else null
      end,
      visit_executor_ids = executor_ids,
      visit_feedback_at = null,
      visit_started_notified_at = null,
      visit_follow_up_notified_at = null,
      visit_feedback_reminder_sent_at = null,
      updated_at = now()
  where lead.id = p_lead_id;
end;
$$;

revoke all on function public.reschedule_lead_visit(uuid, timestamptz, uuid[])
  from public, anon;
grant execute on function public.reschedule_lead_visit(uuid, timestamptz, uuid[])
  to authenticated;

comment on function public.reschedule_lead_visit(uuid, timestamptz, uuid[]) is
  'Allows the owner broker or Allyson to safely reschedule an existing lead visit and synchronize its open agenda entry.';

commit;

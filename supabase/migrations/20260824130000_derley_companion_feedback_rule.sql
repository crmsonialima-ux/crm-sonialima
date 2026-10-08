begin;

create or replace function public.refresh_broker_visit_block(p_broker_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare has_pending_feedback boolean;
begin
  select exists (
    select 1
    from public.crm_leads lead
    left join public.crm_agenda_entries entry on entry.source_lead_id = lead.id and entry.source_kind = 'lead_visit' and entry.scheduled_at = lead.visit_scheduled_at
    where lead.visit_scheduled_at is not null
      and lead.visit_scheduled_at <= now() - interval '2 hours'
      and lead.visit_feedback_at is null
      and (
        (
          p_broker_id != lead.owner_id
          and lead.lead_type = 'Aluguel'
          and exists (
            select 1 from public.crm_agenda_entry_participants p
            join public.profiles pr on pr.id = p.user_id
            where p.entry_id = entry.id and p.user_id = p_broker_id and pr.email ilike 'derley@%'
          )
        )
        or
        (
          lead.owner_id = p_broker_id
          and not (
            lead.lead_type = 'Aluguel'
            and exists (
              select 1 from public.crm_agenda_entry_participants p
              join public.profiles pr on pr.id = p.user_id
              where p.entry_id = entry.id and p.user_id != lead.owner_id and pr.email ilike 'derley@%'
            )
          )
        )
      )
  ) into has_pending_feedback;

  update public.profiles
  set lead_distribution_blocked = has_pending_feedback,
      lead_distribution_blocked_reason = case
        when has_pending_feedback then 'feedback_missing'
        else lead_distribution_blocked_reason
      end,
      lead_distribution_blocked_at = case when has_pending_feedback then coalesce(lead_distribution_blocked_at, now()) else null end,
      updated_at = now()
  where id = p_broker_id;

  return has_pending_feedback;
end;
$$;

create or replace function public.record_visit_feedback_block_status()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  lead_owner uuid;
  derley_id uuid;
begin
  if new.stage = 'Visita realizada' and nullif(trim(coalesce(new.note, '')), '') is not null then
    update public.crm_leads
    set visit_feedback_at = coalesce(visit_feedback_at, now())
    where id = new.lead_id
    returning owner_id into lead_owner;

    if lead_owner is not null then
      perform public.refresh_broker_visit_block(lead_owner);
    end if;

    select pr.id into derley_id from public.crm_agenda_entries entry
    join public.crm_agenda_entry_participants p on p.entry_id = entry.id
    join public.profiles pr on pr.id = p.user_id
    join public.crm_leads l on l.id = entry.source_lead_id
    where entry.source_lead_id = new.lead_id and entry.source_kind = 'lead_visit' and pr.email ilike 'derley@%' and l.lead_type = 'Aluguel'
    limit 1;

    if derley_id is not null then
      perform public.refresh_broker_visit_block(derley_id);
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.process_due_visit_notifications()
returns void language plpgsql security definer set search_path = public as $$
declare
  lead_row record;
  responsible_id uuid;
  derley_id uuid;
begin
  for lead_row in
    select l.id, l.owner_id, l.name, l.property_interest, l.visit_scheduled_at,
      l.visit_started_notified_at, l.visit_follow_up_notified_at, l.lead_type
    from public.crm_leads l
    where l.stage = 'Visita agendada'
      and l.visit_scheduled_at is not null
      and l.visit_scheduled_at <= now()
      and (l.visit_started_notified_at is null or l.visit_follow_up_notified_at is null)
    for update skip locked
  loop
    derley_id := null;
    if lead_row.lead_type = 'Aluguel' then
      select pr.id into derley_id from public.crm_agenda_entries entry
      join public.crm_agenda_entry_participants p on p.entry_id = entry.id
      join public.profiles pr on pr.id = p.user_id
      where entry.source_lead_id = lead_row.id and entry.source_kind = 'lead_visit' and entry.scheduled_at = lead_row.visit_scheduled_at and pr.email ilike 'derley@%'
      limit 1;
    end if;

    if derley_id is not null then
      responsible_id := derley_id;
    else
      responsible_id := lead_row.owner_id;
    end if;

    if lead_row.visit_started_notified_at is null then
      update public.crm_leads set visit_started_notified_at = now() where id = lead_row.id;
      if lead_row.visit_scheduled_at > now() - interval '2 hours' then
        insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
        values (responsible_id, 'visit_started', 'Hora da visita',
          'A visita com ' || lead_row.name || ' começa agora. Depois, registre como foi a visita.',
          '/leads', jsonb_build_object('leadId', lead_row.id, 'name', lead_row.name));
      end if;
    end if;

    if lead_row.visit_follow_up_notified_at is null
       and lead_row.visit_scheduled_at <= now() - interval '2 hours' then
      update public.crm_leads set visit_follow_up_notified_at = now() where id = lead_row.id;
      perform public.refresh_broker_visit_block(responsible_id);
      insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
      values (responsible_id, 'visit_follow_up', 'Como foi a visita?',
        'Você ficou bloqueado temporariamente da fila até registrar o retorno da visita com ' || lead_row.name || '.',
        '/leads', jsonb_build_object('leadId', lead_row.id, 'name', lead_row.name));
    end if;
  end loop;
end;
$$;

select public.refresh_broker_visit_block(id)
from public.profiles
where role = 'broker';

commit;

-- Avisos automáticos no início da visita e duas horas depois, caso ela ainda não tenha sido concluída.
alter table public.crm_leads
  add column if not exists visit_started_notified_at timestamptz,
  add column if not exists visit_follow_up_notified_at timestamptz;

create or replace function public.process_due_visit_notifications()
returns void language plpgsql security definer set search_path = public as $$
declare lead_row record;
begin
  for lead_row in
    select id, owner_id, name, property_interest, visit_scheduled_at,
      visit_started_notified_at, visit_follow_up_notified_at
    from public.crm_leads
    where stage = 'Visita agendada'
      and visit_scheduled_at is not null
      and visit_scheduled_at <= now()
      and (
        visit_started_notified_at is null
        or visit_follow_up_notified_at is null
      )
    for update skip locked
  loop
    -- Quando o agendador roda atrasado por mais de duas horas, evita enviar o aviso antigo de início.
    if lead_row.visit_started_notified_at is null and lead_row.visit_scheduled_at <= now() then
      update public.crm_leads
      set visit_started_notified_at = now()
      where id = lead_row.id;

      if lead_row.visit_scheduled_at <= now()
         and lead_row.visit_scheduled_at > now() - interval '2 hours' then
        insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
        values (
          lead_row.owner_id,
          'visit_started',
          'Hora da visita',
          'A visita com ' || lead_row.name || ' começa agora. Depois, registre como foi a visita.',
          '/leads',
          jsonb_build_object('leadId', lead_row.id, 'name', lead_row.name, 'property', lead_row.property_interest)
        );
      end if;
    end if;

    if lead_row.visit_follow_up_notified_at is null
       and lead_row.visit_scheduled_at <= now() - interval '2 hours' then
      update public.crm_leads
      set visit_follow_up_notified_at = now()
      where id = lead_row.id;

      insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
      values (
        lead_row.owner_id,
        'visit_follow_up',
        'Como foi a visita?',
        'Já se passaram 2 horas desde a visita com ' || lead_row.name || '. Registre agora como foi o atendimento.',
        '/leads',
        jsonb_build_object('leadId', lead_row.id, 'name', lead_row.name, 'property', lead_row.property_interest)
      );
    end if;
  end loop;
end;
$$;

grant execute on function public.process_due_visit_notifications() to service_role;

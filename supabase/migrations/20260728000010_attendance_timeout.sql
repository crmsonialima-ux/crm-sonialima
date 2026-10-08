-- Após assumir, o corretor tem 24h para avançar o lead além de Em atendimento.
create or replace function public.accept_lead_assignment(p_lead_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.crm_leads
  set assignment_status = 'accepted', assignment_deadline_at = now() + interval '24 hours', stage = 'Em atendimento'
  where id = p_lead_id and owner_id = auth.uid() and assignment_status = 'pending';
  if not found then raise exception 'Este lead não está mais disponível para aceite.'; end if;
  update public.lead_assignment_attempts
  set accepted_at = now()
  where lead_id = p_lead_id and broker_id = auth.uid() and accepted_at is null and expired_at is null;
end;
$$;

create or replace function public.process_expired_lead_assignments()
returns void language plpgsql security definer set search_path = public as $$
declare lead_row record; next_broker record; next_position integer; attempt_count integer; timeout_message text;
begin
  for lead_row in
    select * from public.crm_leads
    where assignment_deadline_at <= now()
      and (assignment_status = 'pending' or (assignment_status = 'accepted' and stage = 'Em atendimento'))
    for update skip locked
  loop
    update public.lead_assignment_attempts set expired_at = now()
    where lead_id = lead_row.id and expired_at is null
      and ((lead_row.assignment_status = 'pending' and accepted_at is null) or lead_row.assignment_status = 'accepted');
    select count(*) into attempt_count from public.lead_assignment_attempts where lead_id = lead_row.id;
    perform pg_advisory_xact_lock(hashtext('lead-distribution:' || lead_row.lead_type));
    select q.broker_id, p.full_name, p.email into next_broker
    from public.lead_distribution_queue q join public.profiles p on p.id = q.broker_id
    where q.lead_type = lead_row.lead_type and p.role = 'broker'
      and not exists (select 1 from public.lead_assignment_attempts a where a.lead_id = lead_row.id and a.broker_id = q.broker_id)
    order by q.position limit 1 for update of q skip locked;
    if next_broker.broker_id is null then
      update public.crm_leads set assignment_status = 'exhausted', assignment_deadline_at = null where id = lead_row.id;
      timeout_message := case when lead_row.assignment_status = 'accepted'
        then lead_row.name || ' ficou 24h em atendimento sem avanço.'
        else lead_row.name || ' não foi assumido por nenhum corretor.' end;
      insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
      select id, 'lead_unanswered', 'Esteira de atendimento esgotada', timeout_message, '/leads',
        jsonb_build_object('leadId', lead_row.id, 'phone', lead_row.phone, 'name', lead_row.name)
      from public.profiles where role = 'admin';
    else
      select coalesce(max(position), 0) + 1 into next_position from public.lead_distribution_queue where lead_type = lead_row.lead_type;
      update public.lead_distribution_queue set position = next_position, updated_at = now()
      where lead_type = lead_row.lead_type and broker_id = next_broker.broker_id;
      update public.crm_leads
      set owner_id = next_broker.broker_id, assignment_status = 'pending',
        assignment_deadline_at = now() + interval '4 minutes', stage = 'Aguardando atendimento'
      where id = lead_row.id;
      insert into public.lead_assignment_attempts (lead_id, broker_id, attempt_number, deadline_at)
      values (lead_row.id, next_broker.broker_id, attempt_count + 1, now() + interval '4 minutes');
      insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
      values (next_broker.broker_id, 'lead_assignment', 'Lead transferido para sua carteira',
        'Você tem 4 minutos para iniciar o atendimento de ' || lead_row.name || '.', '/leads',
        jsonb_build_object('leadId', lead_row.id, 'phone', lead_row.phone, 'name', lead_row.name));
    end if;
  end loop;
end;
$$;

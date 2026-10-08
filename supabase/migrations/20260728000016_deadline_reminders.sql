-- Lembretes enviados 30 minutos antes dos prazos de atendimento e feedback de visita.
alter table public.crm_leads
  add column if not exists assignment_reminder_sent_at timestamptz,
  add column if not exists visit_feedback_reminder_sent_at timestamptz;

create or replace function public.accept_lead_assignment(p_lead_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare current_profile record;
begin
  update public.crm_leads
  set assignment_status = 'accepted',
      assignment_deadline_at = now() + interval '24 hours',
      assignment_reminder_sent_at = null,
      stage = 'Em atendimento'
  where id = p_lead_id and owner_id = auth.uid() and assignment_status = 'pending';
  if not found then raise exception 'Este lead não está mais disponível para aceite.'; end if;

  update public.lead_assignment_attempts
  set accepted_at = now()
  where lead_id = p_lead_id and broker_id = auth.uid() and accepted_at is null and expired_at is null;

  select full_name, email into current_profile from public.profiles where id = auth.uid();
  insert into public.crm_lead_activities (lead_id, stage, note, author_id, author_name)
  values (
    p_lead_id, 'Em atendimento',
    'Atendimento iniciado em ' || to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'),
    auth.uid(), coalesce(nullif(current_profile.full_name, ''), current_profile.email)
  );
end;
$$;

create or replace function public.extend_lead_attendance(p_lead_id uuid, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare current_profile record;
begin
  if nullif(trim(p_note), '') is null then raise exception 'Informe o motivo para manter o lead em atendimento.'; end if;
  update public.crm_leads
  set assignment_status = 'accepted',
      assignment_deadline_at = now() + interval '24 hours',
      assignment_reminder_sent_at = null
  where id = p_lead_id and (owner_id = auth.uid() or public.is_admin()) and stage = 'Em atendimento';
  if not found then raise exception 'Este lead não está disponível para renovação de atendimento.'; end if;
  select full_name, email into current_profile from public.profiles where id = auth.uid();
  insert into public.crm_lead_activities (lead_id, stage, note, author_id, author_name)
  values (p_lead_id, 'Ainda em atendimento', trim(p_note), auth.uid(),
    coalesce(nullif(current_profile.full_name, ''), current_profile.email));
end;
$$;

create or replace function public.process_due_lead_reminders()
returns void language plpgsql security definer set search_path = public as $$
declare lead_row record;
begin
  -- 30 min antes de vencer as 24h do atendimento.
  for lead_row in
    select id, owner_id, name, assignment_deadline_at
    from public.crm_leads
    where assignment_status = 'accepted'
      and stage = 'Em atendimento'
      and assignment_deadline_at > now()
      and assignment_deadline_at <= now() + interval '30 minutes'
      and assignment_reminder_sent_at is null
    for update skip locked
  loop
    update public.crm_leads set assignment_reminder_sent_at = now() where id = lead_row.id;
    insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
    values (
      lead_row.owner_id,
      'attendance_reminder',
      'Atendimento vence em 30 minutos',
      'O prazo do lead ' || lead_row.name || ' termina em até 30 minutos. Avance a etapa ou registre “Ainda em atendimento”.',
      '/leads', jsonb_build_object('leadId', lead_row.id, 'name', lead_row.name)
    );
  end loop;

  -- 30 min antes da cobrança obrigatória de feedback, que ocorre 2h após a visita.
  for lead_row in
    select id, owner_id, name, visit_scheduled_at
    from public.crm_leads
    where stage = 'Visita agendada'
      and visit_scheduled_at <= now() - interval '1 hour 30 minutes'
      and visit_scheduled_at > now() - interval '2 hours'
      and visit_feedback_at is null
      and visit_feedback_reminder_sent_at is null
    for update skip locked
  loop
    update public.crm_leads set visit_feedback_reminder_sent_at = now() where id = lead_row.id;
    insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
    values (
      lead_row.owner_id,
      'visit_feedback_reminder',
      'Feedback da visita vence em 30 minutos',
      'Registre como foi a visita com ' || lead_row.name || ' antes de ser bloqueado da fila.',
      '/leads', jsonb_build_object('leadId', lead_row.id, 'name', lead_row.name)
    );
  end loop;
end;
$$;

grant execute on function public.process_due_lead_reminders() to service_role;
grant execute on function public.accept_lead_assignment(uuid) to authenticated;
grant execute on function public.extend_lead_attendance(uuid, text) to authenticated;

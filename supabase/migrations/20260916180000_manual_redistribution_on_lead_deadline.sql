begin;

-- Existing expiration functions cancel queued reminders; the self-hosted
-- outbox constraint was missing this already-used state.
alter table public.crm_notification_outbox
  drop constraint crm_notification_outbox_delivery_status_check;
alter table public.crm_notification_outbox
  add constraint crm_notification_outbox_delivery_status_check
  check (delivery_status in (
    'queued','processing','sent','failed','no_subscription',
    'invalid_subscription','processed_legacy','cancelled'
  ));

-- Once the acceptance deadline ends, the lead waits for Allyson instead of
-- silently rotating to another broker. Qualification expiration uses the same
-- manual handoff. The previous processor still handles accepted attendance.
create or replace function public.process_expired_lead_assignments()
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare lead_row public.crm_leads%rowtype;
begin
  perform public.process_expired_lead_qualifications();

  for lead_row in
    select * from public.crm_leads
    where assignment_status='pending' and assignment_deadline_at<=now()
    order by assignment_deadline_at,id
    for update skip locked
  loop
    update public.lead_assignment_attempts
    set expired_at=now()
    where lead_id=lead_row.id and broker_id=lead_row.owner_id
      and run_number=lead_row.assignment_run_number
      and accepted_at is null and expired_at is null;

    update public.crm_leads
    set assignment_status='exhausted',
        stage='Aguardando redistribuicao pelo Allyson',
        assignment_available_at=null,
        assignment_deadline_at=null,
        assignment_reminder_sent_at=null,
        updated_at=now()
    where id=lead_row.id;

    update public.crm_notification_outbox
    set delivery_status='cancelled'
    where kind='lead_assignment' and recipient_id=lead_row.owner_id
      and payload->>'leadId'=lead_row.id::text
      and delivered_at is null;

    insert into public.crm_lead_activities(lead_id,stage,note,author_name)
    values(lead_row.id,'Aguardando redistribuicao pelo Allyson',
      'Prazo de aceite encerrado. Redistribuicao manual pendente.','Sistema');

    insert into public.crm_notification_outbox(recipient_id,kind,title,body,url,payload)
    select profile.id,'lead_assignment_exhausted',
      'Lead aguardando redistribuicao',
      lead_row.name||' terminou o prazo de aceite e aguarda sua redistribuicao.',
      '/leads',jsonb_build_object('leadId',lead_row.id)
    from public.profiles profile
    where lower(trim(profile.email))='crmsoniaallyson@gmail.com';
  end loop;

  perform public.process_expired_lead_assignments_before_integrity();
end; $$;

revoke all on function public.process_expired_lead_assignments() from public,anon,authenticated;
grant execute on function public.process_expired_lead_assignments() to service_role;

-- The self-hosted instance did not have a job for expired lead assignments.
select cron.schedule(
  'crm-lead-expiration','* * * * *',
  'select public.process_expired_lead_assignments();'
);

commit;

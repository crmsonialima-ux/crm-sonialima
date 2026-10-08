begin;

-- Bio intake leads outside active attendance must not receive hourly
-- registration requests. Keep their actual missing fields and history intact.
do $$
declare
  definition text;
  updated_definition text;
begin
  select pg_get_functiondef('public.sync_portal_lead_registration_reminder()'::regprocedure) into definition;
  updated_definition := replace(definition,
    'if new.source_portal is null',
    'if (new.source_portal = ''link_bio'' and new.stage is distinct from ''Em atendimento'') or new.source_portal is null');
  if updated_definition = definition then raise exception 'Registration trigger definition not recognized'; end if;
  -- Pending deliveries also stop as soon as the lead leaves attendance.
  updated_definition := replace(updated_definition,
    'delete from public.crm_lead_registration_reminders',
    'delete from public.crm_notification_outbox where kind = ''lead_registration_incomplete'' and delivered_at is null and payload->>''leadId'' = new.id::text;
    delete from public.crm_lead_registration_reminders');
  execute updated_definition;

  select pg_get_functiondef('public.process_due_lead_reminders()'::regprocedure) into definition;
  updated_definition := replace(definition,
    'and lead.source_portal is not null',
    'and lead.source_portal is not null
        and (lead.source_portal <> ''link_bio'' or lead.stage = ''Em atendimento'')');
  if updated_definition = definition then raise exception 'Reminder processor definition not recognized'; end if;
  definition := updated_definition;
  updated_definition := replace(definition,
    'lead.source_portal is null',
    '(lead.source_portal = ''link_bio'' and lead.stage is distinct from ''Em atendimento'') or lead.source_portal is null');
  if updated_definition = definition then raise exception 'Reminder cleanup definition not recognized'; end if;
  execute updated_definition;
end;
$$;

-- The previous trigger did not listen to stage changes.
create trigger crm_leads_sync_bio_registration_on_stage
after update of stage on public.crm_leads
for each row
when (new.source_portal = 'link_bio' and old.stage is distinct from new.stage)
execute function public.sync_portal_lead_registration_reminder();

delete from public.crm_lead_registration_reminders as reminder
using public.crm_leads as lead
where lead.id = reminder.lead_id and lead.source_portal = 'link_bio'
  and lead.stage is distinct from 'Em atendimento';

delete from public.crm_notification_outbox as notification
using public.crm_leads as lead
where notification.payload->>'leadId' = lead.id::text
  and notification.kind = 'lead_registration_incomplete'
  and notification.delivered_at is null
  and lead.source_portal = 'link_bio'
  and lead.stage is distinct from 'Em atendimento';

commit;

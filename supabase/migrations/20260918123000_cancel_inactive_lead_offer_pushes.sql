begin;

-- Every queue offer is valid only while this exact lead is still pending for
-- the same broker and queue run. This trigger makes cancellation atomic with
-- acceptance, expiration, redistribution and direct transfer.
create or replace function public.cancel_inactive_lead_offer_notifications()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'UPDATE' and (
    new.owner_id is distinct from old.owner_id
    or new.assignment_status is distinct from old.assignment_status
    or new.assignment_run_number is distinct from old.assignment_run_number
    or new.assignment_deadline_at is distinct from old.assignment_deadline_at
  ) then
    update public.crm_notification_outbox as notification
    set dismissed_at = coalesce(notification.dismissed_at, now()),
        delivery_status = 'cancelled',
        delivery_updated_at = now()
    where notification.kind = 'lead_assignment'
      and notification.dismissed_at is null
      and notification.delivered_at is null
      and notification.payload ->> 'leadId' = new.id::text
      and (
        new.assignment_status <> 'pending'
        or notification.recipient_id <> new.owner_id
        or nullif(notification.payload ->> 'runNumber', '') is distinct from new.assignment_run_number::text
        or new.assignment_deadline_at is null
        or new.assignment_deadline_at <= now()
      );
  end if;
  return new;
end;
$$;

revoke all on function public.cancel_inactive_lead_offer_notifications() from public, anon;
grant execute on function public.cancel_inactive_lead_offer_notifications() to service_role;

drop trigger if exists zzzzzz_crm_leads_cancel_inactive_offer_notifications on public.crm_leads;
create trigger zzzzzz_crm_leads_cancel_inactive_offer_notifications
after update of owner_id, assignment_status, assignment_run_number, assignment_deadline_at
on public.crm_leads
for each row execute function public.cancel_inactive_lead_offer_notifications();

-- One-time repair for offers left queued by earlier versions. They must not be
-- sent to a broker after the lead has moved, been accepted or expired.
update public.crm_notification_outbox as notification
set dismissed_at = now(),
    delivery_status = 'cancelled',
    delivery_updated_at = now()
where notification.kind = 'lead_assignment'
  and notification.dismissed_at is null
  and notification.delivered_at is null
  and notification.delivery_status in ('queued', 'failed', 'processing')
  and not exists (
    select 1
    from public.crm_leads as lead
    where lead.id::text = notification.payload ->> 'leadId'
      and lead.owner_id = notification.recipient_id
      and lead.assignment_status = 'pending'
      and lead.assignment_deadline_at > now()
      and nullif(notification.payload ->> 'runNumber', '') = lead.assignment_run_number::text
  );

commit;

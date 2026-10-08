begin;

-- A dismissed notification is no longer a valid message. Older releases left
-- some of them queued, allowing the push worker to retry messages that had
-- already disappeared from the CRM inbox.
update public.crm_notification_outbox
set delivery_status = 'cancelled',
    delivery_updated_at = now()
where dismissed_at is not null
  and delivered_at is null
  and delivery_status in ('queued', 'failed', 'processing');

-- Keeps the delivery worker focused on notifications that can still reach the
-- recipient. The Edge Function applies the same predicates.
create index if not exists crm_notification_outbox_deliverable_idx
  on public.crm_notification_outbox (available_at, created_at)
  where dismissed_at is null
    and delivered_at is null
    and delivery_status in ('queued', 'failed');

commit;

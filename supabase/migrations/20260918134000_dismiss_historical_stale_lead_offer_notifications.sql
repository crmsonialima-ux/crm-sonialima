begin;

-- Historical lead-offer notifications must disappear when the offer no longer
-- belongs to the recipient or the lead is no longer pending. Sent push events
-- remain in delivery history but are dismissed from every inbox.
with stale_notifications as (
  select notification.id
  from public.crm_notification_outbox as notification
  join public.crm_leads as lead
    on lead.id = (notification.payload ->> 'leadId')::uuid
  where notification.kind = 'lead_assignment'
    and notification.payload ? 'leadId'
    and notification.payload ->> 'leadId' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and notification.dismissed_at is null
    and notification.delivery_status not in ('cancelled', 'failed')
    and (
      lead.assignment_status is distinct from 'pending'
      or lead.owner_id is distinct from notification.recipient_id
    )
)
update public.crm_notification_outbox as notification
set dismissed_at = now(),
    delivery_status = case
      when notification.delivered_at is null then 'cancelled'
      else notification.delivery_status
    end,
    delivery_updated_at = now()
from stale_notifications as stale
where notification.id = stale.id;

commit;

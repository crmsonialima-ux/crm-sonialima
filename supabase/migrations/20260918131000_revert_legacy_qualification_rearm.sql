begin;

-- Reverses the legacy-status repair from 20260918130000. Those leads had
-- already advanced in the CRM before the self-hosted migration and must never
-- start a new mandatory qualification merely because their status is normalized.
with repaired_leads(id) as (
  values
    ('116ef6fb-671d-43d2-ba09-2be2b486cebf'::uuid),
    ('df8ff988-af5e-4a45-8c81-f04e48a0cb3e'::uuid),
    ('ab07e375-2edb-4676-a8dd-07cabd28d15a'::uuid),
    ('3836bf7d-c0f6-481a-95af-8b8e09e979c0'::uuid),
    ('18aa0baf-1495-4bf6-830d-d22e5d72bea4'::uuid),
    ('2db37f3d-f03c-49d4-b718-c0d8a52c30e6'::uuid),
    ('dc06e1be-0800-4eec-ba97-28b9c1ece259'::uuid),
    ('cd164ce9-0d7a-401d-98a6-ab6d92dcb746'::uuid),
    ('3f6b92aa-a6fd-49d1-b7c5-a5a0f4c83ee4'::uuid),
    ('f6e769b7-8764-456f-8772-dfb171f4874f'::uuid),
    ('725dea46-51c8-46bf-a4b9-8f3907d07b20'::uuid),
    ('b38299f9-4284-474c-807b-645167565526'::uuid),
    ('cd2bb55b-189e-4868-94e1-11e7af7b0969'::uuid),
    ('b7f8d079-a705-4038-be77-c350ca8892c7'::uuid),
    ('a49c4e3c-de4f-468b-8403-23f30bcfd87f'::uuid)
), closed as (
  update public.crm_leads lead
  set post_acceptance_qualification_deadline_at = null,
      post_acceptance_qualification_completed_at = coalesce(lead.post_acceptance_qualification_completed_at, now()),
      post_acceptance_qualification_expired_at = null,
      updated_at = now()
  from repaired_leads repaired
  where lead.id = repaired.id
  returning lead.id
)
update public.crm_notification_outbox notification
set dismissed_at = coalesce(notification.dismissed_at, now()),
    delivery_status = 'cancelled',
    delivery_updated_at = now()
where notification.kind = 'qualification_reminder'
  and notification.dismissed_at is null
  and notification.payload ->> 'leadId' in (select id::text from closed);

commit;

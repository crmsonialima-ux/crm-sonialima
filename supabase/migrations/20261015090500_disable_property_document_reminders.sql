-- O fluxo dos nove anexos deixou de fazer parte da aba Imóveis.
begin;

update public.crm_operational_settings
set property_document_notifications_enabled = false,
    updated_at = now();

delete from public.crm_notification_outbox
where kind = 'property_document_reminder'
  and delivered_at is null;

commit;

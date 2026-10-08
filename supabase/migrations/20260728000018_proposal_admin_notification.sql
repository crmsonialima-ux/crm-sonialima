-- Apenas administradores são avisados quando um lead entra em proposta.
create or replace function public.notify_admins_on_lead_proposal()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.stage = 'Proposta' and old.stage is distinct from 'Proposta' then
    insert into public.crm_notification_outbox (recipient_id, kind, title, body, url, payload)
    select
      id,
      'proposal_admin_alert',
      'Lead em proposta',
      'O cliente ' || new.name || ' entrou em proposta' ||
        case when nullif(new.property_interest, '') is not null then ' · ' || new.property_interest else '' end || '.',
      '/leads',
      jsonb_build_object('leadId', new.id, 'name', new.name, 'property', new.property_interest)
    from public.profiles
    where role = 'admin';
  end if;
  return new;
end;
$$;

drop trigger if exists crm_leads_notify_admins_on_proposal on public.crm_leads;
create trigger crm_leads_notify_admins_on_proposal
after update of stage on public.crm_leads
for each row execute procedure public.notify_admins_on_lead_proposal();

begin;

insert into public.crm_notification_delivery_policies (kind, delivery_mode, rationale)
values (
  'lead_accepted_sonialima',
  'immediate',
  'O SoniaLima deve saber imediatamente quando um lead for aceito.'
)
on conflict (kind) do update set
  delivery_mode = excluded.delivery_mode,
  rationale = excluded.rationale,
  updated_at = now();

create or replace function public.notify_sonialima_when_lead_is_accepted()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  broker_name text;
begin
  if new.assignment_status is distinct from 'accepted'
     or (tg_op = 'UPDATE' and old.assignment_status is not distinct from 'accepted') then
    return new;
  end if;

  select coalesce(nullif(trim(profile.full_name), ''), profile.email)
  into broker_name
  from public.profiles as profile
  where profile.id = new.owner_id;

  insert into public.crm_notification_outbox (
    recipient_id, kind, title, body, url, payload, available_at
  )
  select
    profile.id,
    'lead_accepted_sonialima',
    'Lead aceito',
    coalesce(broker_name, 'O corretor responsável') || ' aceitou o lead ' || new.name || '.',
    '/leads',
    jsonb_build_object(
      'leadId', new.id,
      'name', new.name,
      'brokerId', new.owner_id,
      'brokerName', broker_name,
      'acceptedAt', now()
    ),
    now()
  from public.profiles as profile
  where profile.role = 'admin'
    and lower(trim(profile.email)) = 'unassigned-institutional@example.invalid';

  return new;
end;
$$;

drop trigger if exists crm_leads_notify_sonialima_on_acceptance
  on public.crm_leads;
create trigger crm_leads_notify_sonialima_on_acceptance
after insert or update of assignment_status
on public.crm_leads
for each row execute function public.notify_sonialima_when_lead_is_accepted();

revoke all on function public.notify_sonialima_when_lead_is_accepted()
  from public, anon, authenticated;

commit;

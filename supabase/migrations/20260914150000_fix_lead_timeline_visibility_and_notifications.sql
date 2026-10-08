begin;

-- The full technical audit belongs to Allyson. Other users see only actual
-- broker interactions recorded in the lead activity table.
drop policy if exists "Team reads permanent timeline for accessible leads"
  on public.crm_lead_timeline_events;
create policy "Allyson reads full timeline; owners read broker interactions"
  on public.crm_lead_timeline_events
  for select
  to authenticated
  using (
    public.is_allyson_admin()
    or (
      event_type = 'activity'
      and source_table = 'crm_lead_activities'
      and actor_id is not null
      and lower(trim(coalesce(actor_name, ''))) not in ('sistema', 'sistema (gestao)')
      and (
        public.is_admin()
        or exists (
          select 1
          from public.crm_leads as lead
          where lead.id = crm_lead_timeline_events.lead_id
            and lead.owner_id = auth.uid()
        )
      )
    )
  );

drop policy if exists "Admins read every lead activity; brokers read their own lead activity"
  on public.crm_lead_activities;
create policy "Allyson reads all activities; team reads broker interactions"
  on public.crm_lead_activities
  for select
  to authenticated
  using (
    public.is_allyson_admin()
    or (
      author_id is not null
      and lower(trim(coalesce(author_name, ''))) not in ('sistema', 'sistema (gestao)')
      and (
        public.is_admin()
        or exists (
          select 1
          from public.crm_leads as lead
          where lead.id = crm_lead_activities.lead_id
            and lead.owner_id = auth.uid()
        )
      )
    )
  );

-- A newly-created lead can have the legacy "accepted" default, but that is
-- not an acceptance by a broker. Notify only a real pending -> accepted change.
create or replace function public.notify_sonialima_when_lead_is_accepted()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  broker_name text;
begin
  if tg_op <> 'UPDATE'
     or old.assignment_status is distinct from 'pending'
     or new.assignment_status is distinct from 'accepted' then
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

drop trigger if exists crm_leads_notify_sonialima_on_acceptance on public.crm_leads;
create trigger crm_leads_notify_sonialima_on_acceptance
after update of assignment_status on public.crm_leads
for each row execute function public.notify_sonialima_when_lead_is_accepted();

-- The central trigger creates the four scheduled qualification reminders. The
-- acceptance RPC used to create the same four again, producing duplicates.
do $$
declare
  definition text;
  delete_start integer;
  return_start integer;
begin
  select pg_get_functiondef('public.accept_lead_assignment(uuid)'::regprocedure)
  into definition;

  delete_start := strpos(definition, '  delete from public.crm_notification_outbox notification');
  return_start := strpos(definition, '  return case when is_accesscrm');
  if delete_start = 0 or return_start = 0 or return_start <= delete_start then
    raise exception 'A definição esperada do aceite de lead não foi encontrada.';
  end if;

  execute left(definition, delete_start - 1) || substring(definition from return_start);
end;
$$;

-- Remove only undelivered duplicate qualification reminders, preserving the
-- earliest schedule for each lead, recipient and delivery moment.
delete from public.crm_notification_outbox as duplicate
using public.crm_notification_outbox as keeper
where duplicate.kind = 'qualification_reminder'
  and keeper.kind = 'qualification_reminder'
  and duplicate.id > keeper.id
  and duplicate.recipient_id = keeper.recipient_id
  and duplicate.payload ->> 'leadId' = keeper.payload ->> 'leadId'
  and duplicate.available_at = keeper.available_at
  and duplicate.delivered_at is null
  and keeper.delivered_at is null;

notify pgrst, 'reload schema';
commit;

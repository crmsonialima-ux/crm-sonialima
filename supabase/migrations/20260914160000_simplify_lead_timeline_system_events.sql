begin;

-- The cleanup is an internal, atomic migration. Restore the immutable guard
-- before commit so normal application sessions can never edit history.
drop trigger if exists crm_lead_timeline_is_immutable
  on public.crm_lead_timeline_events;

-- Notifications have their own delivery center. Recording both their creation
-- and delivery in every lead history made a single acceptance look like many
-- simultaneous actions. Stop capturing them and remove only those duplicate
-- timeline projections; the notifications themselves remain untouched.
drop trigger if exists crm_capture_notification_timeline on public.crm_notification_outbox;

delete from public.crm_lead_timeline_events
where source_table = 'crm_notification_outbox';

-- The broker's "Lead aceito" activity is the human record of an acceptance.
-- The technical assignment event said the same thing a second time.
do $$
declare
  definition text;
  accepted_start integer;
  expired_start integer;
begin
  select pg_get_functiondef('public.crm_capture_assignment_timeline()'::regprocedure)
  into definition;

  accepted_start := strpos(definition, '  if new.accepted_at is not null and');
  expired_start := strpos(definition, '  if new.expired_at is not null and');
  if accepted_start = 0 or expired_start = 0 or expired_start <= accepted_start then
    raise exception 'A definição esperada do histórico de aceite não foi encontrada.';
  end if;

  execute left(definition, accepted_start - 1) || substring(definition from expired_start);
end;
$$;

delete from public.crm_lead_timeline_events
where event_type = 'assignment_accepted'
  and source_table = 'lead_assignment_attempts';

-- A qualification already writes its own broker activity. Avoid a second
-- generic "Lead atualizado" entry for deadline-only or qualification-only
-- updates, while retaining owner, stage, distribution and property changes.
do $$
declare
  definition text;
  updated_definition text;
  expected_pattern text := E'\\n[[:space:]]*if \\(to_jsonb\\(old\\) - ''updated_at''\\) is not distinct from \\(to_jsonb\\(new\\) - ''updated_at''\\) then\\n[[:space:]]*return new;\\n[[:space:]]*end if;';
  replacement text := $replacement$
  if (to_jsonb(old) - 'updated_at') is not distinct from (to_jsonb(new) - 'updated_at') then
    return new;
  end if;

  if old.owner_id is not distinct from new.owner_id
     and old.stage is not distinct from new.stage
     and old.assignment_status is not distinct from new.assignment_status
     and old.property_interest is not distinct from new.property_interest then
    return new;
  end if;
$replacement$;
begin
  select pg_get_functiondef('public.crm_capture_lead_row_timeline()'::regprocedure)
  into definition;
  -- pg_get_functiondef preserves CRLF from older migrations on this database.
  definition := replace(definition, chr(13), '');
  updated_definition := regexp_replace(definition, expected_pattern, replacement);
  if updated_definition = definition then
    raise exception 'A definição esperada do histórico do lead não foi encontrada.';
  end if;

  execute updated_definition;
end;
$$;

delete from public.crm_lead_timeline_events
where event_type = 'lead_updated'
  and stage = 'Lead atualizado'
  and source_table = 'crm_leads';

-- On old creation paths the legacy default briefly changed from accepted to
-- pending before the first offer. It was a setup detail, not an acceptance.
delete from public.crm_lead_timeline_events as event
using public.crm_leads as lead
where event.event_type = 'lead_updated'
  and event.source_table = 'crm_leads'
  and event.metadata -> 'before' ->> 'assignment_status' = 'accepted'
  and event.metadata -> 'after' ->> 'assignment_status' = 'pending'
  and event.occurred_at between lead.created_at - interval '1 second'
    and lead.created_at + interval '1 minute';

create trigger crm_lead_timeline_is_immutable
before update or delete on public.crm_lead_timeline_events
for each row execute function public.prevent_lead_timeline_mutation();

commit;

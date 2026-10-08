begin;

-- The attendance deadline belongs exclusively to an active accepted lead in
-- "Em atendimento". Queue offers keep their own pending deadline and every
-- other accepted stage must have no deadline to render or process.
create or replace function public.enforce_attendance_deadline()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if new.assignment_status = 'accepted'
     and new.stage is distinct from 'Em atendimento' then
    new.assignment_available_at := null;
    new.assignment_deadline_at := null;
    new.assignment_reminder_sent_at := null;
  elsif new.stage = 'Em atendimento'
     and (
       tg_op = 'INSERT'
       or old.stage is distinct from 'Em atendimento'
       or new.assignment_status is distinct from 'accepted'
       or new.assignment_deadline_at is null
     ) then
    new.assignment_status := 'accepted';
    new.assignment_available_at := null;
    new.assignment_deadline_at := public.crm_add_commercial_minutes(now(), 1440);
    new.assignment_reminder_sent_at := null;
  end if;

  return new;
end;
$$;

-- Repair state written before the invariant above existed. Pending offers are
-- deliberately excluded because their deadline is the broker acceptance window.
update public.crm_leads
set assignment_available_at = null,
    assignment_deadline_at = null,
    assignment_reminder_sent_at = null,
    updated_at = now()
where assignment_status = 'accepted'
  and stage is distinct from 'Em atendimento'
  and (
    assignment_available_at is not null
    or assignment_deadline_at is not null
    or assignment_reminder_sent_at is not null
  );

commit;

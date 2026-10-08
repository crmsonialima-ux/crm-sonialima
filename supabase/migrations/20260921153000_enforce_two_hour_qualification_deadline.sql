-- Qualification is an elapsed-time SLA: it must expire exactly two hours
-- after acceptance, without pausing outside lead-queue or commercial hours.

-- Repair qualifications that are already open. Prefer the recorded acceptance
-- time for the current assignment run; direct transfers without an accepted
-- attempt are capped at two hours from this migration and are never extended.
with current_acceptances as (
  select distinct on (attempt.lead_id)
    attempt.lead_id,
    attempt.accepted_at
  from public.lead_assignment_attempts attempt
  join public.crm_leads lead
    on lead.id = attempt.lead_id
   and attempt.run_number = lead.assignment_run_number
  where attempt.accepted_at is not null
  order by attempt.lead_id, attempt.accepted_at desc
)
update public.crm_leads lead
set post_acceptance_qualification_deadline_at = least(
      lead.post_acceptance_qualification_deadline_at,
      coalesce(
        (
          select acceptance.accepted_at + interval '2 hours'
          from current_acceptances acceptance
          where acceptance.lead_id = lead.id
        ),
        now() + interval '2 hours'
      )
    ),
    updated_at = now()
where lead.post_acceptance_qualification_deadline_at is not null
  and lead.post_acceptance_qualification_completed_at is null
  and lead.post_acceptance_qualification_expired_at is null
  and lead.post_acceptance_qualification_deadline_at > now();

create or replace function public.enforce_two_hour_qualification_deadline()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if new.post_acceptance_qualification_deadline_at is not null
     and new.post_acceptance_qualification_deadline_at is distinct from old.post_acceptance_qualification_deadline_at
     and new.post_acceptance_qualification_completed_at is null
     and new.post_acceptance_qualification_expired_at is null
     and not coalesce(new.accesscrm_permanent_owner, false) then
    new.post_acceptance_qualification_deadline_at := statement_timestamp() + interval '2 hours';
  end if;

  return new;
end;
$$;

drop trigger if exists zz_enforce_two_hour_qualification_deadline on public.crm_leads;
create trigger zz_enforce_two_hour_qualification_deadline
before update on public.crm_leads
for each row
execute function public.enforce_two_hour_qualification_deadline();

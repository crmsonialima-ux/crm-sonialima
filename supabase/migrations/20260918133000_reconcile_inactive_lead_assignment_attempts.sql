begin;

-- An assignment attempt is only active while its lead is pending in the
-- distribution queue. Closing orphaned attempts prevents historic queue rows
-- from being considered by future routing or notification processing.
create or replace function public.reconcile_inactive_lead_assignment_attempts()
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  update public.lead_assignment_attempts as attempt
  set expired_at = attempt.deadline_at
  from public.crm_leads as lead
  where lead.id = attempt.lead_id
    and lead.assignment_status is distinct from 'pending'
    and attempt.accepted_at is null
    and attempt.expired_at is null;
end;
$$;

-- This is the cron entry point used by process-lead-assignments. Reconcile
-- first, then retain the existing qualification and queue processing order.
create or replace function public.process_expired_lead_assignments()
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  perform public.reconcile_inactive_lead_assignment_attempts();
  perform public.process_expired_lead_qualifications();
  perform public.process_expired_lead_assignments_before_integrity();
end;
$$;

revoke all on function public.reconcile_inactive_lead_assignment_attempts() from public, anon, authenticated;
grant execute on function public.reconcile_inactive_lead_assignment_attempts() to service_role;
revoke all on function public.process_expired_lead_assignments() from public, anon, authenticated;
grant execute on function public.process_expired_lead_assignments() to service_role;

-- Repair only orphaned historical attempts. The original deadline is retained
-- as the expiration time to preserve the real chronology of the queue.
select public.reconcile_inactive_lead_assignment_attempts();

commit;

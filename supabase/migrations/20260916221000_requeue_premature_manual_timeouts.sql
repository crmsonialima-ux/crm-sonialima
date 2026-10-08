begin;

-- Correct only the leads moved to Allyson by the premature-timeout wrapper
-- deployed on 16 September. They re-enter the restored two-round processor
-- from their current assigned broker and preserve their assignment history.
update public.crm_leads lead
set assignment_status='pending',
    assignment_available_at=now()-interval '1 second',
    assignment_deadline_at=now()-interval '1 second',
    assignment_reminder_sent_at=null,
    stage='Aguardando atendimento',
    updated_at=now()
where lead.assignment_status='exhausted'
  and lead.stage='Aguardando redistribuicao pelo Allyson'
  and exists (
    select 1
    from public.crm_lead_activities activity
    where activity.lead_id=lead.id
      and activity.stage='Aguardando redistribuicao pelo Allyson'
      and activity.note='Prazo de aceite encerrado. Redistribuicao manual pendente.'
      and activity.created_at >= timestamptz '2026-09-16 17:00:00+00'
  );

select public.process_expired_lead_assignments();

commit;

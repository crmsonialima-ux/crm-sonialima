begin;

-- The five-hour penalty belongs to the missed qualification deadline.  If the
-- scheduler is unavailable and catches up later, do not start a new five-hour
-- block at that later time.
create or replace function public.process_expired_lead_qualifications()
returns void
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  lead_row record;
  actor_name text;
  penalty_until timestamptz;
begin
  for lead_row in
    select lead.*
    from public.crm_leads lead
    join public.profiles owner on owner.id=lead.owner_id
    where lead.assignment_status='accepted'
      and lower(trim(owner.email)) <> 'unassigned-institutional@example.invalid'
      and lead.post_acceptance_qualification_deadline_at <= now()
      and lead.post_acceptance_qualification_completed_at is null
      and lead.post_acceptance_qualification_expired_at is null
    order by lead.post_acceptance_qualification_deadline_at,lead.id
    for update of lead skip locked
  loop
    penalty_until := lead_row.post_acceptance_qualification_deadline_at + interval '5 hours';

    select coalesce(nullif(profile.full_name,''),profile.email)
      into actor_name
    from public.profiles profile
    where profile.id=lead_row.owner_id;

    -- Apply a block only while the original penalty window is still open.
    -- This prevents a delayed cron job from penalising a broker today for a
    -- deadline that elapsed yesterday.
    if penalty_until > now() then
      update public.profiles profile
      set lead_distribution_blocked_until=greatest(
            coalesce(profile.lead_distribution_blocked_until,'-infinity'::timestamptz),
            penalty_until
          ),
          lead_distribution_blocked_reason=case
            when profile.lead_distribution_blocked_until is null
              or profile.lead_distribution_blocked_until <= penalty_until
              or profile.lead_distribution_blocked_reason='Penalidade: qualificacao obrigatoria nao concluida'
            then 'Penalidade: qualificacao obrigatoria nao concluida'
            else profile.lead_distribution_blocked_reason
          end,
          updated_at=now()
      where profile.id=lead_row.owner_id;
    end if;

    update public.crm_leads lead
    set assignment_status='pending',
        assignment_available_at=now()-interval '1 second',
        assignment_deadline_at=now()-interval '1 second',
        assignment_reminder_sent_at=null,
        stage='Aguardando atendimento',
        post_acceptance_qualification_expired_at=now(),
        updated_at=now()
    where lead.id=lead_row.id;

    update public.crm_notification_outbox notification
    set delivery_status='cancelled'
    where notification.kind='qualification_reminder'
      and notification.recipient_id=lead_row.owner_id
      and notification.payload->>'leadId'=lead_row.id::text
      and notification.delivered_at is null;

    insert into public.crm_lead_activities(
      lead_id,stage,note,author_id,author_name
    ) values (
      lead_row.id,
      'Qualificacao expirada',
      case when penalty_until > now()
        then 'Qualificacao obrigatoria nao concluida. Corretor bloqueado ate '
             || to_char(penalty_until at time zone 'America/Sao_Paulo','DD/MM/YYYY HH24:MI')
             || ' e lead devolvido a esteira.'
        else 'Qualificacao obrigatoria nao concluida. O prazo de penalidade ja havia encerrado; lead devolvido a esteira sem novo bloqueio.'
      end,
      lead_row.owner_id,
      coalesce(actor_name,'Sistema')
    );
  end loop;
end;
$$;

-- Repair any qualification-only block created by the old catch-up behaviour.
-- A broker may have more than one expired qualification, therefore keep the
-- latest original deadline plus five hours when that window is still active.
with qualification_penalties as (
  select owner_id,
         max(post_acceptance_qualification_deadline_at + interval '5 hours') as valid_until
  from public.crm_leads
  where post_acceptance_qualification_expired_at is not null
    and post_acceptance_qualification_deadline_at is not null
  group by owner_id
)
update public.profiles profile
set lead_distribution_blocked_until=case
      when qualification_penalties.valid_until > now()
        then qualification_penalties.valid_until
      else null
    end,
    lead_distribution_blocked_reason=case
      when qualification_penalties.valid_until > now()
        then 'Penalidade: qualificacao obrigatoria nao concluida'
      else null
    end,
    updated_at=now()
from qualification_penalties
where profile.id=qualification_penalties.owner_id
  and profile.lead_distribution_blocked_reason='Penalidade: qualificacao obrigatoria nao concluida';

commit;

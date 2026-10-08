begin;

-- Visit-feedback refreshes own the permanent block, but must not erase the
-- reason of an independent timed penalty that is still active.
create or replace function public.refresh_broker_visit_block(p_broker_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  has_pending_feedback boolean;
  manually_disabled boolean;
begin
  select exists (
    select 1
    from public.crm_leads lead
    left join public.crm_agenda_entries entry
      on entry.source_lead_id = lead.id
     and entry.source_kind = 'lead_visit'
     and entry.scheduled_at = lead.visit_scheduled_at
    where lead.visit_scheduled_at is not null
      and lead.visit_scheduled_at <= now() - interval '2 hours'
      and lead.visit_feedback_at is null
      and (
        (
          p_broker_id != lead.owner_id
          and lead.lead_type = 'Aluguel'
          and exists (
            select 1
            from public.crm_agenda_entry_participants participant
            join public.profiles participant_profile
              on participant_profile.id = participant.user_id
            where participant.entry_id = entry.id
              and participant.user_id = p_broker_id
              and participant_profile.email ilike 'derley@%'
          )
        )
        or
        (
          lead.owner_id = p_broker_id
          and not (
            lead.lead_type = 'Aluguel'
            and exists (
              select 1
              from public.crm_agenda_entry_participants participant
              join public.profiles participant_profile
                on participant_profile.id = participant.user_id
              where participant.entry_id = entry.id
                and participant.user_id != lead.owner_id
                and participant_profile.email ilike 'derley@%'
            )
          )
        )
      )
  ) into has_pending_feedback;

  select coalesce(profile.lead_distribution_manually_disabled, false)
  into manually_disabled
  from public.profiles profile
  where profile.id = p_broker_id;

  update public.profiles as profile
  set lead_distribution_blocked = has_pending_feedback or coalesce(manually_disabled, false),
      lead_distribution_blocked_reason = case
        when manually_disabled then 'Desativado manualmente da fila pelo Allyson'
        when has_pending_feedback then 'feedback_missing'
        when profile.lead_distribution_blocked_until > now()
          then profile.lead_distribution_blocked_reason
        else null
      end,
      lead_distribution_blocked_at = case
        when has_pending_feedback or manually_disabled
          then coalesce(profile.lead_distribution_blocked_at, now())
        else null
      end,
      updated_at = now()
  where profile.id = p_broker_id;

  return has_pending_feedback or coalesce(manually_disabled, false);
end;
$$;

-- Some timed reasons were erased by the old feedback refresh. The activity log
-- still identifies the authoritative latest qualification expiration.
with latest_expiration as (
  select
    activity.author_id as broker_id,
    max(activity.created_at) as occurred_at
  from public.crm_lead_activities as activity
  where activity.stage = 'Qualificacao expirada'
    and activity.author_id is not null
  group by activity.author_id
)
update public.profiles as profile
set lead_distribution_blocked_until = least(
      profile.lead_distribution_blocked_until,
      latest_expiration.occurred_at + interval '5 hours'
    ),
    lead_distribution_blocked_reason = case
      when latest_expiration.occurred_at + interval '5 hours' > now()
        then 'Penalidade: qualificacao obrigatoria nao concluida'
      else profile.lead_distribution_blocked_reason
    end,
    updated_at = now()
from latest_expiration
where profile.id = latest_expiration.broker_id
  and (
    profile.lead_distribution_blocked_reason is null
    or profile.lead_distribution_blocked_reason ilike
        '%qualificacao obrigatoria nao concluida%'
  )
  and profile.lead_distribution_blocked_until >
      latest_expiration.occurred_at + interval '5 hours';

do $$
begin
  if exists (
    select 1
    from public.profiles as profile
    join (
      select activity.author_id as broker_id, max(activity.created_at) as occurred_at
      from public.crm_lead_activities as activity
      where activity.stage = 'Qualificacao expirada' and activity.author_id is not null
      group by activity.author_id
    ) as latest_expiration on latest_expiration.broker_id = profile.id
    where (
        profile.lead_distribution_blocked_reason is null
        or profile.lead_distribution_blocked_reason ilike
            '%qualificacao obrigatoria nao concluida%'
      )
      and profile.lead_distribution_blocked_until >
          latest_expiration.occurred_at + interval '5 hours'
  ) then
    raise exception 'Falha ao limitar penalidades acumuladas a cinco horas.';
  end if;
end;
$$;

commit;

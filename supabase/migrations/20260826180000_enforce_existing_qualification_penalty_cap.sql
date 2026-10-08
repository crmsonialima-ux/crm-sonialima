begin;

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
    updated_at = now()
from latest_expiration
where profile.id = latest_expiration.broker_id
  and profile.lead_distribution_blocked_reason ilike
      '%qualificacao obrigatoria nao concluida%'
  and profile.lead_distribution_blocked_until >
      latest_expiration.occurred_at + interval '5 hours';

do $$
begin
  if exists (
    select 1
    from public.profiles as profile
    join (
      select
        activity.author_id as broker_id,
        max(activity.created_at) as occurred_at
      from public.crm_lead_activities as activity
      where activity.stage = 'Qualificacao expirada'
        and activity.author_id is not null
      group by activity.author_id
    ) as latest_expiration on latest_expiration.broker_id = profile.id
    where profile.lead_distribution_blocked_reason ilike
        '%qualificacao obrigatoria nao concluida%'
      and profile.lead_distribution_blocked_until >
        latest_expiration.occurred_at + interval '5 hours'
  ) then
    raise exception 'Falha ao corrigir penalidades de qualificacao acumuladas.';
  end if;
end;
$$;

commit;

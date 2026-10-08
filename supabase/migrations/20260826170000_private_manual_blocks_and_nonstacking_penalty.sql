begin;

-- A qualification penalty lasts five hours from the latest infraction. Multiple
-- expired leads in the same processor run must not add five hours to each other.
create or replace function public.process_expired_lead_qualifications()
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  lead_row record;
  actor_name text;
begin
  for lead_row in
    select lead.*
    from public.crm_leads as lead
    where lead.assignment_status = 'accepted'
      and lead.post_acceptance_qualification_deadline_at <= now()
      and lead.post_acceptance_qualification_completed_at is null
      and lead.post_acceptance_qualification_expired_at is null
    order by lead.post_acceptance_qualification_deadline_at, lead.id
    for update skip locked
  loop
    select coalesce(nullif(profile.full_name, ''), profile.email)
    into actor_name
    from public.profiles as profile
    where profile.id = lead_row.owner_id;

    update public.profiles as profile
    set lead_distribution_blocked_until = greatest(
          coalesce(profile.lead_distribution_blocked_until, '-infinity'::timestamptz),
          now() + interval '5 hours'
        ),
        lead_distribution_blocked_reason = 'Penalidade: qualificacao obrigatoria nao concluida',
        updated_at = now()
    where profile.id = lead_row.owner_id;

    update public.crm_leads as lead
    set assignment_status = 'pending',
        assignment_available_at = now() - interval '1 second',
        assignment_deadline_at = now() - interval '1 second',
        assignment_reminder_sent_at = null,
        stage = 'Aguardando atendimento',
        post_acceptance_qualification_expired_at = now(),
        updated_at = now()
    where lead.id = lead_row.id;

    update public.crm_notification_outbox as notification
    set delivery_status = 'cancelled'
    where notification.kind = 'qualification_reminder'
      and notification.recipient_id = lead_row.owner_id
      and notification.payload ->> 'leadId' = lead_row.id::text
      and notification.delivered_at is null;

    insert into public.crm_lead_activities (
      lead_id,
      stage,
      note,
      author_id,
      author_name
    )
    values (
      lead_row.id,
      'Qualificacao expirada',
      'Qualificacao obrigatoria nao concluida. Corretor bloqueado por 5 horas e lead devolvido a esteira.',
      lead_row.owner_id,
      coalesce(actor_name, 'Sistema')
    );
  end loop;
end;
$$;

revoke all on function public.process_expired_lead_qualifications()
  from public, anon, authenticated;
grant execute on function public.process_expired_lead_qualifications() to service_role;

-- Repair penalties that were already stacked. The latest recorded expiration is
-- the authoritative start of the single five-hour penalty.
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
set lead_distribution_blocked_until = latest_expiration.occurred_at + interval '5 hours',
    updated_at = now()
from latest_expiration
where profile.id = latest_expiration.broker_id
  and lower(coalesce(profile.lead_distribution_blocked_reason, '')) =
      'penalidade: qualificacao obrigatoria nao concluida'
  and profile.lead_distribution_blocked_until >
      latest_expiration.occurred_at + interval '5 hours';

-- Manual queue controls are private. Other authenticated users receive only a
-- generic unavailable status; the manual flag, reason and stale timer are never
-- returned to their session.
create or replace function public.list_lead_distribution_status()
returns table (
  id uuid,
  lead_type text,
  queue_position integer,
  broker_id uuid,
  full_name text,
  email text,
  is_blocked boolean,
  is_permanently_blocked boolean,
  manually_disabled boolean,
  blocked_until timestamptz,
  blocked_reason text
)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  with actor as (
    select exists (
      select 1
      from public.profiles as actor_profile
      where actor_profile.id = auth.uid()
        and actor_profile.role = 'admin'
        and (
          actor_profile.id = '37094db7-2457-48f2-8573-40c887e547e5'::uuid
          or lower(trim(coalesce(actor_profile.email, ''))) = 'crmsoniaallyson@gmail.com'
        )
    ) as is_allyson
  )
  select
    queue.id,
    queue.lead_type,
    queue.position,
    queue.broker_id,
    coalesce(nullif(trim(profile.full_name), ''), queue.broker_email, profile.email),
    profile.email,
    coalesce(profile.lead_distribution_blocked, false)
      or coalesce(profile.lead_distribution_manually_disabled, false)
      or coalesce(profile.lead_distribution_blocked_until > now(), false),
    coalesce(profile.lead_distribution_blocked, false)
      or coalesce(profile.lead_distribution_manually_disabled, false),
    case
      when profile.lead_distribution_manually_disabled and not actor.is_allyson then false
      else coalesce(profile.lead_distribution_manually_disabled, false)
    end,
    case
      when profile.lead_distribution_manually_disabled and not actor.is_allyson then null
      else profile.lead_distribution_blocked_until
    end,
    case
      when profile.lead_distribution_manually_disabled and not actor.is_allyson
        then 'Indisponivel para receber leads'
      else profile.lead_distribution_blocked_reason
    end
  from public.lead_distribution_queue as queue
  join public.profiles as profile on profile.id = queue.broker_id
  cross join actor
  where auth.uid() is not null
  order by queue.lead_type, queue.position, queue.updated_at, queue.id;
$$;

revoke all on function public.list_lead_distribution_status() from public, anon;
grant execute on function public.list_lead_distribution_status() to authenticated;

commit;

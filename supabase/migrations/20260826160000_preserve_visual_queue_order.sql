begin;

-- Preserve the visual FIFO ordering introduced before the authenticated status
-- RPC. Position remains the primary key and updated_at breaks ties fairly.
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
    coalesce(profile.lead_distribution_manually_disabled, false),
    profile.lead_distribution_blocked_until,
    profile.lead_distribution_blocked_reason
  from public.lead_distribution_queue as queue
  join public.profiles as profile on profile.id = queue.broker_id
  where auth.uid() is not null
  order by queue.lead_type, queue.position, queue.updated_at, queue.id;
$$;

revoke all on function public.list_lead_distribution_status() from public, anon;
grant execute on function public.list_lead_distribution_status() to authenticated;

commit;

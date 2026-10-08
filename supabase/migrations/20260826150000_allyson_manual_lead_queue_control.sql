begin;

alter table public.profiles
  add column if not exists lead_distribution_manually_disabled boolean not null default false;

comment on column public.profiles.lead_distribution_manually_disabled is
  'Manual lead queue opt-out controlled exclusively by Allyson.';

create or replace function public.preserve_manual_lead_queue_block()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if new.lead_distribution_manually_disabled then
    new.lead_distribution_blocked := true;
    new.lead_distribution_blocked_reason := 'Desativado manualmente da fila pelo Allyson';
    new.lead_distribution_blocked_at := coalesce(new.lead_distribution_blocked_at, now());
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_preserve_manual_lead_queue_block on public.profiles;
create trigger profiles_preserve_manual_lead_queue_block
before insert or update of lead_distribution_manually_disabled, lead_distribution_blocked,
  lead_distribution_blocked_reason, lead_distribution_blocked_at
on public.profiles
for each row execute function public.preserve_manual_lead_queue_block();

-- Keep the latest companion-feedback rule while making the permanent block the
-- union of an operational feedback block and Allyson's manual queue control.
create or replace function public.refresh_broker_visit_block(p_broker_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
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
            join public.profiles participant_profile on participant_profile.id = participant.user_id
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
              join public.profiles participant_profile on participant_profile.id = participant.user_id
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

  update public.profiles
  set lead_distribution_blocked = has_pending_feedback or coalesce(manually_disabled, false),
      lead_distribution_blocked_reason = case
        when manually_disabled then 'Desativado manualmente da fila pelo Allyson'
        when has_pending_feedback then 'feedback_missing'
        else null
      end,
      lead_distribution_blocked_at = case
        when has_pending_feedback or manually_disabled
          then coalesce(lead_distribution_blocked_at, now())
        else null
      end,
      updated_at = now()
  where id = p_broker_id;

  return has_pending_feedback or coalesce(manually_disabled, false);
end;
$$;

create or replace function public.set_broker_lead_queue_enabled(
  p_broker_id uuid,
  p_enabled boolean
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  actor public.profiles%rowtype;
begin
  select * into actor from public.profiles where id = auth.uid();
  if actor.id is null
     or actor.role is distinct from 'admin'
     or (
       actor.id <> '37094db7-2457-48f2-8573-40c887e547e5'::uuid
       and lower(trim(coalesce(actor.email, ''))) <> 'crmsoniaallyson@gmail.com'
     ) then
    raise exception 'Somente Allyson pode alterar a participacao dos corretores na fila.';
  end if;

  if not exists (
    select 1 from public.profiles profile
    where profile.id = p_broker_id and profile.role = 'broker'
  ) then
    raise exception 'Corretor nao encontrado.';
  end if;

  if p_enabled then
    update public.profiles
    set lead_distribution_manually_disabled = false,
        updated_at = now()
    where id = p_broker_id;

    -- A reativacao manual never removes a valid visit-feedback block.
    perform public.refresh_broker_visit_block(p_broker_id);
  else
    update public.profiles
    set lead_distribution_manually_disabled = true,
        lead_distribution_blocked = true,
        lead_distribution_blocked_reason = 'Desativado manualmente da fila pelo Allyson',
        lead_distribution_blocked_at = coalesce(lead_distribution_blocked_at, now()),
        updated_at = now()
    where id = p_broker_id;
  end if;
end;
$$;

revoke all on function public.set_broker_lead_queue_enabled(uuid, boolean) from public, anon;
grant execute on function public.set_broker_lead_queue_enabled(uuid, boolean) to authenticated;

drop function if exists public.list_lead_distribution_status();
create function public.list_lead_distribution_status()
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
  order by queue.lead_type, queue.position, queue.id;
$$;

revoke all on function public.list_lead_distribution_status() from public, anon;
grant execute on function public.list_lead_distribution_status() to authenticated;

commit;

-- Garante que notificacoes administrativas/repetitivas com data explicita
-- tambem sejam normalizadas para 08:00-19:00 (America/Sao_Paulo).

create or replace function public.crm_apply_notification_business_hours()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  configured_mode text;
  event_moment timestamptz;
begin
  if tg_op = 'UPDATE' then
    if new.kind is not distinct from old.kind
       and new.created_at is not distinct from old.created_at
       and new.available_at is not distinct from old.available_at then
      return new;
    end if;
  end if;

  select policy.delivery_mode
  into configured_mode
  from public.crm_notification_delivery_policies as policy
  where policy.kind = new.kind;

  event_moment := coalesce(new.created_at, now());
  new.available_at := coalesce(new.available_at, event_moment);

  if configured_mode = 'business_hours' then
    new.available_at := public.crm_next_business_moment(
      greatest(new.available_at, event_moment)
    );
  end if;

  return new;
end;
$$;

revoke all on function public.crm_apply_notification_business_hours()
  from public, anon, authenticated;

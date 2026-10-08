-- Todas as notificacoes, sem excecao, funcionam diariamente das 08:30 as 20:00
-- no fuso America/Sao_Paulo. Fora da janela, aguardam a abertura seguinte.
create or replace function public.crm_is_business_hours(
  p_moment timestamptz default now()
)
returns boolean
language sql
stable
set search_path = public
as $$
  select (p_moment at time zone 'America/Sao_Paulo')::time >= time '08:30'
     and (p_moment at time zone 'America/Sao_Paulo')::time < time '20:00';
$$;

create or replace function public.crm_next_business_moment(
  p_moment timestamptz default now()
)
returns timestamptz
language plpgsql
stable
set search_path = public
as $$
declare
  local_moment timestamp := p_moment at time zone 'America/Sao_Paulo';
  next_local timestamp;
begin
  if local_moment::time < time '08:30' then
    next_local := local_moment::date + time '08:30';
  elsif local_moment::time >= time '20:00' then
    next_local := (local_moment::date + 1) + time '08:30';
  else
    return p_moment;
  end if;

  return next_local at time zone 'America/Sao_Paulo';
end;
$$;

create or replace function public.crm_add_business_minutes(
  p_start timestamptz,
  p_minutes integer
)
returns timestamptz
language plpgsql
stable
set search_path = public
as $$
declare
  local_cursor timestamp;
  local_close timestamp;
  available_minutes integer;
  remaining_minutes integer := greatest(coalesce(p_minutes, 0), 0);
begin
  local_cursor := public.crm_next_business_moment(p_start)
    at time zone 'America/Sao_Paulo';

  while remaining_minutes > 0 loop
    local_close := local_cursor::date + time '20:00';
    available_minutes := greatest(
      floor(extract(epoch from (local_close - local_cursor)) / 60)::integer,
      0
    );

    if remaining_minutes <= available_minutes then
      local_cursor := local_cursor + make_interval(mins => remaining_minutes);
      remaining_minutes := 0;
    else
      remaining_minutes := remaining_minutes - available_minutes;
      local_cursor := (local_cursor::date + 1) + time '08:30';
    end if;
  end loop;

  return local_cursor at time zone 'America/Sao_Paulo';
end;
$$;

-- A matriz continua como registro administrativo, mas nenhuma categoria e imediata.
update public.crm_notification_delivery_policies
set delivery_mode = 'business_hours',
    rationale = 'Todas as notificacoes obedecem ao expediente diario de 08:30 a 20:00.',
    updated_at = now();

-- Tipos novos ou ainda nao cadastrados tambem obedecem ao expediente.
create or replace function public.crm_apply_notification_business_hours()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  event_moment timestamptz;
begin
  if tg_op = 'UPDATE' then
    if new.kind is not distinct from old.kind
       and new.created_at is not distinct from old.created_at
       and new.available_at is not distinct from old.available_at then
      return new;
    end if;
  end if;

  event_moment := coalesce(new.created_at, now());
  new.available_at := public.crm_next_business_moment(
    greatest(coalesce(new.available_at, event_moment), event_moment)
  );

  return new;
end;
$$;

-- Normaliza tambem qualquer envio ainda pendente no momento da implantacao.
update public.crm_notification_outbox
set available_at = public.crm_next_business_moment(
  greatest(available_at, now())
)
where delivered_at is null;

revoke all on function public.crm_is_business_hours(timestamptz) from public, anon;
revoke all on function public.crm_next_business_moment(timestamptz) from public, anon;
revoke all on function public.crm_add_business_minutes(timestamptz, integer) from public, anon;
revoke all on function public.crm_apply_notification_business_hours()
  from public, anon, authenticated;
grant execute on function public.crm_is_business_hours(timestamptz)
  to authenticated, service_role;
grant execute on function public.crm_next_business_moment(timestamptz)
  to authenticated, service_role;
grant execute on function public.crm_add_business_minutes(timestamptz, integer)
  to authenticated, service_role;

comment on table public.crm_notification_delivery_policies is
  'Todas as notificacoes obedecem ao expediente diario 08:30-20:00 America/Sao_Paulo, inclusive a esteira de leads.';

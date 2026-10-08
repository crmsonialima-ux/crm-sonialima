begin;

-- As 24 horas de atendimento correm de segunda 00:01 ate sexta 23:59.
-- O relogio fica integralmente pausado entre sexta 23:59 e segunda 00:01,
-- sempre no fuso de Brasilia.
create or replace function public.crm_add_weekday_hours(
  p_start timestamptz,
  p_hours integer
)
returns timestamptz
language plpgsql
stable
set search_path = pg_catalog, public
as $$
declare
  local_cursor timestamp;
  weekday_number integer;
  local_time time;
  pause_start timestamp;
  resume_at timestamp;
  available_interval interval;
  remaining_interval interval;
begin
  if p_start is null then
    return null;
  end if;
  if p_hours is null or p_hours < 0 or p_hours > 8760 then
    raise exception 'Informe uma duracao entre 0 e 8760 horas.';
  end if;

  local_cursor := p_start at time zone 'America/Sao_Paulo';
  weekday_number := extract(isodow from local_cursor)::integer;
  local_time := local_cursor::time;

  if weekday_number = 5 and local_time >= time '23:59' then
    local_cursor := local_cursor::date + 3 + time '00:01';
  elsif weekday_number = 6 then
    local_cursor := local_cursor::date + 2 + time '00:01';
  elsif weekday_number = 7 then
    local_cursor := local_cursor::date + 1 + time '00:01';
  elsif weekday_number = 1 and local_time < time '00:01' then
    local_cursor := local_cursor::date + time '00:01';
  end if;

  remaining_interval := make_interval(hours => p_hours);
  while remaining_interval > interval '0' loop
    weekday_number := extract(isodow from local_cursor)::integer;
    pause_start := local_cursor::date + (5 - weekday_number) + time '23:59';
    resume_at := pause_start::date + 3 + time '00:01';
    available_interval := greatest(pause_start - local_cursor, interval '0');

    if remaining_interval < available_interval then
      local_cursor := local_cursor + remaining_interval;
      remaining_interval := interval '0';
    else
      remaining_interval := remaining_interval - available_interval;
      local_cursor := resume_at;
    end if;
  end loop;

  return local_cursor at time zone 'America/Sao_Paulo';
end;
$$;

revoke all on function public.crm_add_weekday_hours(timestamptz, integer)
  from public, anon, authenticated;
grant execute on function public.crm_add_weekday_hours(timestamptz, integer)
  to authenticated, service_role;

comment on function public.crm_add_weekday_hours(timestamptz, integer) is
  'Soma as 24 horas do atendimento apenas entre segunda 00:01 e sexta 23:59, pausando no fim de semana.';

commit;

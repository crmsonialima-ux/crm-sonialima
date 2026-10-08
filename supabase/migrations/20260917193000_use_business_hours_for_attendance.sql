begin;

-- Todos os prazos comerciais usam dias uteis, das 08:30 as 18:30
-- (horario de Brasilia). Fora desse intervalo, o prazo fica pausado.
create or replace function public.crm_add_commercial_minutes(
  p_start timestamptz,
  p_minutes integer
)
returns timestamptz
language plpgsql
stable
set search_path = pg_catalog, public
as $$
declare
  local_cursor timestamp;
  remaining integer := greatest(coalesce(p_minutes, 0), 0);
  available integer;
begin
  local_cursor := p_start at time zone 'America/Sao_Paulo';
  loop
    if extract(isodow from local_cursor)::integer > 5 then
      local_cursor := local_cursor::date
        + (8 - extract(isodow from local_cursor)::integer)
        + time '08:30';
    elsif local_cursor::time < time '08:30' then
      local_cursor := local_cursor::date + time '08:30';
    elsif local_cursor::time >= time '18:30' then
      local_cursor := local_cursor::date + interval '1 day' + time '08:30';
      continue;
    end if;

    exit when remaining = 0;
    available := floor(extract(epoch from ((local_cursor::date + time '18:30') - local_cursor)) / 60)::integer;
    if remaining <= available then
      local_cursor := local_cursor + make_interval(mins => remaining);
      remaining := 0;
    else
      remaining := remaining - available;
      local_cursor := local_cursor::date + interval '1 day' + time '08:30';
    end if;
  end loop;

  return local_cursor at time zone 'America/Sao_Paulo';
end;
$$;

create or replace function public.enforce_attendance_deadline()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if new.stage = 'Em atendimento'
     and (
       tg_op = 'INSERT'
       or old.stage is distinct from 'Em atendimento'
       or new.assignment_status is distinct from 'accepted'
       or new.assignment_deadline_at is null
     ) then
    new.assignment_status := 'accepted';
    new.assignment_deadline_at := public.crm_add_commercial_minutes(now(), 1440);
  end if;
  return new;
end;
$$;

-- Mantem a mesma regra no aceite e na renovacao sem duplicar as funcoes de
-- seguranca extensas ja instaladas no banco.
do $$
declare definition text;
begin
  select pg_get_functiondef('public.accept_lead_assignment(uuid)'::regprocedure)
    into definition;
  definition := replace(
    definition,
    'else now() + interval ''24 hours'' end,',
    'else public.crm_add_commercial_minutes(now(), 1440) end,'
  );
  if position('public.crm_add_commercial_minutes(now(), 1440)' in definition) = 0 then
    raise exception 'Nao foi possivel atualizar o prazo de aceite para horas comerciais.';
  end if;
  execute definition;

  select pg_get_functiondef('public.extend_lead_attendance(uuid,text)'::regprocedure)
    into definition;
  execute definition;
end;
$$;

-- Reinicia apenas os atendimentos ainda ativos com 24 horas uteis a partir
-- desta correcao. Atendimentos encerrados permanecem intactos.
update public.crm_leads
set assignment_deadline_at = public.crm_add_commercial_minutes(now(), 1440),
    assignment_reminder_sent_at = null,
    updated_at = now()
where stage = 'Em atendimento'
  and assignment_status = 'accepted'
  and assignment_deadline_at > now();

commit;

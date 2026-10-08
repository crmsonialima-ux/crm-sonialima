begin;

-- Atendimento sempre dura 24 horas corridas. A qualificacao e calculada em
-- horario comercial separadamente; ela nao pode transformar o atendimento em
-- 1.440 minutos comerciais (aproximadamente quatro dias corridos).
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
    new.assignment_deadline_at := now() + interval '24 hours';
  end if;

  return new;
end;
$$;

-- Corrige somente os atendimentos ativos que receberam o prazo comercial de
-- quatro dias pelo gatilho anterior. Nao altera atendimentos ja encerrados.
update public.crm_leads
set assignment_deadline_at = now() + interval '24 hours',
    assignment_reminder_sent_at = null,
    updated_at = now()
where stage = 'Em atendimento'
  and assignment_status = 'accepted'
  and assignment_deadline_at > now() + interval '25 hours';

commit;

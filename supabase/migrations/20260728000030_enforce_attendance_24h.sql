-- Garante que a transicao para "Em atendimento" sempre inicia uma janela de 24 horas.
-- Isso tambem protege a sincronizacao da planilha: ela nao pode deixar o prazo antigo
-- de 15 ou 4 minutos quando altera o estagio para atendimento.
create or replace function public.enforce_attendance_deadline()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.stage = 'Em atendimento'
    and (
      tg_op = 'INSERT'
      or old.stage is distinct from 'Em atendimento'
      or new.assignment_status is distinct from 'accepted'
      or new.assignment_deadline_at is null
    )
  then
    new.assignment_status := 'accepted';
    new.assignment_deadline_at := now() + interval '24 hours';
  end if;

  return new;
end;
$$;

drop trigger if exists crm_leads_enforce_attendance_deadline on public.crm_leads;
create trigger crm_leads_enforce_attendance_deadline
before insert or update of stage, assignment_status, assignment_deadline_at
on public.crm_leads
for each row
execute procedure public.enforce_attendance_deadline();

-- Corrige os registros que ficaram em atendimento com o prazo residual de aceite.
update public.crm_leads
set
  assignment_status = 'accepted',
  assignment_deadline_at = now() + interval '24 hours'
where stage = 'Em atendimento'
  and (
    assignment_status is distinct from 'accepted'
    or assignment_deadline_at is null
    or assignment_deadline_at <= now() + interval '30 minutes'
  );

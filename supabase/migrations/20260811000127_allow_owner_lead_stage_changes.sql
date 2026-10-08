begin;

-- Brokers may freely progress their own accepted leads. Only queue-owned
-- technical fields remain protected from direct client updates.
create or replace function public.protect_lead_assignment_system_fields()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  trusted_backend boolean := current_user in (
    'postgres',
    'service_role',
    'supabase_admin'
  );
  allowed_progress_deadline_change boolean;
begin
  if trusted_backend then
    return new;
  end if;

  if old.assignment_status = 'pending'
     and new.stage is distinct from old.stage then
    raise exception 'Aceite o lead pela acao Estou em atendimento antes de alterar sua etapa.';
  elsif old.assignment_status = 'exhausted'
        and new.stage is distinct from old.stage then
    raise exception 'Somente Allyson pode reiniciar e alterar um lead com a esteira esgotada.';
  end if;

  allowed_progress_deadline_change :=
    old.assignment_status = 'accepted'
    and new.assignment_status = 'accepted'
    and new.stage is distinct from old.stage
    and (
      (new.stage = 'Em atendimento' and new.assignment_deadline_at is not null)
      or (new.stage <> 'Em atendimento' and new.assignment_deadline_at is null)
    );

  if new.assignment_status is distinct from old.assignment_status
     or new.assignment_available_at is distinct from old.assignment_available_at
     or new.assignment_run_number is distinct from old.assignment_run_number
     or new.assignment_reminder_sent_at is distinct from old.assignment_reminder_sent_at
     or (
       new.assignment_deadline_at is distinct from old.assignment_deadline_at
       and not allowed_progress_deadline_change
     ) then
    raise exception 'Os controles da esteira so podem ser alterados pelas acoes seguras do CRM.';
  end if;

  return new;
end;
$$;

commit;

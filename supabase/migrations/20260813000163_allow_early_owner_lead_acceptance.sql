-- Permite ao corretor da vez iniciar o atendimento antes da abertura da
-- esteira. O SLA permanece ancorado no horario programado (por exemplo, 09h),
-- portanto o aceite antecipado nao antecipa nem reduz o prazo de atendimento.

create or replace function public.accept_lead_assignment(p_lead_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  current_profile record;
  accepted_run_number integer;
begin
  update public.crm_leads as lead
  set assignment_status = 'accepted',
      assignment_deadline_at = greatest(now(), lead.assignment_available_at)
        + interval '24 hours',
      assignment_available_at = null,
      assignment_reminder_sent_at = null,
      stage = 'Em atendimento'
  where lead.id = p_lead_id
    and lead.owner_id = auth.uid()
    and lead.assignment_status = 'pending'
    and lead.assignment_deadline_at > now()
    and (
      lead.property_catalog_id is null
      or exists (
          select 1
          from public.crm_property_broker_access as access
          join public.lead_distribution_queue as queue
            on queue.broker_id = access.broker_id
           and queue.lead_type = lead.lead_type
          join public.profiles as profile
            on profile.id = access.broker_id
          where access.property_id = lead.property_catalog_id
            and access.broker_id = auth.uid()
            and profile.role = 'broker'
            and not coalesce(profile.lead_distribution_blocked, false)
        )
    )
  returning lead.assignment_run_number into accepted_run_number;

  if not found then
    raise exception 'Este lead nao esta disponivel para aceite ou seu prazo/acesso foi alterado.';
  end if;

  update public.lead_assignment_attempts as attempt
  set accepted_at = now()
  where attempt.lead_id = p_lead_id
    and attempt.broker_id = auth.uid()
    and attempt.run_number = accepted_run_number
    and attempt.accepted_at is null
    and attempt.expired_at is null;

  select profile.full_name, profile.email
  into current_profile
  from public.profiles as profile
  where profile.id = auth.uid();

  insert into public.crm_lead_activities (
    lead_id,
    stage,
    note,
    author_id,
    author_name
  ) values (
    p_lead_id,
    'Em atendimento',
    'Atendimento iniciado em '
      || to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'),
    auth.uid(),
    coalesce(nullif(current_profile.full_name, ''), current_profile.email)
  );
end;
$$;

revoke all on function public.accept_lead_assignment(uuid)
from public, anon;

grant execute on function public.accept_lead_assignment(uuid)
to authenticated;

comment on function public.accept_lead_assignment(uuid) is
  'Permite ao corretor atualmente responsavel aceitar antecipadamente; o SLA de 24 horas continua a partir do horario programado da esteira.';

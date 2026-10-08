-- Recupera os prazos dos leads existentes, criados antes da esteira de atendimento.
update public.crm_leads
set assignment_status = 'accepted',
    assignment_deadline_at = now() + interval '24 hours'
where stage = 'Em atendimento'
  and assignment_deadline_at is null;

with pending_attempts as (
  select lead_id, max(attempt_number) as attempt_number
  from public.lead_assignment_attempts
  where accepted_at is null and expired_at is null
  group by lead_id
)
update public.crm_leads lead
set assignment_status = 'pending',
    assignment_deadline_at = now() + case
      when coalesce(pending_attempts.attempt_number, 1) > 1 then interval '4 minutes'
      else interval '15 minutes'
    end
from pending_attempts
where lead.id = pending_attempts.lead_id
  and lead.stage = 'Aguardando atendimento'
  and lead.assignment_deadline_at is null;

-- Permite ao titular renovar um atendimento legado e o enquadra na regra atual.
create or replace function public.extend_lead_attendance(p_lead_id uuid, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare current_profile record;
begin
  if nullif(trim(p_note), '') is null then
    raise exception 'Informe o motivo para manter o lead em atendimento.';
  end if;

  update public.crm_leads
  set assignment_status = 'accepted',
      assignment_deadline_at = now() + interval '24 hours'
  where id = p_lead_id
    and (owner_id = auth.uid() or public.is_admin())
    and stage = 'Em atendimento';

  if not found then
    raise exception 'Este lead não está disponível para renovação de atendimento.';
  end if;

  select full_name, email into current_profile
  from public.profiles
  where id = auth.uid();

  insert into public.crm_lead_activities (lead_id, stage, note, author_id, author_name)
  values (
    p_lead_id,
    'Ainda em atendimento',
    trim(p_note),
    auth.uid(),
    coalesce(nullif(current_profile.full_name, ''), current_profile.email)
  );
end;
$$;

grant execute on function public.extend_lead_attendance(uuid, text) to authenticated;

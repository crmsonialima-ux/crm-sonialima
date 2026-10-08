-- Registra o aceite diretamente na transação do banco, com data e hora confiáveis.
create or replace function public.accept_lead_assignment(p_lead_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare current_profile record;
begin
  update public.crm_leads
  set assignment_status = 'accepted',
      assignment_deadline_at = now() + interval '24 hours',
      stage = 'Em atendimento'
  where id = p_lead_id
    and owner_id = auth.uid()
    and assignment_status = 'pending';

  if not found then
    raise exception 'Este lead não está mais disponível para aceite.';
  end if;

  update public.lead_assignment_attempts
  set accepted_at = now()
  where lead_id = p_lead_id
    and broker_id = auth.uid()
    and accepted_at is null
    and expired_at is null;

  select full_name, email
    into current_profile
    from public.profiles
   where id = auth.uid();

  insert into public.crm_lead_activities (lead_id, stage, note, author_id, author_name)
  values (
    p_lead_id,
    'Em atendimento',
    'Atendimento iniciado em ' || to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'),
    auth.uid(),
    coalesce(nullif(current_profile.full_name, ''), current_profile.email)
  );
end;
$$;

grant execute on function public.accept_lead_assignment(uuid) to authenticated;

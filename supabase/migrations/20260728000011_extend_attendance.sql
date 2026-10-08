create or replace function public.extend_lead_attendance(p_lead_id uuid, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare current_profile record;
begin
  if nullif(trim(p_note), '') is null then
    raise exception 'Informe o motivo para manter o lead em atendimento.';
  end if;
  update public.crm_leads
  set assignment_deadline_at = now() + interval '24 hours'
  where id = p_lead_id and owner_id = auth.uid()
    and assignment_status = 'accepted' and stage = 'Em atendimento';
  if not found then raise exception 'Este lead não está disponível para renovação de atendimento.'; end if;
  select full_name, email into current_profile from public.profiles where id = auth.uid();
  insert into public.crm_lead_activities (lead_id, stage, note, author_id, author_name)
  values (p_lead_id, 'Ainda em atendimento', trim(p_note), auth.uid(), coalesce(nullif(current_profile.full_name, ''), current_profile.email));
end;
$$;
grant execute on function public.extend_lead_attendance(uuid, text) to authenticated;

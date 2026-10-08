-- O retorno de uma demanda pertence exclusivamente ao usuário demandado.
create or replace function public.feedback_agenda_entry(p_id uuid, p_feedback_at timestamptz, p_note text)
returns void language plpgsql security definer set search_path=public as $$
declare target_id uuid;
begin
  select target_user_id into target_id from public.crm_agenda_entries where id = p_id;
  if target_id is null then raise exception 'Demanda não encontrada.'; end if;
  if auth.uid() is distinct from target_id then
    raise exception 'Somente o responsável por esta demanda pode registrar retorno.';
  end if;
  update public.crm_agenda_entries
    set feedback_at = coalesce(p_feedback_at, now()),
        feedback_note = nullif(trim(p_note), ''),
        feedback_by = auth.uid(), updated_at = now()
  where id = p_id;
end;
$$;

-- Aviso imediato ao responsável quando outra pessoa registra uma demanda na Agenda.
create or replace function public.create_agenda_entry(
  p_category public.agenda_category,
  p_scheduled_at timestamptz,
  p_observation text,
  p_target_user_id uuid
)
returns uuid language plpgsql security definer set search_path=public as $$
declare derley uuid; entry_id uuid;
begin
  select id into derley from public.profiles where lower(email) = 'unassigned-agenda@example.invalid' limit 1;
  if auth.uid() is null then raise exception 'Sessão não encontrada.'; end if;
  if not public.is_admin() and p_target_user_id <> auth.uid() and p_target_user_id <> derley then
    raise exception 'Você só pode adicionar compromissos para si ou para Derley.';
  end if;
  if p_scheduled_at is null or nullif(trim(p_observation), '') is null then
    raise exception 'Informe data, hora e observação.';
  end if;
  insert into public.crm_agenda_entries(category, scheduled_at, observation, target_user_id, created_by)
  values (p_category, p_scheduled_at, trim(p_observation), p_target_user_id, auth.uid())
  returning id into entry_id;
  if p_target_user_id <> auth.uid() then
    insert into public.crm_notification_outbox(recipient_id, kind, title, body, url, payload)
    values (p_target_user_id, 'agenda_new_demand', 'Nova demanda na Agenda', trim(p_observation), '/agenda', jsonb_build_object('agendaId', entry_id));
  end if;
  return entry_id;
end;
$$;

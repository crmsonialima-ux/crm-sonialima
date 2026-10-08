-- Preserva cada retorno da demanda para que novas observações não apaguem o histórico.
alter table public.crm_agenda_entries
  add column if not exists feedback_history jsonb not null default '[]'::jsonb;

update public.crm_agenda_entries
set feedback_history = jsonb_build_array(jsonb_build_object(
  'at', feedback_at,
  'note', feedback_note,
  'by', feedback_by
))
where feedback_at is not null and feedback_history = '[]'::jsonb;

create or replace function public.feedback_agenda_entry(p_id uuid, p_feedback_at timestamptz, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare target_id uuid; registered_at timestamptz;
begin
  select target_user_id into target_id from public.crm_agenda_entries where id = p_id;
  if target_id is null then raise exception 'Demanda não encontrada.'; end if;
  if auth.uid() is distinct from target_id then raise exception 'Somente o responsável por esta demanda pode registrar retorno.'; end if;

  registered_at := coalesce(p_feedback_at, now());
  update public.crm_agenda_entries
  set feedback_at = registered_at,
      feedback_note = nullif(trim(coalesce(p_note, '')), ''),
      feedback_by = auth.uid(),
      feedback_history = coalesce(feedback_history, '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
        'at', registered_at,
        'note', nullif(trim(coalesce(p_note, '')), ''),
        'by', auth.uid()
      )),
      updated_at = now()
  where id = p_id;
end;
$$;

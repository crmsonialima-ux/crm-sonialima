-- Derley é o responsável pelo protocolo; o admin pode intervir se for necessário.
create or replace function public.attach_agenda_cartorio_protocols(
  p_id uuid,
  p_protocol_paths jsonb,
  p_entry_date date,
  p_expected_date date
)
returns void language plpgsql security definer set search_path = public as $$
declare derley uuid; current_paths jsonb; next_paths jsonb; entry_date_value date; expected_date_value date;
begin
  select id into derley from public.profiles where lower(email) = 'unassigned-agenda@example.invalid' limit 1;
  if auth.uid() <> derley and not public.is_admin() then raise exception 'Somente Derley ou admin podem anexar o protocolo.'; end if;
  if jsonb_typeof(p_protocol_paths) <> 'array' or jsonb_array_length(p_protocol_paths) < 1 then raise exception 'Selecione ao menos um arquivo.'; end if;
  select coalesce(protocol_paths, '[]'::jsonb), coalesce(protocol_entry_date, p_entry_date), coalesce(protocol_expected_date, p_expected_date)
  into current_paths, entry_date_value, expected_date_value
  from public.crm_agenda_entries where id = p_id and category = 'cartorio' and target_user_id = derley for update;
  if not found then raise exception 'Demanda de Cartório não encontrada.'; end if;
  if entry_date_value is null or expected_date_value is null then raise exception 'Informe a data de entrada e a data prevista para buscar.'; end if;
  if expected_date_value < entry_date_value then raise exception 'A data prevista não pode ser anterior à data de entrada.'; end if;
  next_paths := current_paths || p_protocol_paths;
  if jsonb_array_length(next_paths) > 5 then raise exception 'É permitido anexar no máximo 5 arquivos.'; end if;
  update public.crm_agenda_entries
  set protocol_paths = next_paths, protocol_path = coalesce(protocol_path, p_protocol_paths ->> 0), protocol_uploaded_at = now(),
      protocol_entry_date = entry_date_value, protocol_expected_date = expected_date_value, updated_at = now()
  where id = p_id;
end;
$$;

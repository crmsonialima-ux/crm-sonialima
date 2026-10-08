-- As datas do protocolo são salvas antes do envio dos arquivos e ficam imutáveis.
create or replace function public.save_agenda_cartorio_protocol_dates(
  p_id uuid,
  p_entry_date date,
  p_expected_date date
)
returns public.crm_agenda_entries
language plpgsql
security definer
set search_path = public
as $$
declare entry public.crm_agenda_entries; derley uuid;
begin
  select id into derley from public.profiles where lower(email) = 'unassigned-agenda@example.invalid' limit 1;
  if auth.uid() <> derley and not public.is_admin() then raise exception 'Somente Derley ou admin podem salvar os dados do protocolo.'; end if;
  if p_entry_date is null or p_expected_date is null then raise exception 'Informe a data de entrada e a data prevista para buscar.'; end if;
  if p_expected_date < p_entry_date then raise exception 'A data prevista não pode ser anterior à data de entrada.'; end if;

  select * into entry from public.crm_agenda_entries
  where id = p_id and category = 'cartorio' and target_user_id = derley for update;
  if not found then raise exception 'Demanda de Cartório não encontrada.'; end if;
  if entry.protocol_entry_date is not null or entry.protocol_expected_date is not null then
    raise exception 'As datas do protocolo já foram salvas e não podem ser alteradas.';
  end if;

  update public.crm_agenda_entries
  set protocol_entry_date = p_entry_date, protocol_expected_date = p_expected_date, updated_at = now()
  where id = p_id returning * into entry;
  return entry;
end;
$$;

grant execute on function public.save_agenda_cartorio_protocol_dates(uuid,date,date) to authenticated;

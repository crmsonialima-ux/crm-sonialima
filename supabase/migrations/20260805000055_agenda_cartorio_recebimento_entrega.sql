-- Marcos imutáveis do fluxo de Cartório: registrados somente pelo Derley.
alter table public.crm_agenda_entries
  add column if not exists cartorio_received_at timestamptz,
  add column if not exists cartorio_delivered_to_vitor_at timestamptz;

create or replace function public.register_agenda_cartorio_milestone(
  p_id uuid,
  p_milestone text
)
returns public.crm_agenda_entries
language plpgsql
security definer
set search_path = public
as $$
declare
  entry public.crm_agenda_entries;
  derley uuid;
begin
  select id into derley from public.profiles where lower(email) = 'unassigned-agenda@example.invalid' limit 1;
  if derley is null or auth.uid() <> derley then
    raise exception 'Somente Derley pode registrar os horários do Cartório.';
  end if;

  select * into entry
  from public.crm_agenda_entries
  where id = p_id and category = 'cartorio' and target_user_id = derley
  for update;

  if not found then raise exception 'Demanda de Cartório não encontrada.'; end if;

  if p_milestone = 'received' then
    if entry.cartorio_received_at is not null then
      raise exception 'O horário de recebimento já foi registrado e não pode ser alterado.';
    end if;
    update public.crm_agenda_entries
      set cartorio_received_at = now(), updated_at = now()
      where id = p_id
      returning * into entry;
  elsif p_milestone = 'delivered_to_vitor' then
    if entry.cartorio_delivered_to_vitor_at is not null then
      raise exception 'O horário de entrega ao Vitor já foi registrado e não pode ser alterado.';
    end if;
    update public.crm_agenda_entries
      set cartorio_delivered_to_vitor_at = now(), updated_at = now()
      where id = p_id
      returning * into entry;
  else
    raise exception 'Marco de Cartório inválido.';
  end if;

  return entry;
end;
$$;

grant execute on function public.register_agenda_cartorio_milestone(uuid,text) to authenticated;

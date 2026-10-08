alter table public.crm_agenda_entries
  add column if not exists protocol_confirmed_at timestamptz,
  add column if not exists protocol_confirmed_by uuid references public.profiles(id);

create or replace function public.confirm_agenda_cartorio_protocol(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare derley uuid;
begin
  select id into derley from public.profiles where lower(email) = 'unassigned-agenda@example.invalid' limit 1;
  if auth.uid() <> derley then raise exception 'Somente Derley pode confirmar o protocolo.'; end if;
  update public.crm_agenda_entries
  set protocol_confirmed_at = now(), protocol_confirmed_by = auth.uid(), updated_at = now()
  where id = p_id
    and category = 'cartorio'
    and target_user_id = derley
    and protocol_path is not null;
  if not found then raise exception 'Anexe a foto do protocolo antes de confirmar.'; end if;
end;
$$;

grant execute on function public.confirm_agenda_cartorio_protocol(uuid) to authenticated;

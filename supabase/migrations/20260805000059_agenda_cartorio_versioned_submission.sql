-- Fluxo atômico e auditável do protocolo de Cartório.
alter table public.crm_agenda_entries
  add column if not exists cartorio_protocol_versions jsonb not null default '[]'::jsonb,
  add column if not exists cartorio_protocol_revision_count integer not null default 0;

-- Preserva protocolos completos criados antes desta versão como a primeira versão.
update public.crm_agenda_entries
set cartorio_protocol_versions = jsonb_build_array(jsonb_build_object(
      'version', 1,
      'entry_date', protocol_entry_date,
      'expected_date', protocol_expected_date,
      'paths', coalesce(protocol_paths, '[]'::jsonb),
      'saved_at', coalesce(protocol_uploaded_at, updated_at),
      'saved_by', target_user_id,
      'received_at', cartorio_received_at,
      'delivered_to_vitor_at', cartorio_delivered_to_vitor_at
    )),
    cartorio_protocol_revision_count = 1
where category = 'cartorio'
  and cartorio_protocol_revision_count = 0
  and jsonb_array_length(coalesce(protocol_paths, '[]'::jsonb)) > 0;

create or replace function public.save_agenda_cartorio_submission(
  p_id uuid,
  p_entry_date date,
  p_expected_date date,
  p_protocol_paths jsonb
)
returns public.crm_agenda_entries
language plpgsql
security definer
set search_path = public
as $$
declare
  entry public.crm_agenda_entries;
  derley uuid;
  next_version integer;
  saved_at timestamptz := now();
  snapshot jsonb;
begin
  select id into derley from public.profiles where lower(email) = 'unassigned-agenda@example.invalid' limit 1;
  if derley is null or auth.uid() <> derley then
    raise exception 'Somente Derley pode salvar o protocolo do Cartório.';
  end if;
  if p_entry_date is null or p_expected_date is null then
    raise exception 'Informe a data de entrada e a data prevista para buscar.';
  end if;
  if p_expected_date < p_entry_date then
    raise exception 'A data prevista não pode ser anterior à data de entrada.';
  end if;
  if jsonb_typeof(p_protocol_paths) <> 'array'
     or jsonb_array_length(p_protocol_paths) < 1
     or jsonb_array_length(p_protocol_paths) > 5 then
    raise exception 'Anexe de 1 a 5 arquivos.';
  end if;

  select * into entry
  from public.crm_agenda_entries
  where id = p_id and category = 'cartorio' and target_user_id = derley
  for update;
  if not found then raise exception 'Demanda de Cartório não encontrada.'; end if;
  if entry.cartorio_protocol_revision_count >= 2 then
    raise exception 'A correção permitida já foi utilizada.';
  end if;

  next_version := entry.cartorio_protocol_revision_count + 1;
  snapshot := jsonb_build_object(
    'version', next_version,
    'entry_date', p_entry_date,
    'expected_date', p_expected_date,
    'paths', p_protocol_paths,
    'saved_at', saved_at,
    'saved_by', auth.uid(),
    'received_at', null,
    'delivered_to_vitor_at', null
  );

  update public.crm_agenda_entries
  set protocol_entry_date = p_entry_date,
      protocol_expected_date = p_expected_date,
      protocol_paths = p_protocol_paths,
      protocol_path = p_protocol_paths ->> 0,
      protocol_uploaded_at = saved_at,
      cartorio_received_at = null,
      cartorio_delivered_to_vitor_at = null,
      cartorio_protocol_versions = coalesce(cartorio_protocol_versions, '[]'::jsonb) || jsonb_build_array(snapshot),
      cartorio_protocol_revision_count = next_version,
      updated_at = saved_at
  where id = p_id
  returning * into entry;

  return entry;
end;
$$;

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
  registered_at timestamptz := now();
  version_index integer;
begin
  select id into derley from public.profiles where lower(email) = 'unassigned-agenda@example.invalid' limit 1;
  if derley is null or auth.uid() <> derley then
    raise exception 'Somente Derley pode registrar os horários do Cartório.';
  end if;

  select * into entry from public.crm_agenda_entries
  where id = p_id and category = 'cartorio' and target_user_id = derley
  for update;
  if not found then raise exception 'Demanda de Cartório não encontrada.'; end if;
  if entry.cartorio_protocol_revision_count < 1 then
    raise exception 'Salve primeiro as datas e os anexos.';
  end if;
  version_index := jsonb_array_length(entry.cartorio_protocol_versions) - 1;

  if p_milestone = 'received' then
    if entry.cartorio_received_at is not null then
      raise exception 'O horário de recebimento já foi registrado.';
    end if;
    update public.crm_agenda_entries
    set cartorio_received_at = registered_at,
        cartorio_protocol_versions = jsonb_set(cartorio_protocol_versions, array[version_index::text, 'received_at'], to_jsonb(registered_at), true),
        updated_at = registered_at
    where id = p_id returning * into entry;
  elsif p_milestone = 'delivered_to_vitor' then
    if entry.cartorio_delivered_to_vitor_at is not null then
      raise exception 'O horário de entrega ao Vitor já foi registrado.';
    end if;
    update public.crm_agenda_entries
    set cartorio_delivered_to_vitor_at = registered_at,
        cartorio_protocol_versions = jsonb_set(cartorio_protocol_versions, array[version_index::text, 'delivered_to_vitor_at'], to_jsonb(registered_at), true),
        updated_at = registered_at
    where id = p_id returning * into entry;
  else
    raise exception 'Marco de Cartório inválido.';
  end if;

  return entry;
end;
$$;

grant execute on function public.save_agenda_cartorio_submission(uuid,date,date,jsonb) to authenticated;
grant execute on function public.register_agenda_cartorio_milestone(uuid,text) to authenticated;

-- Impede o uso dos fluxos antigos que salvavam partes separadas.
revoke execute on function public.attach_agenda_cartorio_protocols(uuid,jsonb,date,date) from authenticated;
revoke execute on function public.save_agenda_cartorio_protocol_dates(uuid,date,date) from authenticated;

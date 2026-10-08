-- Etapa final do Cartorio: Vitor digitaliza o documento depois de recebe-lo do Derley.
alter table public.crm_agenda_entries
  add column if not exists cartorio_vitor_document_paths jsonb not null default '[]'::jsonb,
  add column if not exists cartorio_vitor_document_uploaded_at timestamptz,
  add column if not exists cartorio_vitor_document_uploaded_by uuid references public.profiles(id),
  add column if not exists cartorio_vitor_tracking_started_at timestamptz,
  add column if not exists cartorio_vitor_document_last_reminder_at timestamptz,
  add column if not exists cartorio_vitor_document_admin_notified_at timestamptz;

-- Demandas entregues antes desta funcionalidade comecam a contar a partir da implantacao,
-- evitando uma enxurrada de alertas retroativos.
update public.crm_agenda_entries
set cartorio_vitor_tracking_started_at = now()
where category = 'cartorio'
  and cartorio_delivered_to_vitor_at is not null
  and cartorio_vitor_tracking_started_at is null
  and jsonb_array_length(coalesce(cartorio_vitor_document_paths, '[]'::jsonb)) = 0;

insert into storage.buckets (id, name, public)
values ('agenda-vitor-documents', 'agenda-vitor-documents', false)
on conflict (id) do nothing;

drop policy if exists "Cartorio team reads Vitor documents" on storage.objects;
create policy "Cartorio team reads Vitor documents"
on storage.objects for select to authenticated
using (
  bucket_id = 'agenda-vitor-documents'
  and (
    public.is_admin()
    or exists (
      select 1
      from public.profiles p
      where p.id = auth.uid()
        and lower(p.email) in ('unassigned-agenda@example.invalid', 'unassigned-operator@example.invalid')
    )
  )
);

drop policy if exists "Vitor uploads digitized Cartorio documents" on storage.objects;
create policy "Vitor uploads digitized Cartorio documents"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'agenda-vitor-documents'
  and exists (
    select 1
    from public.profiles p
    where p.id = auth.uid() and lower(p.email) = 'unassigned-operator@example.invalid'
  )
);

-- Mantem os marcos imutaveis e cria o aviso ao Vitor na mesma transacao da entrega.
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
  vitor uuid;
  registered_at timestamptz := now();
  version_index integer;
  notification_body text;
begin
  select id into derley from public.profiles where lower(email) = 'unassigned-agenda@example.invalid' limit 1;
  if derley is null or auth.uid() <> derley then
    raise exception 'Somente Derley pode registrar os horarios do Cartorio.';
  end if;

  select * into entry
  from public.crm_agenda_entries
  where id = p_id and category = 'cartorio' and target_user_id = derley
  for update;
  if not found then raise exception 'Demanda de Cartorio nao encontrada.'; end if;
  if entry.cartorio_protocol_revision_count < 1 then
    raise exception 'Salve primeiro as datas e os anexos.';
  end if;
  version_index := jsonb_array_length(entry.cartorio_protocol_versions) - 1;

  if p_milestone = 'received' then
    if entry.cartorio_received_at is not null then
      raise exception 'O horario de recebimento ja foi registrado.';
    end if;
    update public.crm_agenda_entries
    set cartorio_received_at = registered_at,
        cartorio_protocol_versions = jsonb_set(cartorio_protocol_versions, array[version_index::text, 'received_at'], to_jsonb(registered_at), true),
        updated_at = registered_at
    where id = p_id
    returning * into entry;
  elsif p_milestone = 'delivered_to_vitor' then
    if entry.cartorio_delivered_to_vitor_at is not null then
      raise exception 'O horario de entrega ao Vitor ja foi registrado.';
    end if;

    select id into vitor from public.profiles where lower(email) = 'unassigned-operator@example.invalid' limit 1;
    if vitor is null then raise exception 'Perfil do Vitor nao encontrado.'; end if;

    update public.crm_agenda_entries
    set cartorio_delivered_to_vitor_at = registered_at,
        cartorio_vitor_tracking_started_at = registered_at,
        cartorio_vitor_document_last_reminder_at = null,
        cartorio_vitor_document_admin_notified_at = null,
        cartorio_protocol_versions = jsonb_set(cartorio_protocol_versions, array[version_index::text, 'delivered_to_vitor_at'], to_jsonb(registered_at), true),
        updated_at = registered_at
    where id = p_id
    returning * into entry;

    notification_body := 'Documento de Cartorio entregue para digitalizacao. Cliente: '
      || coalesce(nullif(entry.cartorio_client_name, ''), 'nao informado')
      || '. Imovel: ' || coalesce(nullif(entry.cartorio_property_address, ''), 'nao informado') || '.';

    insert into public.crm_notification_outbox(recipient_id, kind, title, body, url, payload)
    values (
      vitor,
      'agenda_cartorio_delivered_to_vitor',
      'Documento de Cartorio entregue a voce',
      notification_body,
      '/agenda',
      jsonb_build_object('agendaId', entry.id)
    );
  else
    raise exception 'Marco de Cartorio invalido.';
  end if;

  return entry;
end;
$$;

create or replace function public.save_agenda_cartorio_vitor_documents(
  p_id uuid,
  p_document_paths jsonb
)
returns public.crm_agenda_entries
language plpgsql
security definer
set search_path = public
as $$
declare
  entry public.crm_agenda_entries;
  vitor uuid;
  path_value text;
  uploaded_at timestamptz := now();
begin
  select id into vitor from public.profiles where lower(email) = 'unassigned-operator@example.invalid' limit 1;
  if vitor is null or auth.uid() <> vitor then
    raise exception 'Somente Vitor pode anexar o documento digitalizado.';
  end if;
  if jsonb_typeof(p_document_paths) <> 'array'
     or jsonb_array_length(p_document_paths) < 1
     or jsonb_array_length(p_document_paths) > 5 then
    raise exception 'Anexe de 1 a 5 arquivos.';
  end if;
  for path_value in select jsonb_array_elements_text(p_document_paths)
  loop
    if nullif(trim(path_value), '') is null
       or position(p_id::text || '/vitor-' in path_value) <> 1 then
      raise exception 'Caminho de documento invalido.';
    end if;
  end loop;

  select * into entry
  from public.crm_agenda_entries
  where id = p_id and category = 'cartorio'
  for update;
  if not found then raise exception 'Demanda de Cartorio nao encontrada.'; end if;
  if entry.cartorio_delivered_to_vitor_at is null then
    raise exception 'O Derley ainda nao registrou a entrega ao Vitor.';
  end if;
  if jsonb_array_length(coalesce(entry.cartorio_vitor_document_paths, '[]'::jsonb)) > 0 then
    raise exception 'O documento digitalizado ja foi salvo.';
  end if;

  update public.crm_agenda_entries
  set cartorio_vitor_document_paths = p_document_paths,
      cartorio_vitor_document_uploaded_at = uploaded_at,
      cartorio_vitor_document_uploaded_by = auth.uid(),
      updated_at = uploaded_at
  where id = p_id
  returning * into entry;

  return entry;
end;
$$;

create or replace function public.process_agenda_cartorio_vitor_document_notifications()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  entry record;
  vitor uuid;
  notification_body text;
begin
  select id into vitor from public.profiles where lower(email) = 'unassigned-operator@example.invalid' limit 1;

  if vitor is not null then
    for entry in
      select *
      from public.crm_agenda_entries
      where category = 'cartorio'
        and cartorio_delivered_to_vitor_at is not null
        and cartorio_vitor_tracking_started_at is not null
        and jsonb_array_length(coalesce(cartorio_vitor_document_paths, '[]'::jsonb)) = 0
        and cartorio_vitor_tracking_started_at + interval '1 hour' <= now()
        and (
          cartorio_vitor_document_last_reminder_at is null
          or cartorio_vitor_document_last_reminder_at + interval '1 hour' <= now()
        )
      for update skip locked
    loop
      notification_body := 'Digitalize e anexe o documento do cliente '
        || coalesce(nullif(entry.cartorio_client_name, ''), 'nao informado')
        || '. Entregue por Derley em '
        || to_char(entry.cartorio_delivered_to_vitor_at at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || '.';
      insert into public.crm_notification_outbox(recipient_id, kind, title, body, url, payload)
      values (
        vitor,
        'agenda_cartorio_vitor_document_reminder',
        'Documento de Cartorio aguardando digitalizacao',
        notification_body,
        '/agenda',
        jsonb_build_object('agendaId', entry.id)
      );
      update public.crm_agenda_entries
      set cartorio_vitor_document_last_reminder_at = now()
      where id = entry.id;
    end loop;
  end if;

  for entry in
    select *
    from public.crm_agenda_entries
    where category = 'cartorio'
      and cartorio_delivered_to_vitor_at is not null
      and cartorio_vitor_tracking_started_at is not null
      and jsonb_array_length(coalesce(cartorio_vitor_document_paths, '[]'::jsonb)) = 0
      and cartorio_vitor_tracking_started_at + interval '24 hours' <= now()
      and cartorio_vitor_document_admin_notified_at is null
    for update skip locked
  loop
    notification_body := 'Vitor ainda nao anexou o documento digitalizado do cliente '
      || coalesce(nullif(entry.cartorio_client_name, ''), 'nao informado')
      || ', entregue por Derley ha 24 horas.';
    insert into public.crm_notification_outbox(recipient_id, kind, title, body, url, payload)
    select
      id,
      'agenda_cartorio_vitor_document_overdue',
      'Digitalizacao de Cartorio pendente ha 24 horas',
      notification_body,
      '/agenda',
      jsonb_build_object('agendaId', entry.id)
    from public.profiles
    where role = 'admin';

    update public.crm_agenda_entries
    set cartorio_vitor_document_admin_notified_at = now()
    where id = entry.id;
  end loop;
end;
$$;

grant execute on function public.register_agenda_cartorio_milestone(uuid,text) to authenticated;
grant execute on function public.save_agenda_cartorio_vitor_documents(uuid,jsonb) to authenticated;
grant execute on function public.process_agenda_cartorio_vitor_document_notifications() to authenticated;

do $$
declare existing_job bigint;
begin
  for existing_job in
    select jobid from cron.job where jobname = 'agenda-cartorio-vitor-document-reminders'
  loop
    perform cron.unschedule(existing_job);
  end loop;
end;
$$;

select cron.schedule(
  'agenda-cartorio-vitor-document-reminders',
  '*/15 * * * *',
  $$select public.process_agenda_cartorio_vitor_document_notifications();$$
);

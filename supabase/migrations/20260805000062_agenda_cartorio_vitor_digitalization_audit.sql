-- Reforca a etapa de digitalizacao: limite de arquivos, auditoria por versao e reinicio em correcao.
update storage.buckets
set file_size_limit = 20971520,
    allowed_mime_types = array[
      'image/jpeg',
      'image/png',
      'image/webp',
      'image/heic',
      'image/heif',
      'application/pdf'
    ]
where id = 'agenda-vitor-documents';

create index if not exists crm_agenda_cartorio_vitor_document_due_idx
  on public.crm_agenda_entries (
    cartorio_vitor_tracking_started_at,
    cartorio_vitor_document_last_reminder_at
  )
  where category = 'cartorio'
    and cartorio_delivered_to_vitor_at is not null
    and cartorio_vitor_document_uploaded_at is null;

create or replace function public.prepare_agenda_cartorio_vitor_document_stage()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.category = 'cartorio' then
    -- Uma correcao do protocolo cria uma nova etapa de entrega e preserva a anterior no JSON de auditoria.
    if new.cartorio_protocol_revision_count > old.cartorio_protocol_revision_count then
      new.cartorio_vitor_document_paths := '[]'::jsonb;
      new.cartorio_vitor_document_uploaded_at := null;
      new.cartorio_vitor_document_uploaded_by := null;
      new.cartorio_vitor_tracking_started_at := null;
      new.cartorio_vitor_document_last_reminder_at := null;
      new.cartorio_vitor_document_admin_notified_at := null;
    end if;

    if old.cartorio_delivered_to_vitor_at is null
       and new.cartorio_delivered_to_vitor_at is not null then
      new.cartorio_vitor_document_paths := '[]'::jsonb;
      new.cartorio_vitor_document_uploaded_at := null;
      new.cartorio_vitor_document_uploaded_by := null;
      new.cartorio_vitor_tracking_started_at := new.cartorio_delivered_to_vitor_at;
      new.cartorio_vitor_document_last_reminder_at := null;
      new.cartorio_vitor_document_admin_notified_at := null;
    end if;
  end if;
  return new;
end;
$$;

revoke all on function public.prepare_agenda_cartorio_vitor_document_stage() from public, anon, authenticated;

drop trigger if exists crm_agenda_prepare_cartorio_vitor_document_stage on public.crm_agenda_entries;
create trigger crm_agenda_prepare_cartorio_vitor_document_stage
before update of cartorio_protocol_revision_count, cartorio_delivered_to_vitor_at
on public.crm_agenda_entries
for each row execute function public.prepare_agenda_cartorio_vitor_document_stage();

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
  version_index integer;
  versions jsonb;
begin
  select id into vitor from public.profiles where lower(email) = 'unassigned-operator@example.invalid' limit 1;
  if vitor is null or auth.uid() is distinct from vitor then
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
  if entry.cartorio_vitor_document_uploaded_at is not null
     or jsonb_array_length(coalesce(entry.cartorio_vitor_document_paths, '[]'::jsonb)) > 0 then
    raise exception 'O documento digitalizado ja foi salvo.';
  end if;
  if entry.cartorio_protocol_revision_count < 1
     or jsonb_array_length(coalesce(entry.cartorio_protocol_versions, '[]'::jsonb)) < 1 then
    raise exception 'Versao do protocolo nao encontrada.';
  end if;

  version_index := jsonb_array_length(entry.cartorio_protocol_versions) - 1;
  versions := jsonb_set(
    jsonb_set(
      jsonb_set(
        entry.cartorio_protocol_versions,
        array[version_index::text, 'vitor_document_paths'],
        p_document_paths,
        true
      ),
      array[version_index::text, 'vitor_document_uploaded_at'],
      to_jsonb(uploaded_at),
      true
    ),
    array[version_index::text, 'vitor_document_uploaded_by'],
    to_jsonb(auth.uid()),
    true
  );

  update public.crm_agenda_entries
  set cartorio_vitor_document_paths = p_document_paths,
      cartorio_vitor_document_uploaded_at = uploaded_at,
      cartorio_vitor_document_uploaded_by = auth.uid(),
      cartorio_protocol_versions = versions,
      updated_at = uploaded_at
  where id = p_id
  returning * into entry;

  return entry;
end;
$$;

revoke all on function public.save_agenda_cartorio_vitor_documents(uuid,jsonb) from public, anon;
grant execute on function public.save_agenda_cartorio_vitor_documents(uuid,jsonb) to authenticated;
revoke all on function public.process_agenda_cartorio_vitor_document_notifications() from public, anon, authenticated;
grant execute on function public.process_agenda_cartorio_vitor_document_notifications() to service_role;

-- Executa a cada minuto; a funcao so cria um novo aviso quando completou uma hora do anterior.
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
  '* * * * *',
  $$select public.process_agenda_cartorio_vitor_document_notifications();$$
);

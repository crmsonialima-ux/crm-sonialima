begin;

drop policy if exists "Only Allyson deletes agenda attachments" on storage.objects;
create policy "Only Allyson deletes agenda attachments"
on storage.objects for delete to authenticated
using (
  bucket_id in ('agenda-protocols', 'agenda-vitor-documents')
  and public.is_allyson_admin()
);

create or replace function public.delete_agenda_attachment(
  p_id uuid,
  p_bucket text,
  p_path text
)
returns public.crm_agenda_entries
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  entry public.crm_agenda_entries%rowtype;
  next_paths jsonb;
  next_versions jsonb;
begin
  if not public.is_allyson_admin() then
    raise exception 'Somente Allyson pode excluir anexos da agenda.';
  end if;
  if p_bucket not in ('agenda-protocols', 'agenda-vitor-documents') then
    raise exception 'Tipo de anexo da agenda inválido.';
  end if;
  if nullif(trim(p_path), '') is null then
    raise exception 'Anexo não informado.';
  end if;

  select agenda.* into entry
  from public.crm_agenda_entries as agenda
  where agenda.id = p_id
  for update;
  if not found then
    raise exception 'Demanda da agenda não encontrada.';
  end if;

  if p_bucket = 'agenda-protocols' then
    if not coalesce(entry.protocol_paths, '[]'::jsonb) ? p_path
       and entry.protocol_path is distinct from p_path then
      raise exception 'Este anexo não pertence à demanda informada.';
    end if;

    select coalesce(jsonb_agg(to_jsonb(item.value) order by item.ordinality), '[]'::jsonb)
    into next_paths
    from jsonb_array_elements_text(coalesce(entry.protocol_paths, '[]'::jsonb))
      with ordinality as item(value, ordinality)
    where item.value <> p_path;

    select coalesce(
      jsonb_agg(
        case
          when jsonb_typeof(version.value -> 'paths') = 'array' then
            jsonb_set(
              version.value,
              '{paths}',
              (
                select coalesce(
                  jsonb_agg(to_jsonb(version_path.value) order by version_path.ordinality),
                  '[]'::jsonb
                )
                from jsonb_array_elements_text(version.value -> 'paths')
                  with ordinality as version_path(value, ordinality)
                where version_path.value <> p_path
              )
            )
          else version.value
        end
        order by version.ordinality
      ),
      '[]'::jsonb
    ) into next_versions
    from jsonb_array_elements(coalesce(entry.cartorio_protocol_versions, '[]'::jsonb))
      with ordinality as version(value, ordinality);

    update public.crm_agenda_entries as agenda
    set protocol_paths = next_paths,
        protocol_path = next_paths ->> 0,
        protocol_uploaded_at = case
          when jsonb_array_length(next_paths) = 0 then null
          else agenda.protocol_uploaded_at
        end,
        cartorio_protocol_versions = next_versions,
        updated_at = now()
    where agenda.id = entry.id
    returning agenda.* into entry;
  else
    if not coalesce(entry.cartorio_vitor_document_paths, '[]'::jsonb) ? p_path then
      raise exception 'Este documento não pertence à demanda informada.';
    end if;

    select coalesce(jsonb_agg(to_jsonb(item.value) order by item.ordinality), '[]'::jsonb)
    into next_paths
    from jsonb_array_elements_text(coalesce(entry.cartorio_vitor_document_paths, '[]'::jsonb))
      with ordinality as item(value, ordinality)
    where item.value <> p_path;

    select coalesce(
      jsonb_agg(
        case
          when jsonb_typeof(version.value -> 'vitor_document_paths') = 'array' then
            jsonb_set(
              version.value,
              '{vitor_document_paths}',
              (
                select coalesce(
                  jsonb_agg(to_jsonb(version_path.value) order by version_path.ordinality),
                  '[]'::jsonb
                )
                from jsonb_array_elements_text(version.value -> 'vitor_document_paths')
                  with ordinality as version_path(value, ordinality)
                where version_path.value <> p_path
              )
            )
          else version.value
        end
        order by version.ordinality
      ),
      '[]'::jsonb
    ) into next_versions
    from jsonb_array_elements(coalesce(entry.cartorio_protocol_versions, '[]'::jsonb))
      with ordinality as version(value, ordinality);

    update public.crm_agenda_entries as agenda
    set cartorio_vitor_document_paths = next_paths,
        cartorio_vitor_document_uploaded_at = case
          when jsonb_array_length(next_paths) = 0 then null
          else agenda.cartorio_vitor_document_uploaded_at
        end,
        cartorio_vitor_document_uploaded_by = case
          when jsonb_array_length(next_paths) = 0 then null
          else agenda.cartorio_vitor_document_uploaded_by
        end,
        cartorio_protocol_versions = next_versions,
        updated_at = now()
    where agenda.id = entry.id
    returning agenda.* into entry;
  end if;

  return entry;
end;
$$;

revoke all on function public.delete_agenda_attachment(uuid,text,text)
from public, anon;
grant execute on function public.delete_agenda_attachment(uuid,text,text)
to authenticated;

commit;

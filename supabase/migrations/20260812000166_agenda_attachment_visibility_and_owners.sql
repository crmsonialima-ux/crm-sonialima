begin;

-- Todos os usuários autenticados podem apenas visualizar e baixar os protocolos do Derley.
drop policy if exists "Authenticated users read agenda protocols" on storage.objects;
create policy "Authenticated users read agenda protocols"
on storage.objects for select to authenticated
using (bucket_id = 'agenda-protocols');

-- O documento digitalizado do Vitor continua restrito à equipe do Cartório e aos admins.
drop policy if exists "Cartorio team reads Vitor documents" on storage.objects;
drop policy if exists "All authenticated users read agenda documents" on storage.objects;
create policy "Cartorio team reads Vitor documents"
on storage.objects for select to authenticated
using (
  bucket_id = 'agenda-vitor-documents'
  and (
    public.is_admin()
    or exists (
      select 1 from public.profiles as profile
      where profile.id = auth.uid()
        and lower(trim(profile.email)) in (
          'unassigned-agenda@example.invalid',
          'unassigned-operator@example.invalid'
        )
    )
  )
);

-- Exclusão física: Allyson ou o dono do respectivo anexo.
drop policy if exists "Only Allyson deletes agenda attachments" on storage.objects;
drop policy if exists "Agenda attachment owners delete own files" on storage.objects;
create policy "Agenda attachment owners delete own files"
on storage.objects for delete to authenticated
using (
  bucket_id in ('agenda-protocols', 'agenda-vitor-documents')
  and (
    public.is_allyson_admin()
    or (
      bucket_id = 'agenda-protocols'
      and exists (
        select 1 from public.profiles as profile
        where profile.id = auth.uid()
          and lower(trim(profile.email)) = 'unassigned-agenda@example.invalid'
      )
    )
    or (
      bucket_id = 'agenda-vitor-documents'
      and exists (
        select 1 from public.crm_agenda_entries as agenda
        where agenda.cartorio_vitor_document_uploaded_by = auth.uid()
          and coalesce(agenda.cartorio_vitor_document_paths, '[]'::jsonb) ? storage.objects.name
      )
    )
  )
);

-- Mantém a remoção auditável já existente, ampliando-a somente ao dono do arquivo.
do $$
declare
  definition text;
begin
  select pg_get_functiondef(
    'public.delete_agenda_attachment(uuid,text,text)'::regprocedure
  ) into definition;

  if position('if not public.is_allyson_admin() then' in definition) = 0 then
    raise exception 'Formato inesperado de delete_agenda_attachment.';
  end if;

  definition := replace(
    definition,
    'if not public.is_allyson_admin() then',
    $guard$if not public.is_allyson_admin()
      and not (
        p_bucket = 'agenda-protocols'
        and exists (
          select 1 from public.profiles as owner_profile
          where owner_profile.id = auth.uid()
            and lower(trim(owner_profile.email)) = 'unassigned-agenda@example.invalid'
        )
      )
      and not (
        p_bucket = 'agenda-vitor-documents'
        and exists (
          select 1 from public.crm_agenda_entries as owner_entry
          where owner_entry.id = p_id
            and owner_entry.cartorio_vitor_document_uploaded_by = auth.uid()
            and coalesce(owner_entry.cartorio_vitor_document_paths, '[]'::jsonb) ? p_path
        )
      ) then$guard$
  );
  definition := replace(
    definition,
    'Somente Allyson pode excluir anexos da agenda.',
    'Somente Allyson ou o dono do anexo pode excluí-lo.'
  );
  execute definition;
end;
$$;

revoke all on function public.delete_agenda_attachment(uuid,text,text) from public, anon;
grant execute on function public.delete_agenda_attachment(uuid,text,text) to authenticated;

commit;

-- Documentos do imóvel: todos os usuários autenticados podem anexar e baixar.
insert into storage.buckets (id, name, public)
values ('property-documents', 'property-documents', false)
on conflict (id) do nothing;

create policy "Authenticated users read property documents"
on storage.objects for select to authenticated
using (bucket_id = 'property-documents');

create policy "Authenticated users upload property documents"
on storage.objects for insert to authenticated
with check (bucket_id = 'property-documents');

create policy "Authenticated users update property documents"
on storage.objects for update to authenticated
using (bucket_id = 'property-documents')
with check (bucket_id = 'property-documents');

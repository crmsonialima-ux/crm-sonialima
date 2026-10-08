insert into storage.buckets (id, name, public)
values ('lead-documents', 'lead-documents', false)
on conflict (id) do nothing;

create policy "Authenticated users read lead proposal documents"
on storage.objects for select to authenticated
using (bucket_id = 'lead-documents');

create policy "Authenticated users upload lead proposal documents"
on storage.objects for insert to authenticated
with check (bucket_id = 'lead-documents');

create policy "Authenticated users update lead proposal documents"
on storage.objects for update to authenticated
using (bucket_id = 'lead-documents')
with check (bucket_id = 'lead-documents');

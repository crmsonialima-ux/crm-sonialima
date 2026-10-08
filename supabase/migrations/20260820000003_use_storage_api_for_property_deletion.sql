begin;

-- Supabase blocks direct DML against storage.objects. Files are removed by the
-- client through the Storage API; the database RPC remains responsible only for
-- relational records and is still restricted to Allyson.
do $$
declare
  definition text;
begin
  select pg_get_functiondef('public.delete_property_metadata(text)'::regprocedure)
  into definition;

  definition := regexp_replace(
    definition,
    'delete from storage[.]objects[[:space:]]*where bucket_id = ''property-authorizations''[[:space:]]*and name like normalized_property_id [|][|] ''/%'';',
    '',
    'i'
  );

  execute definition;
end;
$$;

drop policy if exists "property_auth_delete_allyson_all" on storage.objects;
create policy "property_auth_delete_allyson_all"
on storage.objects for delete to authenticated
using (
  bucket_id = 'property-authorizations'
  and exists (
    select 1 from public.profiles
    where id = auth.uid()
      and role = 'admin'
      and lower(trim(email)) = 'crmsoniaallyson@gmail.com'
  )
);

commit;

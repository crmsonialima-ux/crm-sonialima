-- Permite que a Edge Function, autenticada com a service role, sincronize o catálogo 24h por dia.
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(auth.role() = 'service_role', false) or exists (
    select 1 from public.profiles where id = auth.uid() and role = 'admin'
  );
$$;

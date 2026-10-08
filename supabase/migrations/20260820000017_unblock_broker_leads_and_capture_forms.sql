-- Corrige os dois fluxos operacionais dos corretores: conduÃ§Ã£o do lead e ficha de captaÃ§Ã£o.
begin;

create or replace function public.protect_lead_data_from_unauthorized_edits()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if current_user in ('postgres', 'service_role', 'supabase_admin') or public.is_allyson_admin() then
    return new;
  end if;
  if public.is_restricted_admin() then
    raise exception 'A conta acesso CRM possui somente consulta de leads.';
  end if;
  -- A RLS garante que o corretor atua apenas no prÃ³prio lead.
  return new;
end;
$$;

create or replace function public.protect_lead_assignment_system_fields()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if current_user in ('postgres', 'service_role', 'supabase_admin') or public.is_allyson_admin() then
    return new;
  end if;
  if public.is_restricted_admin() then
    raise exception 'A conta acesso CRM possui somente consulta de leads.';
  end if;
  -- O corretor pode conduzir livremente o prÃ³prio lead; a RLS impede alterar a carteira de terceiros.
  return new;
end;
$$;

create or replace function public.can_access_property_authorization(p_property_id text, p_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_role text;
  v_email text;
begin
  select role, email into v_role, v_email from public.profiles where id = p_user_id;

  if v_role = 'admin' and (v_email ilike 'crmsoniaallyson@gmail.com' or v_email ilike 'unassigned-institutional@example.invalid') then
    return true;
  end if;

  if exists (
    select 1 from public.crm_property_authorizations auth_record
    where auth_record.property_id = p_property_id and auth_record.submitted_by = p_user_id
  ) then
    return true;
  end if;

  if exists (
    select 1 from public.crm_property_capturer_assignments assignment
    where assignment.property_id = p_property_id and assignment.broker_id = p_user_id
  ) or exists (
    select 1 from public.crm_property_broker_access access
    where access.property_id = p_property_id and access.broker_id = p_user_id
  ) then
    return true;
  end if;

  return false;
end;
$$;

create policy "Active assigned brokers update property catalog"
  on public.crm_property_catalog for update to authenticated
  using (
    public.is_allyson_admin()
    or (
      not public.is_restricted_admin()
      and lower(trim(coalesce(status, ''))) = 'ativo'
      and exists (
        select 1 from public.crm_property_broker_access access
        where access.property_id = external_id and access.broker_id = auth.uid()
      )
    )
  )
  with check (
    public.is_allyson_admin()
    or (
      not public.is_restricted_admin()
      and lower(trim(coalesce(status, ''))) = 'ativo'
      and exists (
        select 1 from public.crm_property_broker_access access
        where access.property_id = external_id and access.broker_id = auth.uid()
      )
    )
  );

create policy "Active assigned brokers update authorizations"
  on public.crm_property_authorizations for update to authenticated
  using (
    public.is_allyson_admin()
    or exists (
      select 1
      from public.crm_property_catalog property
      where property.external_id = crm_property_authorizations.property_id
        and lower(trim(coalesce(property.status, ''))) = 'ativo'
        and not public.is_restricted_admin()
        and public.can_access_property_authorization(property.external_id, auth.uid())
    )
  )
  with check (
    public.is_allyson_admin()
    or exists (
      select 1
      from public.crm_property_catalog property
      where property.external_id = crm_property_authorizations.property_id
        and lower(trim(coalesce(property.status, ''))) = 'ativo'
        and not public.is_restricted_admin()
        and public.can_access_property_authorization(property.external_id, auth.uid())
    )
  );

drop policy if exists "property_auth_insert_original" on storage.objects;
create policy "property_auth_insert_original"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'property-authorizations'
    and split_part(name, '/', 2) != 'pdfs'
    and (
      public.is_allyson_admin()
      or (
        not public.is_restricted_admin()
        and public.can_access_property_authorization(split_part(name, '/', 1), auth.uid())
        and exists (
          select 1 from public.crm_property_catalog property
          where property.external_id = split_part(name, '/', 1)
            and lower(trim(coalesce(property.status, ''))) = 'ativo'
        )
      )
    )
  );

commit;

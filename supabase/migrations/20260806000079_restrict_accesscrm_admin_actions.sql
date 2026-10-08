-- Mantem o perfil como admin, mas retira operacoes destrutivas e de edicao
-- exclusivamente da conta operacional unassigned-institutional@example.invalid.
create or replace function public.is_restricted_admin()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1
    from public.profiles as profile
    where profile.id = auth.uid()
      and profile.role = 'admin'
      and lower(trim(profile.email)) = 'unassigned-institutional@example.invalid'
  );
$$;

create or replace function public.has_full_admin_access()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select coalesce(auth.role() = 'service_role', false)
    or exists (
      select 1
      from public.profiles as profile
      where profile.id = auth.uid()
        and profile.role = 'admin'
        and lower(trim(profile.email)) <> 'unassigned-institutional@example.invalid'
    );
$$;

revoke all on function public.is_restricted_admin() from public, anon;
revoke all on function public.has_full_admin_access() from public, anon;
grant execute on function public.is_restricted_admin() to authenticated, service_role;
grant execute on function public.has_full_admin_access() to authenticated, service_role;

drop policy if exists "Admins update every lead; brokers update their own without reassigning"
  on public.crm_leads;
create policy "Full admins update every lead; brokers update their own without reassigning"
  on public.crm_leads
  for update
  using (
    public.has_full_admin_access()
    or (not public.is_admin() and owner_id = auth.uid())
  )
  with check (
    public.has_full_admin_access()
    or (not public.is_admin() and owner_id = auth.uid())
  );

drop policy if exists "Only admins can delete leads" on public.crm_leads;
create policy "Only full admins can delete leads"
  on public.crm_leads
  for delete
  using (public.has_full_admin_access());

create or replace function public.delete_crm_lead(p_lead_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  previous_owner_id uuid;
begin
  if not public.has_full_admin_access() then
    raise exception 'Seu acesso administrativo nao permite excluir leads.';
  end if;

  select owner_id
  into previous_owner_id
  from public.crm_leads
  where id = p_lead_id
  for update;

  if previous_owner_id is null then
    raise exception 'Lead nao encontrado.';
  end if;

  delete from public.crm_notification_outbox
  where payload ->> 'leadId' = p_lead_id::text;

  delete from public.crm_leads
  where id = p_lead_id;

  perform public.refresh_broker_visit_block(previous_owner_id);
end;
$$;

create or replace function public.set_portal_lead_integration_enabled(
  p_provider text,
  p_enabled boolean
)
returns public.crm_portal_lead_integrations
language plpgsql
security definer
set search_path = public
as $$
declare
  result public.crm_portal_lead_integrations;
begin
  if not public.has_full_admin_access() then
    raise exception 'Seu acesso administrativo nao permite alterar integracoes de leads.';
  end if;

  if p_provider not in ('wimoveis_vrsync', 'dfimoveis_vrsync', 'whatsapp_business') then
    raise exception 'Integracao nao reconhecida.';
  end if;

  insert into public.crm_portal_lead_integrations(provider, enabled, updated_at, updated_by)
  values (p_provider, p_enabled, now(), auth.uid())
  on conflict (provider) do update
    set enabled = excluded.enabled,
        updated_at = excluded.updated_at,
        updated_by = excluded.updated_by
  returning * into result;

  return result;
end;
$$;

create or replace function public.delete_agenda_entry(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.has_full_admin_access() then
    delete from public.crm_agenda_entries where id = p_id;
    return;
  end if;

  if public.is_restricted_admin() then
    delete from public.crm_agenda_entries
    where id = p_id
      and created_by = auth.uid();
    if not found then
      raise exception 'Seu acesso permite excluir apenas demandas criadas por voce.';
    end if;
    return;
  end if;

  raise exception 'Somente administradores podem excluir demandas da agenda.';
end;
$$;

create or replace function public.prevent_restricted_admin_broker_removal()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.is_restricted_admin() then
    raise exception 'Seu acesso administrativo nao permite remover corretores.';
  end if;
  return null;
end;
$$;

drop trigger if exists lead_distribution_queue_restrict_accesscrm_delete
  on public.lead_distribution_queue;
create trigger lead_distribution_queue_restrict_accesscrm_delete
before delete on public.lead_distribution_queue
for each statement
execute function public.prevent_restricted_admin_broker_removal();

revoke all on function public.prevent_restricted_admin_broker_removal()
  from public, anon, authenticated;

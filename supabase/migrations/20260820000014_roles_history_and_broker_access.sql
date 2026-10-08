-- Regras operacionais: Allyson administra, acessocrm consulta e corretores
-- operam somente os próprios leads e a ficha de captação de imóveis ativos.
begin;

-- Acesso CRM não pode alterar ou excluir leads; corretores movem livremente os próprios leads.
drop policy if exists "Allyson and access CRM edit all leads; brokers update their own" on public.crm_leads;
drop policy if exists "Full admins update every lead; brokers update their own without reassigning" on public.crm_leads;
create policy "Allyson updates leads; brokers update their own"
  on public.crm_leads for update to authenticated
  using (
    public.is_allyson_admin()
    or (not public.is_admin() and owner_id = auth.uid())
  )
  with check (
    public.is_allyson_admin()
    or (not public.is_admin() and owner_id = auth.uid())
  );

drop policy if exists "Only Allyson and access CRM delete leads" on public.crm_leads;
drop policy if exists "Only full admins can delete leads" on public.crm_leads;
create policy "Only Allyson deletes leads"
  on public.crm_leads for delete to authenticated
  using (public.is_allyson_admin());

create or replace function public.protect_lead_data_from_unauthorized_edits()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  trusted_backend boolean := current_user in ('postgres', 'service_role', 'supabase_admin');
  old_protected jsonb;
  new_protected jsonb;
begin
  if trusted_backend or public.is_allyson_admin() then return new; end if;
  if public.is_restricted_admin() then
    raise exception 'A conta acesso CRM possui somente consulta de leads.';
  end if;

  -- Corretor pode conduzir a etapa e seus campos operacionais, mas não pode
  -- mudar cadastro, responsável ou dados administrativos do lead.
  old_protected := to_jsonb(old)
    - 'stage' - 'updated_at' - 'assignment_deadline_at'
    - 'visit_scheduled_at' - 'visit_completed_at' - 'visit_feedback_at'
    - 'visit_started_notified_at' - 'visit_follow_up_notified_at'
    - 'visit_feedback_reminder_sent_at' - 'proposal_at'
    - 'visit_executor_id' - 'visit_executor_ids'
    - 'has_property_to_sell' - 'property_to_sell_location' - 'property_to_sell_value'
    - 'needs_financing' - 'will_use_fgts' - 'banking_correspondent_presented'
    - 'visit_property_captured' - 'visit_companion_id';
  new_protected := to_jsonb(new)
    - 'stage' - 'updated_at' - 'assignment_deadline_at'
    - 'visit_scheduled_at' - 'visit_completed_at' - 'visit_feedback_at'
    - 'visit_started_notified_at' - 'visit_follow_up_notified_at'
    - 'visit_feedback_reminder_sent_at' - 'proposal_at'
    - 'visit_executor_id' - 'visit_executor_ids'
    - 'has_property_to_sell' - 'property_to_sell_location' - 'property_to_sell_value'
    - 'needs_financing' - 'will_use_fgts' - 'banking_correspondent_presented'
    - 'visit_property_captured' - 'visit_companion_id';
  if new_protected is distinct from old_protected then
    raise exception 'Corretor pode alterar somente a condução do próprio lead.';
  end if;
  return new;
end;
$$;

-- Etapas permanecem livres e os marcos históricos não são apagados ao mudar de coluna.
create or replace function public.enforce_lead_commercial_qualification()
returns trigger language plpgsql set search_path = pg_catalog, public as $$
begin
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

  -- A etapa do prÃ³prio lead Ã© livre para o corretor. Os controles de distribuiÃ§Ã£o
  -- permanecem sob responsabilidade do CRM, exceto o prazo derivado da etapa.
  if new.assignment_status is distinct from old.assignment_status
     or new.assignment_available_at is distinct from old.assignment_available_at
     or new.assignment_run_number is distinct from old.assignment_run_number
     or new.assignment_reminder_sent_at is distinct from old.assignment_reminder_sent_at then
    raise exception 'Os controles da esteira sÃ³ podem ser alterados pelo CRM.';
  end if;
  return new;
end;
$$;

create or replace function public.guard_expired_lead_qualification()
returns trigger language plpgsql set search_path = pg_catalog, public as $$
begin
  return new;
end;
$$;

create or replace function public.enforce_reliable_lead_visit_lifecycle()
returns trigger language plpgsql set search_path = pg_catalog, public as $$
declare normalized_stage text := lower(trim(coalesce(new.stage, '')));
begin
  if normalized_stage = 'visita realizada' then
    new.visit_completed_at := coalesce(old.visit_completed_at, new.visit_completed_at, now());
  end if;
  if normalized_stage = 'proposta' then
    new.proposal_at := coalesce(old.proposal_at, new.proposal_at, now());
  end if;
  -- Nunca limpa visita realizada ou proposta por uma troca posterior de etapa.
  new.visit_completed_at := coalesce(new.visit_completed_at, old.visit_completed_at);
  new.proposal_at := coalesce(new.proposal_at, old.proposal_at);
  return new;
end;
$$;

-- Preenchimento diário é operação exclusiva da Allyson.
drop policy if exists "Admins insert daily broker revenue" on public.crm_daily_broker_revenue;
drop policy if exists "Admins delete daily broker revenue" on public.crm_daily_broker_revenue;
drop policy if exists "Allyson updates daily broker revenue" on public.crm_daily_broker_revenue;
create policy "Only Allyson inserts daily broker revenue"
  on public.crm_daily_broker_revenue for insert to authenticated
  with check (public.is_allyson_admin() and created_by = auth.uid());
create policy "Only Allyson updates daily broker revenue"
  on public.crm_daily_broker_revenue for update to authenticated
  using (public.is_allyson_admin()) with check (public.is_allyson_admin());
create policy "Only Allyson deletes daily broker revenue"
  on public.crm_daily_broker_revenue for delete to authenticated
  using (public.is_allyson_admin());

-- Corretores editam somente imóveis Ativos dos quais são captadores.
drop policy if exists "Allyson can update all properties" on public.crm_property_catalog;
create policy "Allyson or active property capturer updates catalog"
  on public.crm_property_catalog for update to authenticated
  using (
    public.is_allyson_admin()
    or (
      lower(trim(coalesce(status, ''))) = 'ativo'
      and exists (
        select 1 from public.crm_property_capturer_assignments assignment
        where assignment.property_id = external_id and assignment.broker_id = auth.uid()
      )
    )
  )
  with check (
    public.is_allyson_admin()
    or (
      lower(trim(coalesce(status, ''))) = 'ativo'
      and exists (
        select 1 from public.crm_property_capturer_assignments assignment
        where assignment.property_id = external_id and assignment.broker_id = auth.uid()
      )
    )
  );

create or replace function public.protect_broker_property_catalog_update()
returns trigger language plpgsql set search_path = pg_catalog, public as $$
declare old_protected jsonb; new_protected jsonb;
begin
  if current_user in ('postgres', 'service_role', 'supabase_admin') or public.is_allyson_admin() then
    return new;
  end if;
  if public.is_restricted_admin() then
    raise exception 'A conta acesso CRM não pode editar imóveis.';
  end if;
  old_protected := to_jsonb(old)
    - 'title' - 'address' - 'neighborhood' - 'city' - 'property_type'
    - 'purpose' - 'value' - 'owner_name' - 'has_photos' - 'updated_at';
  new_protected := to_jsonb(new)
    - 'title' - 'address' - 'neighborhood' - 'city' - 'property_type'
    - 'purpose' - 'value' - 'owner_name' - 'has_photos' - 'updated_at';
  if old_protected is distinct from new_protected then
    raise exception 'Corretor pode alterar somente a ficha de captação.';
  end if;
  return new;
end;
$$;

drop trigger if exists zzz_protect_broker_property_catalog_update on public.crm_property_catalog;
create trigger zzz_protect_broker_property_catalog_update
before update on public.crm_property_catalog
for each row execute function public.protect_broker_property_catalog_update();

-- A ficha de captaÃ§Ã£o pode ser preenchida pelo corretor captador em imÃ³vel ativo;
-- Allyson continua com acesso a todas as fichas e acessocrm permanece somente leitura.
drop policy if exists "Apenas Allyson pode editar autorizaÃ§Ãµes" on public.crm_property_authorizations;
create policy "Allyson or active property capturer updates authorizations"
  on public.crm_property_authorizations for update to authenticated
  using (
    public.is_allyson_admin()
    or exists (
      select 1
      from public.crm_property_catalog property
      join public.crm_property_capturer_assignments assignment
        on assignment.property_id = property.external_id
      where property.external_id = crm_property_authorizations.property_id
        and assignment.broker_id = auth.uid()
        and lower(trim(coalesce(property.status, ''))) = 'ativo'
    )
  )
  with check (
    public.is_allyson_admin()
    or exists (
      select 1
      from public.crm_property_catalog property
      join public.crm_property_capturer_assignments assignment
        on assignment.property_id = property.external_id
      where property.external_id = crm_property_authorizations.property_id
        and assignment.broker_id = auth.uid()
        and lower(trim(coalesce(property.status, ''))) = 'ativo'
    )
  );

commit;

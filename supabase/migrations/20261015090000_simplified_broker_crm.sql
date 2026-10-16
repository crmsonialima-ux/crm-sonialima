-- Fluxo comercial simplificado: Allyson administra; os demais usam o CRM como corretores.
create or replace function public.is_allyson_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() = '37094db7-2457-48f2-8573-40c887e547e5'::uuid
    and exists (
      select 1 from public.profiles
      where id = auth.uid() and role = 'admin'
    );
$$;

-- Mantém a compatibilidade das funções e policies existentes, mas só Allyson é administrador.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$ select public.is_allyson_admin(); $$;

update public.profiles
set role = case
  when id = '37094db7-2457-48f2-8573-40c887e547e5'::uuid then 'admin'::public.crm_role
  else 'broker'::public.crm_role
end,
lead_distribution_blocked = false,
lead_distribution_blocked_reason = null,
lead_distribution_blocked_at = null,
lead_distribution_blocked_until = null;

-- Não há mais esteira com aceite, prazo, bloqueio ou qualificação obrigatória.
drop trigger if exists crm_leads_enforce_attendance_deadline on public.crm_leads;
drop trigger if exists crm_leads_enforce_pending_qualification_stage_lock on public.crm_leads;

create or replace function public.enforce_simplified_lead_flow()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.assignment_status := 'accepted';
  new.assignment_available_at := null;
  new.assignment_deadline_at := null;
  new.assignment_reminder_sent_at := null;
  new.commercial_qualification_required := false;
  new.post_acceptance_qualification_deadline_at := null;
  new.post_acceptance_qualification_completed_at := null;
  new.post_acceptance_qualification_expired_at := null;
  new.post_acceptance_call_made := null;
  new.post_acceptance_call_result := null;
  new.post_acceptance_interaction := null;
  new.post_acceptance_whatsapp_contacted := null;
  new.post_acceptance_whatsapp_print_path := null;
  new.post_acceptance_whatsapp_has_whatsapp := null;
  return new;
end;
$$;

drop trigger if exists crm_leads_enforce_simplified_flow on public.crm_leads;
create trigger crm_leads_enforce_simplified_flow
before insert or update on public.crm_leads
for each row execute procedure public.enforce_simplified_lead_flow();

update public.crm_leads
set assignment_status = 'accepted',
    assignment_available_at = null,
    assignment_deadline_at = null,
    assignment_reminder_sent_at = null,
    commercial_qualification_required = false,
    post_acceptance_qualification_deadline_at = null,
    post_acceptance_qualification_completed_at = null,
    post_acceptance_qualification_expired_at = null,
    post_acceptance_call_made = null,
    post_acceptance_call_result = null,
    post_acceptance_interaction = null,
    post_acceptance_whatsapp_contacted = null,
    post_acceptance_whatsapp_print_path = null,
    post_acceptance_whatsapp_has_whatsapp = null;

-- O corretor dono de um lead pode alterar somente a etapa. Allyson continua com acesso total.
create or replace function public.enforce_broker_stage_only()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.is_allyson_admin() or auth.role() = 'service_role' then return new; end if;
  if old.owner_id <> auth.uid() then
    raise exception 'Você só pode atualizar os seus próprios leads.';
  end if;
  if (to_jsonb(new) - array['stage', 'updated_at'])
     is distinct from
     (to_jsonb(old) - array['stage', 'updated_at']) then
    raise exception 'Corretores podem alterar somente a etapa do próprio lead.';
  end if;
  return new;
end;
$$;

drop trigger if exists crm_leads_enforce_broker_stage_only on public.crm_leads;
create trigger crm_leads_enforce_broker_stage_only
before update on public.crm_leads
for each row execute procedure public.enforce_broker_stage_only();

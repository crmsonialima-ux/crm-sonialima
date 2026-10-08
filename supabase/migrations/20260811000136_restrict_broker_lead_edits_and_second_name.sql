begin;

alter table public.crm_leads
  add column if not exists secondary_name text;

comment on column public.crm_leads.secondary_name is
  'Segundo nome opcional, acrescentado sem substituir o nome original do lead.';

create or replace function public.protect_lead_data_from_unauthorized_edits()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  trusted_backend boolean := current_user in (
    'postgres',
    'service_role',
    'supabase_admin'
  );
  full_editor boolean;
  old_protected jsonb;
  new_protected jsonb;
begin
  if trusted_backend then
    return new;
  end if;

  full_editor := public.is_allyson_admin() or public.is_restricted_admin();
  if full_editor then
    return new;
  end if;

  -- O corretor pode registrar somente a etapa e os campos operacionais
  -- derivados dessa troca. Dados cadastrais, observacoes e responsavel
  -- permanecem protegidos mesmo contra uma chamada direta ao banco.
  old_protected := to_jsonb(old)
    - 'stage'
    - 'updated_at'
    - 'assignment_deadline_at'
    - 'visit_scheduled_at'
    - 'visit_completed_at'
    - 'visit_feedback_at'
    - 'visit_started_notified_at'
    - 'visit_follow_up_notified_at'
    - 'visit_feedback_reminder_sent_at'
    - 'proposal_at';
  new_protected := to_jsonb(new)
    - 'stage'
    - 'updated_at'
    - 'assignment_deadline_at'
    - 'visit_scheduled_at'
    - 'visit_completed_at'
    - 'visit_feedback_at'
    - 'visit_started_notified_at'
    - 'visit_follow_up_notified_at'
    - 'visit_feedback_reminder_sent_at'
    - 'proposal_at';

  if new_protected is distinct from old_protected then
    raise exception 'Corretores podem alterar somente a etapa do lead. Solicite ao Allyson ou ao acesso CRM qualquer alteracao cadastral.';
  end if;

  return new;
end;
$$;

revoke all on function public.protect_lead_data_from_unauthorized_edits()
  from public, anon, authenticated;

drop trigger if exists zzy_crm_leads_protect_registered_data
  on public.crm_leads;
create trigger zzy_crm_leads_protect_registered_data
before update on public.crm_leads
for each row execute function public.protect_lead_data_from_unauthorized_edits();

commit;

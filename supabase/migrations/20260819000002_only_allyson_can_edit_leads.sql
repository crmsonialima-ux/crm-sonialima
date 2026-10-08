begin;

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

  -- Somente Allyson pode alterar TODOS OS DADOS do lead.
  full_editor := public.is_allyson_admin();
  if full_editor then
    return new;
  end if;

  -- Qualquer outro usuario (corretores, acesso CRM, etc) so pode registrar a etapa e os campos operacionais
  -- derivados dessa troca. Dados cadastrais, observacoes e responsavel permanecem protegidos.
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
    raise exception 'Somente o Allyson pode alterar os dados cadastrais do lead.';
  end if;

  return new;
end;
$$;

commit;

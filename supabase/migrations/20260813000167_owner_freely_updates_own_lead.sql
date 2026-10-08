begin;

-- A RLS ja limita o corretor aos leads dos quais ele e proprietario. Este
-- gatilho nao deve exigir permissao administrativa quando o proprio corretor
-- progride seu lead; qualificacao e campos tecnicos da esteira continuam
-- protegidos por seus gatilhos especificos.
create or replace function public.protect_lead_data_from_unauthorized_edits()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  trusted_backend boolean := current_user in ('postgres', 'service_role', 'supabase_admin');
  full_editor boolean;
  owner_editor boolean := auth.uid() is not null and old.owner_id = auth.uid();
  old_protected jsonb;
  new_protected jsonb;
begin
  if trusted_backend then return new; end if;

  full_editor := public.is_allyson_admin() or public.is_restricted_admin();
  if full_editor or owner_editor then return new; end if;

  old_protected := to_jsonb(old)
    - 'stage' - 'updated_at' - 'assignment_deadline_at'
    - 'visit_scheduled_at' - 'visit_completed_at' - 'visit_feedback_at'
    - 'visit_started_notified_at' - 'visit_follow_up_notified_at'
    - 'visit_feedback_reminder_sent_at' - 'proposal_at'
    - 'has_property_to_sell' - 'property_to_sell_location'
    - 'property_to_sell_value' - 'needs_financing' - 'will_use_fgts'
    - 'banking_correspondent_presented' - 'visit_property_captured';
  new_protected := to_jsonb(new)
    - 'stage' - 'updated_at' - 'assignment_deadline_at'
    - 'visit_scheduled_at' - 'visit_completed_at' - 'visit_feedback_at'
    - 'visit_started_notified_at' - 'visit_follow_up_notified_at'
    - 'visit_feedback_reminder_sent_at' - 'proposal_at'
    - 'has_property_to_sell' - 'property_to_sell_location'
    - 'property_to_sell_value' - 'needs_financing' - 'will_use_fgts'
    - 'banking_correspondent_presented' - 'visit_property_captured';

  if new_protected is distinct from old_protected then
    raise exception 'Somente o corretor responsavel ou um administrador pode alterar este lead.';
  end if;
  return new;
end;
$$;

revoke all on function public.protect_lead_data_from_unauthorized_edits()
  from public, anon, authenticated;

comment on function public.protect_lead_data_from_unauthorized_edits() is
  'Permite ao corretor proprietario atualizar livremente seu lead; RLS, qualificacao e controles da esteira permanecem independentes.';

commit;

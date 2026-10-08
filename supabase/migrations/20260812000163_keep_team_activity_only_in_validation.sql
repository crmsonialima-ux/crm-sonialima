begin;

-- Alterações realizadas por outros usuários pertencem à auditoria exclusiva da
-- Validação. Elas não são notificações pessoais do Allyson e, portanto, não
-- devem aparecer no sininho, tocar áudio nem gerar push no aparelho dele.
do $$
declare
  table_name text;
  tracked_tables constant text[] := array[
    'crm_leads',
    'crm_lead_activities',
    'crm_property_catalog',
    'crm_property_public_links',
    'crm_property_reviewability',
    'crm_property_value_reviews',
    'crm_property_document_responsibilities',
    'crm_property_document_clearance_status',
    'crm_agenda_entries',
    'crm_marketing_campaigns',
    'crm_daily_broker_revenue',
    'crm_portal_lead_integrations',
    'crm_assignment_test_runs',
    'crm_assignment_test_attempts',
    'profiles'
  ];
begin
  foreach table_name in array tracked_tables loop
    if to_regclass('public.' || table_name) is null then
      continue;
    end if;
    execute format(
      'drop trigger if exists notify_allyson_user_action on public.%I',
      table_name
    );
    execute format(
      'drop trigger if exists zz_enrich_allyson_user_action on public.%I',
      table_name
    );
  end loop;
end;
$$;

drop trigger if exists notify_allyson_crm_file_action on storage.objects;

-- Limpa apenas os avisos artificiais da caixa pessoal. Os eventos de criação,
-- leitura e remoção permanecem em crm_audit_events, e todas as ações continuam
-- registradas em crm_user_action_history para a aba Validação.
delete from public.crm_notification_outbox as notification
where notification.kind = 'allyson_user_activity';

commit;

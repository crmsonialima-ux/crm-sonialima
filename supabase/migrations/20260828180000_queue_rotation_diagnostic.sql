begin;

-- Diagnostico agregado e sem dados de contato dos clientes. Mantido no
-- historico para documentar o estado usado na investigacao da esteira.
do $$
declare queue_state jsonb; recent_state jsonb;
begin
  select jsonb_agg(jsonb_build_object(
    'broker', coalesce(nullif(profile.full_name, ''), profile.email),
    'email', profile.email,
    'position', queue.position,
    'blocked', coalesce(profile.lead_distribution_blocked, false),
    'manual', coalesce(profile.lead_distribution_manually_disabled, false),
    'blocked_until', profile.lead_distribution_blocked_until
  ) order by queue.position)
  into queue_state
  from public.lead_distribution_queue queue
  join public.profiles profile on profile.id = queue.broker_id
  where queue.lead_type = 'Venda';

  select jsonb_agg(row_state order by created_at desc)
  into recent_state
  from (
    select lead.created_at, jsonb_build_object(
      'lead_id', lead.id,
      'owner', coalesce(nullif(owner.full_name, ''), owner.email),
      'property_id', lead.property_catalog_id,
      'assignment_status', lead.assignment_status,
      'property_access_count', (
        select count(*) from public.crm_property_broker_access access
        where access.property_id = lead.property_catalog_id
      )
    ) as row_state
    from public.crm_leads lead
    left join public.profiles owner on owner.id = lead.owner_id
    where lead.lead_type = 'Venda'
    order by lead.created_at desc
    limit 5
  ) recent;

  raise warning 'QUEUE_DIAGNOSTIC=%', queue_state;
  raise warning 'RECENT_LEADS_DIAGNOSTIC=%', recent_state;
end;
$$;

commit;

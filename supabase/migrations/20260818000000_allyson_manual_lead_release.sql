create or replace function public.allyson_release_scheduled_lead(p_lead_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_lead public.crm_leads;
  target_deadline timestamptz;
begin
  if not public.is_allyson_admin() then
    raise exception 'Apenas Allyson pode antecipar leads programados.';
  end if;
  
  select * into v_lead from public.crm_leads where id = p_lead_id;
  
  if v_lead is null then
    raise exception 'Lead não encontrado.';
  end if;
  
  if v_lead.assignment_available_at is null or v_lead.assignment_available_at <= now() then
    raise exception 'O lead não está programado para o futuro.';
  end if;

  target_deadline := public.crm_add_lead_queue_minutes(now(), 20);

  update public.crm_leads
  set assignment_available_at = now(),
      assignment_deadline_at = target_deadline
  where id = p_lead_id;

  insert into public.lead_activity_history (lead_id, actor_id, stage, note)
  values (
    p_lead_id,
    auth.uid(),
    v_lead.stage,
    'Liberou antecipadamente a distribuição do lead programado.'
  );

  update public.lead_assignment_attempts
  set notified_at = now(),
      deadline_at = target_deadline
  where lead_id = p_lead_id and attempt_number = 1 and run_number = 1;

  update public.crm_notification_outbox
  set available_at = now(),
      payload = jsonb_set(
        jsonb_set(coalesce(payload, '{}'::jsonb), '{availableAt}', to_jsonb(now()::timestamptz)),
        '{deadlineAt}', to_jsonb(target_deadline)
      )
  where kind = 'lead_assignment' 
    and payload->>'leadId' = p_lead_id::text 
    and payload->>'attemptNumber' = '1';
end;
$$;

revoke all on function public.allyson_release_scheduled_lead(uuid) from public, anon, authenticated;
grant execute on function public.allyson_release_scheduled_lead(uuid) to authenticated;

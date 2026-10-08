create or replace function public.restart_exhausted_lead_queue(p_lead_id uuid)
returns text language plpgsql security definer set search_path=pg_catalog,public as $$
declare lead_record public.crm_leads%rowtype; next_broker record; next_position integer;
  available_at timestamptz:=public.crm_next_lead_queue_moment(now());
  deadline_at timestamptz:=public.crm_add_lead_queue_minutes(now(),15);
begin
  if not public.is_allyson_admin() then
    raise exception 'Somente Allyson pode girar novamente um lead na esteira.';
  end if;
  select * into lead_record from public.crm_leads where id=p_lead_id for update;
  if not found then raise exception 'Lead nao encontrado.'; end if;
  if lead_record.assignment_status is distinct from 'exhausted' then
    raise exception 'Este lead nao esta com a esteira esgotada.';
  end if;
  perform pg_advisory_xact_lock(hashtext('lead-distribution:'||lead_record.lead_type));
  select queue.broker_id,profile.full_name,profile.email into next_broker
  from public.lead_distribution_queue queue join public.profiles profile on profile.id=queue.broker_id
  where queue.lead_type=lead_record.lead_type and profile.role='broker'
    and not coalesce(profile.lead_distribution_blocked,false)
    and (lead_record.source_portal is null or (lead_record.property_catalog_id is not null and exists(
      select 1 from public.crm_property_broker_access access
      where access.property_id=lead_record.property_catalog_id and access.broker_id=queue.broker_id)))
  order by queue.position limit 1 for update of queue skip locked;
  if next_broker.broker_id is null then
    raise exception 'Nao ha corretor elegivel na fila deste lead.';
  end if;
  select coalesce(max(queue.position),0)+1 into next_position
  from public.lead_distribution_queue queue where queue.lead_type=lead_record.lead_type;
  update public.lead_distribution_queue set position=next_position,updated_at=now()
  where lead_type=lead_record.lead_type and broker_id=next_broker.broker_id;
  delete from public.lead_assignment_attempts where lead_id=lead_record.id;
  update public.crm_leads set owner_id=next_broker.broker_id,assignment_status='pending',
    assignment_deadline_at=deadline_at,assignment_reminder_sent_at=null,
    stage='Aguardando atendimento',updated_at=now() where id=lead_record.id;
  insert into public.lead_assignment_attempts(lead_id,broker_id,attempt_number,notified_at,deadline_at)
  values(lead_record.id,next_broker.broker_id,1,available_at,deadline_at);
  insert into public.crm_notification_outbox(recipient_id,kind,title,body,url,payload,available_at)
  values(next_broker.broker_id,'lead_assignment','Lead reiniciado na esteira',
    'Voce tem 15 minutos uteis para iniciar o atendimento de '||lead_record.name||'.','/leads',
    jsonb_build_object('leadId',lead_record.id,'phone',lead_record.phone,'name',lead_record.name,
      'availableAt',available_at,'deadlineAt',deadline_at,'restartedByAllyson',true),available_at);
  insert into public.crm_lead_activities(lead_id,stage,note,author_id,author_name)
  values(lead_record.id,'Esteira reiniciada','Allyson enviou novamente o lead para o corretor da vez.',
    auth.uid(),'crmallyson');
  return coalesce(nullif(next_broker.full_name,''),next_broker.email);
end; $$;

revoke all on function public.restart_exhausted_lead_queue(uuid) from public,anon;
grant execute on function public.restart_exhausted_lead_queue(uuid) to authenticated;

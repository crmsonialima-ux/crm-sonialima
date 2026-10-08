begin;

create or replace function public.crm_add_commercial_minutes(p_start timestamptz, p_minutes integer)
returns timestamptz language plpgsql stable set search_path=pg_catalog,public as $$
declare local_cursor timestamp; remaining integer:=greatest(coalesce(p_minutes,0),0); available integer;
begin
  local_cursor:=p_start at time zone 'America/Sao_Paulo';
  loop
    if extract(isodow from local_cursor)::int>5 then
      local_cursor:=local_cursor::date+(8-extract(isodow from local_cursor)::int)+time '09:00';
    elsif local_cursor::time<time '09:00' then local_cursor:=local_cursor::date+time '09:00';
    elsif local_cursor::time>=time '18:00' then
      local_cursor:=local_cursor::date+interval '1 day'+time '09:00'; continue;
    end if;
    exit when remaining=0;
    available:=floor(extract(epoch from ((local_cursor::date+time '18:00')-local_cursor))/60)::int;
    if remaining<=available then local_cursor:=local_cursor+make_interval(mins=>remaining); remaining:=0;
    else remaining:=remaining-available; local_cursor:=local_cursor::date+interval '1 day'+time '09:00'; end if;
  end loop;
  return local_cursor at time zone 'America/Sao_Paulo';
end $$;

alter table public.crm_property_match_notifications
  add column if not exists expires_at timestamptz,
  add column if not exists offer_started_at timestamptz,
  add column if not exists expired_at timestamptz,
  add column if not exists morning_reminder_on date,
  add column if not exists afternoon_reminder_on date;
update public.crm_property_match_notifications set expires_at=public.crm_add_weekday_hours(created_at,48) where expires_at is null;
alter table public.crm_property_match_notifications alter column expires_at set default public.crm_add_weekday_hours(now(),48);

create or replace function public.start_similar_property_offer(p_lead_id uuid,p_property_id text)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare match_row public.crm_property_match_notifications; property_row public.crm_property_catalog; lead_row public.crm_leads; actor text;
begin
  select * into match_row from public.crm_property_match_notifications where lead_id=p_lead_id and property_external_id=p_property_id for update;
  if not found then raise exception 'Esta oportunidade nao esta mais disponivel.'; end if;
  select * into lead_row from public.crm_leads where id=p_lead_id for update;
  if lead_row.owner_id<>auth.uid() and not public.is_allyson_admin() and not public.is_restricted_admin() then raise exception 'Somente o corretor responsavel pode iniciar esta oferta.'; end if;
  if lead_row.owner_id=auth.uid() and lead_row.assignment_status<>'accepted' then raise exception 'Aceite o lead antes de iniciar uma nova oferta.'; end if;
  select * into property_row from public.crm_property_catalog where external_id=p_property_id;
  if not found then raise exception 'O imovel sugerido nao foi encontrado.'; end if;
  update public.crm_property_match_notifications set offer_started_at=now() where lead_id=p_lead_id and property_external_id=p_property_id;
  update public.crm_leads set property_catalog_id=p_property_id,property_interest=property_row.title,stage='Em atendimento',assignment_status='accepted',assignment_available_at=null,assignment_deadline_at=public.crm_add_commercial_minutes(now(),1440),assignment_reminder_sent_at=null,updated_at=now() where id=p_lead_id;
  select coalesce(nullif(trim(full_name),''),email,'Usuario') into actor from public.profiles where id=auth.uid();
  insert into public.crm_lead_activities(lead_id,stage,note,author_id,author_name) values(p_lead_id,'Nova oferta iniciada','Imovel selecionado: '||property_row.title||'.',auth.uid(),actor);
end $$;
revoke all on function public.start_similar_property_offer(uuid,text) from public,anon;
grant execute on function public.start_similar_property_offer(uuid,text) to authenticated;

create or replace function public.crm_restart_match_lead_queue(p_lead_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare lead_row public.crm_leads; broker_id uuid; pos integer; run_no integer; available timestamptz; deadline timestamptz;
begin
  select * into lead_row from public.crm_leads where id=p_lead_id for update;
  perform pg_advisory_xact_lock(hashtext('lead-distribution:'||lead_row.lead_type));
  select q.broker_id into broker_id from public.lead_distribution_queue q join public.profiles p on p.id=q.broker_id
  where q.lead_type=lead_row.lead_type
    and (
      p.role='broker'
      or (q.lead_type='Venda' and lower(trim(p.email))='unassigned-institutional@example.invalid')
    )
    and not coalesce(p.lead_distribution_blocked,false)
    and (
      not exists(select 1 from public.crm_property_match_notifications m where m.lead_id=lead_row.id)
      or exists(
        select 1
        from public.crm_property_match_notifications m
        join public.crm_property_broker_access a
          on a.property_id=m.property_external_id
         and a.broker_id=q.broker_id
        where m.lead_id=lead_row.id
      )
    )
  order by q.position limit 1 for update of q skip locked;
  if broker_id is null then update public.crm_leads set assignment_status='exhausted',assignment_deadline_at=null where id=p_lead_id; return; end if;
  select coalesce(max(position),0)+1 into pos from public.lead_distribution_queue where lead_type=lead_row.lead_type;
  update public.lead_distribution_queue set position=pos,updated_at=now() where lead_type=lead_row.lead_type and lead_distribution_queue.broker_id=broker_id;
  run_no:=greatest(coalesce(lead_row.assignment_run_number,1),1)+1; available:=public.crm_next_lead_queue_moment(now()); deadline:=public.crm_add_lead_queue_minutes(available,20);
  update public.crm_leads set owner_id=broker_id,stage='Aguardando atendimento',assignment_status='pending',assignment_available_at=available,assignment_deadline_at=deadline,assignment_run_number=run_no,assignment_reminder_sent_at=null,updated_at=now() where id=p_lead_id;
  insert into public.lead_assignment_attempts(lead_id,broker_id,attempt_number,run_number,round_number,notified_at,deadline_at) values(p_lead_id,broker_id,1,run_no,1,available,deadline);
  insert into public.crm_notification_outbox(recipient_id,kind,title,body,url,payload,available_at) values(broker_id,'lead_assignment','Lead retornou a esteira','O prazo da oferta de imovel similar terminou. O lead voltou para a esteira com os imoveis sugeridos anexados.','/leads?focusLeadId='||p_lead_id,jsonb_build_object('leadId',p_lead_id,'runNumber',run_no,'roundNumber',1,'availableAt',available,'deadlineAt',deadline,'similarPropertiesAttached',true),available);
end $$;
revoke all on function public.crm_restart_match_lead_queue(uuid) from public,anon,authenticated;

create or replace function public.process_property_match_opportunities()
returns integer language plpgsql security definer set search_path=pg_catalog,public as $$
declare item record; local_now timestamp:=now() at time zone 'America/Sao_Paulo'; processed integer:=0;
begin
  for item in
    select
      m.lead_id,
      l.owner_id,
      l.name,
      min(m.expires_at) as expires_at,
      count(*)::integer as match_count,
      coalesce(bool_or(m.morning_reminder_on=local_now::date),false) as morning_sent,
      coalesce(bool_or(m.afternoon_reminder_on=local_now::date),false) as afternoon_sent,
      jsonb_agg(m.property_external_id order by m.created_at) as property_ids
    from public.crm_property_match_notifications m
    join public.crm_leads l on l.id=m.lead_id
    where m.offer_started_at is null and m.expired_at is null
    group by m.lead_id,l.owner_id,l.name
  loop
    if item.expires_at<=now() then
      update public.crm_property_match_notifications set expired_at=now() where lead_id=item.lead_id and offer_started_at is null and expired_at is null;
      perform public.crm_restart_match_lead_queue(item.lead_id);
      processed:=processed+1;
    elsif extract(isodow from local_now)::int<=5 and local_now::time>=time '09:00' and local_now::time<time '18:00' and (
      (local_now::time<time '14:00' and not item.morning_sent) or
      (local_now::time>=time '14:00' and not item.afternoon_sent)) then
      insert into public.crm_notification_outbox(recipient_id,kind,title,body,url,payload)
      values(
        item.owner_id,
        'property_match_reminder',
        'Imovel similar aguardando oferta',
        case when item.match_count=1
          then 'Existe 1 imovel similar aguardando uma nova oferta para o lead '||item.name||'.'
          else 'Existem '||item.match_count||' imoveis similares aguardando uma nova oferta para o lead '||item.name||'.'
        end,
        '/leads?focusLeadId='||item.lead_id,
        jsonb_build_object('leadId',item.lead_id,'propertyIds',item.property_ids,'expiresAt',item.expires_at)
      );
      update public.crm_property_match_notifications
      set morning_reminder_on=case when local_now::time<time '14:00' then local_now::date else morning_reminder_on end,
          afternoon_reminder_on=case when local_now::time>=time '14:00' then local_now::date else afternoon_reminder_on end
      where lead_id=item.lead_id and offer_started_at is null and expired_at is null;
      processed:=processed+1;
    end if;
  end loop;
  return processed;
end $$;
revoke all on function public.process_property_match_opportunities() from public,anon,authenticated;
grant execute on function public.process_property_match_opportunities() to service_role;

create or replace function public.enforce_attendance_deadline() returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.stage='Em atendimento' and (tg_op='INSERT' or old.stage is distinct from 'Em atendimento' or new.assignment_status is distinct from 'accepted' or new.assignment_deadline_at is null) then new.assignment_status:='accepted';new.assignment_deadline_at:=public.crm_add_commercial_minutes(now(),1440);end if; return new;
end $$;

update public.crm_leads
set assignment_deadline_at=public.crm_add_commercial_minutes(
  now(),
  least(1440,greatest(0,ceil(extract(epoch from (assignment_deadline_at-now()))/60)::integer))
)
where stage='Em atendimento'
  and assignment_status='accepted'
  and assignment_deadline_at>now();

create or replace function public.extend_lead_attendance(p_lead_id uuid,p_note text) returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare actor text; begin if nullif(trim(p_note),'') is null then raise exception 'Informe o motivo para manter o lead em atendimento.';end if;
update public.crm_leads set assignment_status='accepted',assignment_deadline_at=public.crm_add_commercial_minutes(now(),1440),assignment_reminder_sent_at=null where id=p_lead_id and (owner_id=auth.uid() or public.is_admin()) and stage='Em atendimento';if not found then raise exception 'Este lead nao esta disponivel para renovacao.';end if;
select coalesce(nullif(full_name,''),email) into actor from public.profiles where id=auth.uid();insert into public.crm_lead_activities(lead_id,stage,note,author_id,author_name) values(p_lead_id,'Ainda em atendimento',trim(p_note),auth.uid(),actor);end $$;
revoke all on function public.extend_lead_attendance(uuid,text) from public,anon;grant execute on function public.extend_lead_attendance(uuid,text) to authenticated;

commit;

-- The lead-assignment conveyor operates daily from 08:30 through 18:30 in
-- Brasilia. Other notification categories keep their existing schedule.
create or replace function public.crm_is_lead_queue_hours(p_moment timestamptz default now())
returns boolean language sql stable set search_path=public as $$
  select (p_moment at time zone 'America/Sao_Paulo')::time >= time '08:30'
     and (p_moment at time zone 'America/Sao_Paulo')::time < time '18:30';
$$;

create or replace function public.crm_next_lead_queue_moment(p_moment timestamptz default now())
returns timestamptz language plpgsql stable set search_path=public as $$
declare local_moment timestamp:=p_moment at time zone 'America/Sao_Paulo'; next_local timestamp;
begin
  if local_moment::time < time '08:30' then next_local:=local_moment::date+time '08:30';
  elsif local_moment::time >= time '18:30' then next_local:=(local_moment::date+1)+time '08:30';
  else return p_moment;
  end if;
  return next_local at time zone 'America/Sao_Paulo';
end; $$;

create or replace function public.crm_add_lead_queue_minutes(p_start timestamptz,p_minutes integer)
returns timestamptz language plpgsql stable set search_path=public as $$
declare local_cursor timestamp; local_close timestamp; available_minutes integer;
  remaining_minutes integer:=greatest(coalesce(p_minutes,0),0);
begin
  local_cursor:=public.crm_next_lead_queue_moment(p_start) at time zone 'America/Sao_Paulo';
  while remaining_minutes>0 loop
    local_close:=local_cursor::date+time '18:30';
    available_minutes:=greatest(floor(extract(epoch from(local_close-local_cursor))/60)::integer,0);
    if remaining_minutes<=available_minutes then
      local_cursor:=local_cursor+make_interval(mins=>remaining_minutes); remaining_minutes:=0;
    else
      remaining_minutes:=remaining_minutes-available_minutes;
      local_cursor:=(local_cursor::date+1)+time '08:30';
    end if;
  end loop;
  return local_cursor at time zone 'America/Sao_Paulo';
end; $$;

create or replace function public.normalize_lead_assignment_attempt_schedule()
returns trigger language plpgsql set search_path=public as $$
declare duration_minutes integer:=case when new.attempt_number=1 then 15 else 4 end;
begin
  new.notified_at:=public.crm_next_lead_queue_moment(coalesce(new.notified_at,now()));
  new.deadline_at:=public.crm_add_lead_queue_minutes(now(),duration_minutes);
  return new;
end; $$;

create or replace function public.sync_lead_assignment_deadline_from_attempt()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  update public.crm_leads set assignment_deadline_at=new.deadline_at
  where id=new.lead_id and assignment_status='pending';
  return new;
end; $$;

drop trigger if exists normalize_lead_assignment_attempt_schedule on public.lead_assignment_attempts;
create trigger normalize_lead_assignment_attempt_schedule before insert on public.lead_assignment_attempts
for each row execute function public.normalize_lead_assignment_attempt_schedule();
drop trigger if exists sync_lead_assignment_deadline_from_attempt on public.lead_assignment_attempts;
create trigger sync_lead_assignment_deadline_from_attempt after insert on public.lead_assignment_attempts
for each row execute function public.sync_lead_assignment_deadline_from_attempt();

create or replace function public.normalize_lead_assignment_notification_schedule()
returns trigger language plpgsql set search_path=public as $$
declare lead_deadline timestamptz; linked_lead_id uuid;
begin
  if new.kind is distinct from 'lead_assignment' then return new; end if;
  begin linked_lead_id:=(new.payload->>'leadId')::uuid;
  exception when invalid_text_representation then return new; end;
  select assignment_deadline_at into lead_deadline from public.crm_leads where id=linked_lead_id;
  new.available_at:=public.crm_next_lead_queue_moment(coalesce(new.available_at,now()));
  if lead_deadline is not null then
    new.payload:=jsonb_set(coalesce(new.payload,'{}'::jsonb),'{deadlineAt}',to_jsonb(lead_deadline),true);
    new.payload:=jsonb_set(new.payload,'{availableAt}',to_jsonb(new.available_at),true);
  end if;
  return new;
end; $$;

drop trigger if exists zz_normalize_lead_assignment_notification_schedule
on public.crm_notification_outbox;
create trigger zz_normalize_lead_assignment_notification_schedule
before insert or update of kind,available_at,payload on public.crm_notification_outbox
for each row execute function public.normalize_lead_assignment_notification_schedule();

create or replace function public.start_lead_assignment()
returns trigger language plpgsql security definer set search_path=public as $$
declare assignment_available_at timestamptz:=public.crm_next_lead_queue_moment(now());
  assignment_deadline timestamptz:=public.crm_add_lead_queue_minutes(now(),15);
begin
  update public.crm_leads set assignment_status='pending',assignment_deadline_at=assignment_deadline,
    stage='Aguardando atendimento' where id=new.id;
  insert into public.lead_assignment_attempts(lead_id,broker_id,attempt_number,notified_at,deadline_at)
  values(new.id,new.owner_id,1,assignment_available_at,assignment_deadline);
  insert into public.crm_notification_outbox(recipient_id,kind,title,body,url,payload,available_at)
  values(new.owner_id,'lead_assignment','Novo lead aguardando atendimento',
    'Voce tem 15 minutos uteis para iniciar o atendimento de '||new.name||'.','/leads',
    jsonb_build_object('leadId',new.id,'phone',new.phone,'name',new.name,
      'availableAt',assignment_available_at,'deadlineAt',assignment_deadline),assignment_available_at);
  return new;
end; $$;

create or replace function public.accept_lead_assignment(p_lead_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare current_profile record;
begin
  update public.crm_leads lead set assignment_status='accepted',
    assignment_deadline_at=now()+interval '24 hours',assignment_reminder_sent_at=null,
    stage='Em atendimento'
  where lead.id=p_lead_id and lead.owner_id=auth.uid() and lead.assignment_status='pending'
    and lead.assignment_deadline_at>now() and public.crm_is_lead_queue_hours(now())
    and (lead.source_portal is null or (lead.property_catalog_id is not null and exists(
      select 1 from public.crm_property_broker_access access
      join public.lead_distribution_queue queue on queue.broker_id=access.broker_id
        and queue.lead_type=lead.lead_type
      join public.profiles profile on profile.id=access.broker_id
      where access.property_id=lead.property_catalog_id and access.broker_id=auth.uid()
        and profile.role='broker' and not coalesce(profile.lead_distribution_blocked,false))));
  if not found then raise exception 'Este lead nao esta disponivel para aceite neste horario ou seu prazo/acesso foi alterado.'; end if;
  update public.lead_assignment_attempts attempt set accepted_at=now()
  where attempt.lead_id=p_lead_id and attempt.broker_id=auth.uid()
    and attempt.accepted_at is null and attempt.expired_at is null;
  select profile.full_name,profile.email into current_profile from public.profiles profile where profile.id=auth.uid();
  insert into public.crm_lead_activities(lead_id,stage,note,author_id,author_name)
  values(p_lead_id,'Em atendimento','Atendimento iniciado em '||
    to_char(now() at time zone 'America/Sao_Paulo','DD/MM/YYYY HH24:MI'),auth.uid(),
    coalesce(nullif(current_profile.full_name,''),current_profile.email));
end; $$;

alter function public.process_expired_lead_assignments()
  rename to process_expired_lead_assignments_before_1830;

create or replace function public.process_expired_lead_assignments()
returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.crm_is_lead_queue_hours(now()) then return; end if;
  perform public.process_expired_lead_assignments_before_1830();
end; $$;

revoke all on function public.crm_is_lead_queue_hours(timestamptz) from public,anon;
revoke all on function public.crm_next_lead_queue_moment(timestamptz) from public,anon;
revoke all on function public.crm_add_lead_queue_minutes(timestamptz,integer) from public,anon;
grant execute on function public.crm_is_lead_queue_hours(timestamptz) to authenticated,service_role;
grant execute on function public.crm_next_lead_queue_moment(timestamptz) to authenticated,service_role;
grant execute on function public.crm_add_lead_queue_minutes(timestamptz,integer) to authenticated,service_role;
revoke all on function public.process_expired_lead_assignments_before_1830() from public,anon,authenticated;
revoke all on function public.process_expired_lead_assignments() from public,anon,authenticated;
grant execute on function public.process_expired_lead_assignments() to service_role;
revoke all on function public.accept_lead_assignment(uuid) from public,anon;
grant execute on function public.accept_lead_assignment(uuid) to authenticated;

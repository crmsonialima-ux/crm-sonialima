begin;

alter table public.crm_property_match_notifications
  add column if not exists dismissed_at timestamptz,
  add column if not exists expiry_warning_sent_at timestamptz;

create or replace function public.normalize_direct_assignment_attendance_stage()
returns trigger
language plpgsql
set search_path=pg_catalog,public
as $$
begin
  if old.assignment_status='pending' and new.assignment_status='accepted' then
    if new.created_at>=timestamptz '2026-08-11 00:00:00-03' then
      new.commercial_qualification_required:=true;
    end if;
    if public.crm_normalize_property_match_text(new.stage)='aguardando atendimento' then
      new.stage:='Em atendimento';
      new.assignment_deadline_at:=public.crm_add_commercial_minutes(now(),1440);
      new.assignment_available_at:=null;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists zy_crm_leads_normalize_direct_assignment_stage
  on public.crm_leads;
create trigger zy_crm_leads_normalize_direct_assignment_stage
before update of assignment_status,stage
on public.crm_leads
for each row execute function public.normalize_direct_assignment_attendance_stage();

-- Repara atribuicoes diretas novas que ja foram criadas como aceitas, mas
-- permaneceram incorretamente em Aguardando atendimento.
update public.crm_leads
set stage='Em atendimento',
    commercial_qualification_required=true,
    assignment_deadline_at=public.crm_add_commercial_minutes(now(),1440),
    updated_at=now()
where assignment_status='accepted'
  and public.crm_normalize_property_match_text(stage)='aguardando atendimento'
  and created_at>=timestamptz '2026-08-11 00:00:00-03';

create or replace function public.crm_weekday_minutes_between(
  p_start timestamptz,
  p_end timestamptz
)
returns integer
language plpgsql
stable
set search_path=pg_catalog,public
as $$
declare
  start_local timestamp:=p_start at time zone 'America/Sao_Paulo';
  end_local timestamp:=p_end at time zone 'America/Sao_Paulo';
  cursor_date date;
  interval_start timestamp;
  interval_end timestamp;
  total_seconds numeric:=0;
begin
  if p_start is null or p_end is null or p_end<=p_start then
    return 0;
  end if;

  cursor_date:=start_local::date;
  while cursor_date<=end_local::date loop
    if extract(isodow from cursor_date)::integer<=5 then
      interval_start:=greatest(start_local,cursor_date::timestamp);
      interval_end:=least(end_local,(cursor_date+1)::timestamp);
      if interval_end>interval_start then
        total_seconds:=total_seconds+extract(epoch from (interval_end-interval_start));
      end if;
    end if;
    cursor_date:=cursor_date+1;
  end loop;

  return floor(total_seconds/60)::integer;
end;
$$;

create or replace function public.dismiss_similar_property_matches(p_lead_id uuid)
returns void
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  lead_row public.crm_leads%rowtype;
  actor text;
begin
  select * into lead_row
  from public.crm_leads
  where id=p_lead_id
  for update;

  if not found then
    raise exception 'Lead nao encontrado.';
  end if;
  if lead_row.owner_id<>auth.uid()
    and not public.is_allyson_admin()
    and not public.is_restricted_admin() then
    raise exception 'Somente o corretor responsavel pode encerrar estas sugestoes.';
  end if;

  update public.crm_property_match_notifications
  set dismissed_at=now()
  where lead_id=p_lead_id
    and offer_started_at is null
    and dismissed_at is null;

  if not found then
    raise exception 'Nao existem imoveis similares pendentes para este lead.';
  end if;

  select coalesce(nullif(trim(full_name),''),email,'Usuario')
  into actor
  from public.profiles
  where id=auth.uid();

  insert into public.crm_lead_activities(
    lead_id,stage,note,author_id,author_name
  ) values(
    p_lead_id,
    'Imoveis similares analisados',
    'O corretor informou que os imoveis sugeridos nao atendem ao cliente. O prazo ficou pausado ate uma nova sugestao.',
    auth.uid(),
    actor
  );
end;
$$;

revoke all on function public.dismiss_similar_property_matches(uuid)
  from public,anon;
grant execute on function public.dismiss_similar_property_matches(uuid)
  to authenticated;

create or replace function public.start_similar_property_offer(
  p_lead_id uuid,
  p_property_id text
)
returns void
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  match_row public.crm_property_match_notifications%rowtype;
  property_row public.crm_property_catalog%rowtype;
  lead_row public.crm_leads%rowtype;
  actor text;
begin
  select * into match_row
  from public.crm_property_match_notifications
  where lead_id=p_lead_id
    and property_external_id=p_property_id
    and dismissed_at is null
  for update;

  if not found then
    raise exception 'Esta oportunidade nao esta mais disponivel.';
  end if;

  select * into lead_row
  from public.crm_leads
  where id=p_lead_id
  for update;

  if lead_row.owner_id<>auth.uid()
    and not public.is_allyson_admin()
    and not public.is_restricted_admin() then
    raise exception 'Somente o corretor responsavel pode iniciar esta oferta.';
  end if;
  if lead_row.owner_id=auth.uid() and lead_row.assignment_status<>'accepted' then
    raise exception 'Aceite o lead antes de iniciar uma nova oferta.';
  end if;

  select * into property_row
  from public.crm_property_catalog
  where external_id=p_property_id;
  if not found then
    raise exception 'O imovel sugerido nao foi encontrado.';
  end if;

  update public.crm_property_match_notifications
  set offer_started_at=case when property_external_id=p_property_id then now() else offer_started_at end,
      dismissed_at=case when property_external_id<>p_property_id then coalesce(dismissed_at,now()) else dismissed_at end
  where lead_id=p_lead_id
    and offer_started_at is null;

  update public.crm_leads
  set property_catalog_id=p_property_id,
      property_interest=property_row.title,
      stage='Em atendimento',
      assignment_status='accepted',
      assignment_available_at=null,
      assignment_deadline_at=public.crm_add_commercial_minutes(now(),1440),
      assignment_reminder_sent_at=null,
      updated_at=now()
  where id=p_lead_id;

  select coalesce(nullif(trim(full_name),''),email,'Usuario')
  into actor
  from public.profiles
  where id=auth.uid();

  insert into public.crm_lead_activities(
    lead_id,stage,note,author_id,author_name
  ) values(
    p_lead_id,
    'Nova oferta iniciada',
    'Imovel selecionado: '||property_row.title||'.',
    auth.uid(),
    actor
  );
end;
$$;

revoke all on function public.start_similar_property_offer(uuid,text)
  from public,anon;
grant execute on function public.start_similar_property_offer(uuid,text)
  to authenticated;

create or replace function public.process_property_match_opportunities()
returns integer
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  item record;
  local_now timestamp:=now() at time zone 'America/Sao_Paulo';
  remaining_minutes integer;
  processed integer:=0;
begin
  for item in
    select
      m.lead_id,
      l.owner_id,
      l.name,
      min(m.expires_at) as expires_at,
      count(*)::integer as match_count,
      coalesce(bool_or(m.morning_reminder_on=local_now::date),false) as reminder_sent,
      coalesce(bool_or(m.expiry_warning_sent_at is not null),false) as warning_sent,
      jsonb_agg(m.property_external_id order by m.created_at) as property_ids
    from public.crm_property_match_notifications m
    join public.crm_leads l on l.id=m.lead_id
    where m.offer_started_at is null
      and m.expired_at is null
      and m.dismissed_at is null
    group by m.lead_id,l.owner_id,l.name
  loop
    remaining_minutes:=public.crm_weekday_minutes_between(now(),item.expires_at);

    if item.expires_at<=now() then
      update public.crm_property_match_notifications
      set expired_at=now()
      where lead_id=item.lead_id
        and offer_started_at is null
        and expired_at is null
        and dismissed_at is null;

      perform public.crm_restart_match_lead_queue(item.lead_id);
      processed:=processed+1;
    elsif remaining_minutes<=60 and not item.warning_sent then
      insert into public.crm_notification_outbox(
        recipient_id,kind,title,body,url,payload
      ) values(
        item.owner_id,
        'property_match_expiry_warning',
        'Prazo de imoveis similares termina em 1 hora',
        'O lead '||item.name||' voltara para a esteira em 1 hora se nenhuma nova oferta for iniciada.',
        '/leads?focusLeadId='||item.lead_id,
        jsonb_build_object(
          'leadId',item.lead_id,
          'propertyIds',item.property_ids,
          'expiresAt',item.expires_at
        )
      );

      update public.crm_property_match_notifications
      set expiry_warning_sent_at=now()
      where lead_id=item.lead_id
        and offer_started_at is null
        and expired_at is null
        and dismissed_at is null;
      processed:=processed+1;
    elsif extract(isodow from local_now)::integer<=6
      and local_now::time>=time '09:00'
      and local_now::time<time '10:00'
      and not item.reminder_sent then
      insert into public.crm_notification_outbox(
        recipient_id,kind,title,body,url,payload
      ) values(
        item.owner_id,
        'property_match_reminder',
        'Imovel similar aguardando oferta',
        case when item.match_count=1
          then 'Existe 1 imovel similar aguardando uma nova oferta para o lead '||item.name||'.'
          else 'Existem '||item.match_count||' imoveis similares aguardando uma nova oferta para o lead '||item.name||'.'
        end,
        '/leads?focusLeadId='||item.lead_id,
        jsonb_build_object(
          'leadId',item.lead_id,
          'propertyIds',item.property_ids,
          'expiresAt',item.expires_at
        )
      );

      update public.crm_property_match_notifications
      set morning_reminder_on=local_now::date
      where lead_id=item.lead_id
        and offer_started_at is null
        and expired_at is null
        and dismissed_at is null;
      processed:=processed+1;
    end if;
  end loop;

  return processed;
end;
$$;

revoke all on function public.process_property_match_opportunities()
  from public,anon,authenticated;
grant execute on function public.process_property_match_opportunities()
  to service_role;

commit;

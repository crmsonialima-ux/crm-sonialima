-- E-mail is optional for lead registration, including portal leads.
create or replace function public.refresh_portal_lead_registration_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  missing_fields text[] := array[]::text[];
begin
  if new.source_portal is null then
    new.registration_missing_fields := array[]::text[];
    new.registration_completed_at := null;
    return new;
  end if;
  if nullif(trim(coalesce(new.name, '')), '') is null
     or lower(trim(new.name)) in ('lead sem nome', 'sem nome') then
    missing_fields := array_append(missing_fields, 'name');
  end if;
  if length(coalesce(public.normalize_crm_phone_identity(new.phone), '')) not in (10, 11) then
    missing_fields := array_append(missing_fields, 'phone');
  end if;
  if new.property_catalog_id is null
     or nullif(trim(coalesce(new.property_interest, '')), '') is null then
    missing_fields := array_append(missing_fields, 'property_interest');
  end if;
  if new.lead_type is null or new.lead_type not in ('Venda', 'Aluguel') then
    missing_fields := array_append(missing_fields, 'lead_type');
  end if;
  if new.channel is distinct from (
    case new.source_portal
      when 'wimoveis' then 'W Imóveis'
      when 'dfimoveis' then 'DF Imóveis'
      else null
    end
  ) then
    missing_fields := array_append(missing_fields, 'channel');
  end if;
  if coalesce(new.desired_property_value, 0) <= 0 then
    missing_fields := array_append(missing_fields, 'desired_property_value');
  end if;
  if nullif(trim(coalesce(new.desired_location, '')), '') is null then
    missing_fields := array_append(missing_fields, 'desired_location');
  end if;
  new.registration_missing_fields := missing_fields;
  if cardinality(missing_fields) = 0 then
    new.registration_completed_at := case when tg_op = 'INSERT'
      then coalesce(new.registration_completed_at, now())
      else coalesce(old.registration_completed_at, now()) end;
  else
    new.registration_completed_at := null;
  end if;
  return new;
end;
$$;

-- Existing incomplete records stop treating e-mail as a pending requirement.
update public.crm_leads
set registration_missing_fields = array_remove(registration_missing_fields, 'email')
where registration_missing_fields @> array['email']::text[];

-- Thiago remains in sales and is removed only from the rental queue.
delete from public.lead_distribution_queue as queue
using public.profiles as profile
where queue.broker_id = profile.id
  and queue.lead_type = 'Aluguel'
  and lower(trim(profile.email)) = 'crmthiago@sonialima.com.br';

-- Only Allyson can manually transfer a lead to another owner. Server-side
-- automations have no auth.uid() and remain unaffected.
create or replace function public.restrict_manual_lead_transfer_to_allyson()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if new.owner_id is distinct from old.owner_id
     and auth.uid() is not null
     and not public.is_allyson_admin() then
    raise exception 'Somente Allyson pode transferir leads.';
  end if;
  return new;
end;
$$;

drop trigger if exists restrict_manual_lead_transfer_to_allyson on public.crm_leads;
create trigger restrict_manual_lead_transfer_to_allyson
before update of owner_id on public.crm_leads
for each row execute function public.restrict_manual_lead_transfer_to_allyson();

-- Every CRM profile can receive an Agenda demand.
create or replace function public.list_agenda_profiles()
returns table (id uuid, full_name text, email text, role text)
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select profile.id, profile.full_name, profile.email, profile.role::text
  from public.profiles as profile
  where profile.role in ('admin', 'broker')
  order by profile.full_name nulls last, profile.email;
$$;

revoke all on function public.list_agenda_profiles() from public, anon;
grant execute on function public.list_agenda_profiles() to authenticated;

-- Optional second attendee. One entry occupies both calendars.
create table if not exists public.crm_agenda_entry_participants (
  entry_id uuid not null references public.crm_agenda_entries(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  added_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (entry_id, user_id)
);

alter table public.crm_agenda_entry_participants enable row level security;
grant select on public.crm_agenda_entry_participants to authenticated;
drop policy if exists "Authenticated users read agenda participants"
  on public.crm_agenda_entry_participants;
create policy "Authenticated users read agenda participants"
  on public.crm_agenda_entry_participants for select to authenticated
  using (auth.uid() is not null);

create or replace function public.set_agenda_companions(
  p_entry_id uuid,
  p_companion_user_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  agenda_entry public.crm_agenda_entries;
begin
  if auth.uid() is null then raise exception 'Sessão não encontrada.'; end if;
  select * into agenda_entry from public.crm_agenda_entries where id = p_entry_id;
  if not found then raise exception 'Demanda não encontrada.'; end if;
  if agenda_entry.created_by <> auth.uid() then
    raise exception 'Somente quem criou a demanda pode definir o acompanhante inicial.';
  end if;

  delete from public.crm_agenda_entry_participants where entry_id = p_entry_id;

  insert into public.crm_notification_outbox(recipient_id, kind, title, body, url, payload)
  select agenda_entry.target_user_id, 'agenda_new_demand', 'Nova demanda na Agenda',
    agenda_entry.observation, '/agenda', jsonb_build_object('agendaId', p_entry_id)
  where not exists (
    select 1 from public.crm_notification_outbox as notification
    where notification.recipient_id = agenda_entry.target_user_id
      and notification.kind = 'agenda_new_demand'
      and notification.payload ->> 'agendaId' = p_entry_id::text
  );

  if coalesce(cardinality(p_companion_user_ids), 0) = 0 then return; end if;
  if agenda_entry.target_user_id = any(p_companion_user_ids) then
    raise exception 'Os acompanhantes devem ser diferentes do responsável.';
  end if;
  if exists (
    select 1
    from unnest(p_companion_user_ids) as selected(user_id)
    left join public.profiles as profile
      on profile.id = selected.user_id and profile.role in ('admin', 'broker')
    where profile.id is null
  ) then raise exception 'Acompanhante inválido.'; end if;

  insert into public.crm_agenda_entry_participants(entry_id, user_id, added_by)
  select p_entry_id, selected.user_id, auth.uid()
  from (select distinct unnest(p_companion_user_ids) as user_id) as selected;

  insert into public.crm_notification_outbox(recipient_id, kind, title, body, url, payload)
  select selected.user_id, 'agenda_new_demand', 'Nova demanda compartilhada na Agenda',
    agenda_entry.observation, '/agenda', jsonb_build_object('agendaId', p_entry_id)
  from (select distinct unnest(p_companion_user_ids) as user_id) as selected;
end;
$$;

revoke all on function public.set_agenda_companions(uuid, uuid[]) from public, anon;
grant execute on function public.set_agenda_companions(uuid, uuid[]) to authenticated;

-- All authenticated users may create regular demands for any CRM profile.
create or replace function public.create_agenda_entry(
  p_category public.agenda_category,
  p_scheduled_at timestamptz,
  p_observation text,
  p_target_user_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare entry_id uuid;
begin
  if auth.uid() is null then raise exception 'Sessão não encontrada.'; end if;
  if not exists (select 1 from public.profiles where id = p_target_user_id and role in ('admin','broker')) then
    raise exception 'Responsável inválido.';
  end if;
  if p_scheduled_at is null or nullif(trim(p_observation), '') is null then
    raise exception 'Informe data, hora e observação.';
  end if;
  insert into public.crm_agenda_entries(category, scheduled_at, observation, target_user_id, created_by)
  values (p_category, p_scheduled_at, trim(p_observation), p_target_user_id, auth.uid())
  returning id into entry_id;
  insert into public.crm_notification_outbox(recipient_id, kind, title, body, url, payload)
  values (p_target_user_id, 'agenda_new_demand', 'Nova demanda na Agenda', trim(p_observation), '/agenda', jsonb_build_object('agendaId', entry_id));
  return entry_id;
end;
$$;

create or replace function public.create_service_agenda_entry(
  p_category public.agenda_category,
  p_scheduled_at timestamptz,
  p_client_name text,
  p_property_address text,
  p_service text,
  p_target_user_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare entry_id uuid; summary text;
begin
  if auth.uid() is null then raise exception 'Sessão não encontrada.'; end if;
  if p_category not in ('neo_energia', 'caesb') then raise exception 'Categoria inválida.'; end if;
  if not exists (select 1 from public.profiles where id = p_target_user_id and role in ('admin','broker')) then
    raise exception 'Responsável inválido.';
  end if;
  if p_scheduled_at is null or nullif(trim(p_client_name),'') is null
     or nullif(trim(p_property_address),'') is null or nullif(trim(p_service),'') is null then
    raise exception 'Informe data, hora, cliente, endereço do imóvel e serviço.';
  end if;
  summary := 'Cliente: ' || trim(p_client_name) || E'\nImóvel: ' || trim(p_property_address) || E'\nServiço: ' || trim(p_service);
  insert into public.crm_agenda_entries(
    category, scheduled_at, observation, target_user_id, created_by,
    demand_client_name, demand_property_address, demand_service
  ) values (
    p_category, p_scheduled_at, summary, p_target_user_id, auth.uid(),
    trim(p_client_name), trim(p_property_address), trim(p_service)
  ) returning id into entry_id;
  insert into public.crm_notification_outbox(recipient_id, kind, title, body, url, payload)
  values (p_target_user_id, 'agenda_new_demand', 'Nova demanda na Agenda', summary, '/agenda', jsonb_build_object('agendaId', entry_id));
  return entry_id;
end;
$$;

-- Manual demands remain shared. A lead visit can be managed by its responsible
-- user, a companion or an administrator.
create or replace function public.can_manage_agenda_entry(p_entry_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select auth.uid() is not null and exists (
    select 1 from public.crm_agenda_entries entry
    where entry.id = p_entry_id
      and entry.feedback_at is null
      and (
        entry.source_kind is distinct from 'lead_visit'
        or public.is_admin()
        or entry.target_user_id = auth.uid()
        or exists (
          select 1 from public.crm_agenda_entry_participants participant
          where participant.entry_id=entry.id and participant.user_id=auth.uid()
        )
      )
  );
$$;

create or replace function public.update_agenda_entry(
  p_id uuid,
  p_category public.agenda_category,
  p_scheduled_at timestamptz,
  p_target_user_id uuid,
  p_observation text default null,
  p_client_name text default null,
  p_property_address text default null,
  p_cartorio_name text default null,
  p_service text default null
)
returns public.crm_agenda_entries
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare current_entry public.crm_agenda_entries; updated_entry public.crm_agenda_entries; summary text; derley_id uuid; actor_name text;
begin
  select * into current_entry from public.crm_agenda_entries where id = p_id for update;
  if not found then raise exception 'Demanda não encontrada.'; end if;
  if not public.can_manage_agenda_entry(p_id) then raise exception 'Esta demanda não pode ser alterada.'; end if;
  if p_scheduled_at is null then raise exception 'Informe data e hora.'; end if;
  if current_entry.source_kind='lead_visit' and current_entry.source_lead_id is not null then
    update public.crm_agenda_entries set
      scheduled_at=p_scheduled_at,
      reminder_sent_at=case when scheduled_at is distinct from p_scheduled_at then null else reminder_sent_at end,
      updated_at=now()
    where id=p_id returning * into updated_entry;

    update public.crm_leads set
      stage='Visita agendada', visit_scheduled_at=p_scheduled_at, updated_at=now()
    where id=current_entry.source_lead_id;
    if not found then raise exception 'Lead vinculado não encontrado.'; end if;

    select coalesce(nullif(full_name,''),email,'Usuário') into actor_name
    from public.profiles where id=auth.uid();
    insert into public.crm_lead_activities(lead_id,stage,note,author_id,author_name,scheduled_for)
    values(current_entry.source_lead_id,'Visita reagendada','Reagendada pela Agenda.',auth.uid(),coalesce(actor_name,'Usuário'),p_scheduled_at);
    return updated_entry;
  end if;
  if p_category = 'cartorio' then
    select id into derley_id from public.profiles where lower(trim(email))='unassigned-agenda@example.invalid' limit 1;
    if p_target_user_id <> derley_id then raise exception 'Demandas de Cartório devem permanecer com Derley.'; end if;
    if nullif(trim(coalesce(p_client_name,'')),'') is null or nullif(trim(coalesce(p_property_address,'')),'') is null
       or nullif(trim(coalesce(p_cartorio_name,'')),'') is null or nullif(trim(coalesce(p_service,'')),'') is null then
      raise exception 'Informe cliente, imóvel, cartório e serviço.';
    end if;
    summary := 'Cliente: '||trim(p_client_name)||E'\nImóvel: '||trim(p_property_address)||E'\nCartório: '||trim(p_cartorio_name)||E'\nServiço: '||trim(p_service);
  elsif p_category in ('neo_energia','caesb') then
    if nullif(trim(coalesce(p_client_name,'')),'') is null or nullif(trim(coalesce(p_property_address,'')),'') is null or nullif(trim(coalesce(p_service,'')),'') is null then
      raise exception 'Informe cliente, imóvel e serviço.';
    end if;
    summary := 'Cliente: '||trim(p_client_name)||E'\nImóvel: '||trim(p_property_address)||E'\nServiço: '||trim(p_service);
  else
    if nullif(trim(coalesce(p_observation,'')),'') is null then raise exception 'Informe a observação.'; end if;
    summary := trim(p_observation);
  end if;
  update public.crm_agenda_entries set
    category=p_category, scheduled_at=p_scheduled_at, target_user_id=p_target_user_id, observation=summary,
    cartorio_client_name=case when p_category='cartorio' then trim(p_client_name) end,
    cartorio_property_address=case when p_category='cartorio' then trim(p_property_address) end,
    cartorio_name=case when p_category='cartorio' then trim(p_cartorio_name) end,
    cartorio_service=case when p_category='cartorio' then trim(p_service) end,
    demand_client_name=case when p_category in ('neo_energia','caesb') then trim(p_client_name) end,
    demand_property_address=case when p_category in ('neo_energia','caesb') then trim(p_property_address) end,
    demand_service=case when p_category in ('neo_energia','caesb') then trim(p_service) end,
    reminder_sent_at=case when scheduled_at is distinct from p_scheduled_at then null else reminder_sent_at end,
    updated_at=now()
  where id=p_id returning * into updated_entry;
  delete from public.crm_agenda_entry_participants
  where entry_id=p_id and user_id=p_target_user_id;
  return updated_entry;
end;
$$;

create or replace function public.delete_agenda_entry(p_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare current_entry public.crm_agenda_entries; actor_name text;
begin
  select * into current_entry from public.crm_agenda_entries where id=p_id for update;
  if not found then raise exception 'Demanda não encontrada.'; end if;
  if not public.is_allyson_admin() and not public.can_manage_agenda_entry(p_id) then
    raise exception 'Esta demanda não pode ser excluída.';
  end if;
  delete from public.crm_agenda_entries where id=p_id;
  if current_entry.source_kind='lead_visit' and current_entry.source_lead_id is not null then
    update public.crm_leads set
      stage='Em atendimento', visit_scheduled_at=null, updated_at=now()
    where id=current_entry.source_lead_id
      and visit_scheduled_at=current_entry.scheduled_at;
    if found then
      select coalesce(nullif(full_name,''),email,'Usuário') into actor_name
      from public.profiles where id=auth.uid();
      insert into public.crm_lead_activities(lead_id,stage,note,author_id,author_name)
      values(current_entry.source_lead_id,'Visita cancelada','Agendamento excluído pela Agenda.',auth.uid(),coalesce(actor_name,'Usuário'));
    end if;
  end if;
end;
$$;

create or replace function public.feedback_agenda_entry(p_id uuid,p_feedback_at timestamptz,p_note text)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare registered_at timestamptz; agenda_entry public.crm_agenda_entries;
begin
  select * into agenda_entry from public.crm_agenda_entries where id=p_id;
  if not found then raise exception 'Demanda não encontrada.'; end if;
  if auth.uid() is distinct from agenda_entry.target_user_id and not exists (
    select 1 from public.crm_agenda_entry_participants where entry_id=p_id and user_id=auth.uid()
  ) then raise exception 'Somente os envolvidos podem concluir esta demanda.'; end if;
  registered_at:=coalesce(p_feedback_at,now());
  update public.crm_agenda_entries set feedback_at=registered_at,
    feedback_note=nullif(trim(coalesce(p_note,'')),''), feedback_by=auth.uid(),
    feedback_history=coalesce(feedback_history,'[]'::jsonb)||jsonb_build_array(jsonb_build_object('at',registered_at,'note',nullif(trim(coalesce(p_note,'')),''),'by',auth.uid())),
    updated_at=now() where id=p_id;
end;
$$;

-- One hour before, notify the primary responsible and optional companion.
create or replace function public.process_agenda_one_hour_notifications()
returns integer language plpgsql security definer set search_path=pg_catalog,public as $$
declare entry record; inserted_count integer; created_count integer:=0;
begin
  for entry in select * from public.crm_agenda_entries
    where reminder_sent_at is null and feedback_at is null
      and scheduled_at > now() and scheduled_at <= now()+interval '1 hour'
    for update skip locked
  loop
    insert into public.crm_notification_outbox(recipient_id,kind,title,body,url,payload)
    select involved.user_id,'agenda_reminder','Compromisso em 1 hora',entry.observation,'/agenda',jsonb_build_object('agendaId',entry.id)
    from (
      select entry.target_user_id as user_id
      union
      select participant.user_id from public.crm_agenda_entry_participants participant where participant.entry_id=entry.id
    ) involved;
    get diagnostics inserted_count=row_count;
    created_count:=created_count+inserted_count;
    update public.crm_agenda_entries set reminder_sent_at=now() where id=entry.id;
  end loop;
  return created_count;
end;
$$;

revoke all on function public.process_agenda_one_hour_notifications() from public,anon,authenticated;
grant execute on function public.process_agenda_one_hour_notifications() to service_role;

do $$ declare scheduled_job record; begin
  for scheduled_job in select jobid from cron.job where jobname='agenda-one-hour-notifications' loop
    perform cron.unschedule(scheduled_job.jobid);
  end loop;
end $$;
select cron.schedule('agenda-one-hour-notifications','* * * * *',$$select public.process_agenda_one_hour_notifications();$$);

revoke all on function public.can_manage_agenda_entry(uuid) from public,anon;
grant execute on function public.can_manage_agenda_entry(uuid) to authenticated,service_role;
grant execute on function public.create_agenda_entry(public.agenda_category,timestamptz,text,uuid) to authenticated;
grant execute on function public.create_service_agenda_entry(public.agenda_category,timestamptz,text,text,text,uuid) to authenticated;
grant execute on function public.update_agenda_entry(uuid,public.agenda_category,timestamptz,uuid,text,text,text,text,text) to authenticated;
grant execute on function public.delete_agenda_entry(uuid) to authenticated;
grant execute on function public.feedback_agenda_entry(uuid,timestamptz,text) to authenticated;

-- Leads created by anyone except Allyson belong to their creator and never rotate in the queue.
drop trigger if exists crm_leads_restrict_accesscrm_update on public.crm_leads;

create or replace function public.create_creator_owned_lead(
  p_name text, p_phone text, p_email text, p_property_interest text, p_stage text,
  p_channel text, p_notes text, p_lead_type text, p_desired_property_value numeric,
  p_desired_location text, p_visit_scheduled_at timestamptz default null
)
returns table (lead_id uuid, assigned_owner_id uuid, assigned_owner_name text)
language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  creator public.profiles%rowtype;
  inserted_lead uuid;
  normalized_phone text;
begin
  if auth.uid() is null then raise exception 'Sessão não encontrada.'; end if;
  select * into creator from public.profiles where id=auth.uid();
  if not found then raise exception 'Perfil não encontrado.'; end if;
  if p_lead_type not in ('Venda','Aluguel') then raise exception 'Tipo de lead inválido.'; end if;
  if coalesce(p_desired_property_value,0)<=0 then raise exception 'Informe o valor médio do imóvel desejado.'; end if;
  if nullif(trim(p_desired_location),'') is null then raise exception 'Informe a localização desejada.'; end if;
  if p_stage='Visita agendada' and p_visit_scheduled_at is null then
    raise exception 'Informe a data e a hora da visita.';
  end if;

  normalized_phone:=regexp_replace(coalesce(p_phone,''),'\D','','g');
  if normalized_phone='' then raise exception 'Telefone é obrigatório.'; end if;
  perform pg_advisory_xact_lock(hashtext(normalized_phone));
  if exists(select 1 from public.crm_leads where regexp_replace(coalesce(phone,''),'\D','','g')=normalized_phone) then
    raise exception 'Já existe um lead cadastrado com este telefone.';
  end if;

  insert into public.crm_leads(
    name,phone,email,property_interest,stage,channel,budget,notes,owner_id,created_by,
    lead_type,desired_property_value,desired_location,visit_scheduled_at,
    assignment_status,assignment_deadline_at
  ) values(
    trim(p_name),nullif(trim(p_phone),''),nullif(trim(p_email),''),nullif(trim(p_property_interest),''),
    p_stage,nullif(trim(p_channel),''),0,nullif(trim(p_notes),''),auth.uid(),auth.uid(),
    p_lead_type,p_desired_property_value,trim(p_desired_location),p_visit_scheduled_at,
    'accepted',null
  ) returning id into inserted_lead;

  -- Neutralize the generic distribution trigger if it produced an acceptance attempt.
  update public.crm_leads set owner_id=auth.uid(),assignment_status='accepted',assignment_deadline_at=null
  where id=inserted_lead;
  delete from public.lead_assignment_attempts where lead_id=inserted_lead;
  delete from public.crm_notification_outbox
  where kind='lead_assignment' and payload->>'leadId'=inserted_lead::text;

  return query select inserted_lead,creator.id,coalesce(nullif(creator.full_name,''),creator.email);
end;
$$;

revoke all on function public.create_creator_owned_lead(text,text,text,text,text,text,text,text,numeric,text,timestamptz)
from public,anon;
grant execute on function public.create_creator_owned_lead(text,text,text,text,text,text,text,text,numeric,text,timestamptz)
to authenticated;

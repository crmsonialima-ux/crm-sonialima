begin;

-- Em visitas de aluguel, o dono comercial do lead continua inalterado, mas a
-- agenda pertence exclusivamente ao corretor escolhido para executar a visita.
alter table public.crm_leads
  add column if not exists visit_executor_id uuid references public.profiles(id) on delete set null;

create index if not exists crm_leads_visit_executor_idx
  on public.crm_leads(visit_executor_id)
  where visit_executor_id is not null;

create or replace function public.validate_rental_visit_executor()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if lower(trim(coalesce(new.lead_type::text, ''))) = 'aluguel'
     and new.stage = 'Visita agendada'
     and new.visit_scheduled_at is not null then
    if new.visit_executor_id is null then
      raise exception 'Selecione o corretor que fara a visita de aluguel.';
    end if;

    if not exists (
      select 1
      from public.profiles as profile
      where profile.id = new.visit_executor_id
        and profile.role = 'broker'
    ) then
      raise exception 'O responsavel pela visita de aluguel deve ser um corretor ativo.';
    end if;
  elsif lower(trim(coalesce(new.lead_type::text, ''))) <> 'aluguel' then
    new.visit_executor_id := null;
  end if;

  return new;
end;
$$;

drop trigger if exists crm_leads_validate_rental_visit_executor on public.crm_leads;
create trigger crm_leads_validate_rental_visit_executor
before update of stage, visit_scheduled_at, visit_executor_id, lead_type
on public.crm_leads
for each row execute procedure public.validate_rental_visit_executor();

-- Preserva os compromissos existentes: quando houver agenda, ela e a fonte mais
-- segura para descobrir quem ja estava escalado; caso contrario, usa o dono.
update public.crm_leads as lead
set visit_executor_id = coalesce(
  (
    select entry.target_user_id
    from public.crm_agenda_entries as entry
    where entry.source_kind = 'lead_visit'
      and entry.source_lead_id = lead.id
      and entry.scheduled_at = lead.visit_scheduled_at
    order by entry.created_at desc
    limit 1
  ),
  lead.owner_id
)
where lower(trim(coalesce(lead.lead_type::text, ''))) = 'aluguel'
  and lead.stage = 'Visita agendada'
  and lead.visit_scheduled_at is not null
  and lead.visit_executor_id is null;

create or replace function public.sync_lead_visit_to_agenda()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_id uuid;
  visit_description text;
  visit_target_id uuid;
  should_create boolean := false;
begin
  visit_target_id := case
    when lower(trim(coalesce(new.lead_type::text, ''))) = 'aluguel'
      then coalesce(new.visit_executor_id, new.owner_id)
    else new.owner_id
  end;

  if tg_op = 'UPDATE'
     and (
       old.owner_id is distinct from new.owner_id
       or old.visit_executor_id is distinct from new.visit_executor_id
       or old.lead_type is distinct from new.lead_type
     ) then
    update public.crm_agenda_entries
    set target_user_id = visit_target_id,
        updated_at = now()
    where source_kind = 'lead_visit'
      and source_lead_id = new.id
      and scheduled_at >= now();
  end if;

  if new.stage <> 'Visita agendada' or new.visit_scheduled_at is null then
    return new;
  end if;

  if tg_op = 'INSERT' then
    should_create := true;
  elsif old.visit_scheduled_at is distinct from new.visit_scheduled_at
     or old.stage is distinct from new.stage then
    should_create := true;
  end if;

  if not should_create then
    return new;
  end if;

  actor_id := coalesce(auth.uid(), new.created_by, new.owner_id);
  visit_description := 'Visita agendada — '
    || coalesce(nullif(trim(new.name), ''), 'Cliente sem nome');

  if nullif(trim(coalesce(new.property_interest, '')), '') is not null then
    visit_description := visit_description || E'\nImóvel: ' || trim(new.property_interest);
  end if;

  insert into public.crm_agenda_entries (
    category, scheduled_at, observation, target_user_id, created_by,
    source_kind, source_lead_id
  ) values (
    'observacao', new.visit_scheduled_at, visit_description, visit_target_id,
    actor_id, 'lead_visit', new.id
  )
  on conflict (source_lead_id, scheduled_at)
    where source_kind = 'lead_visit' and source_lead_id is not null
  do update set
    target_user_id = excluded.target_user_id,
    observation = excluded.observation,
    updated_at = now();

  return new;
end;
$$;

drop trigger if exists crm_leads_sync_visit_to_agenda on public.crm_leads;
create trigger crm_leads_sync_visit_to_agenda
after insert or update of stage, visit_scheduled_at, owner_id, visit_executor_id, lead_type
on public.crm_leads
for each row execute procedure public.sync_lead_visit_to_agenda();

-- Cada corretor pode registrar quantas observacoes quiser nos proprios leads,
-- sem alterar a etapa. Allyson e acessocrm continuam com acesso global.
create or replace function public.add_administrative_lead_observation(
  p_lead_id uuid,
  p_note text
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  actor public.profiles%rowtype;
  lead_owner_id uuid;
  activity_id uuid;
  display_author text;
begin
  select profile.* into actor
  from public.profiles as profile
  where profile.id = auth.uid();

  if not found then
    raise exception 'Sessao nao encontrada.';
  end if;

  if nullif(trim(p_note), '') is null then
    raise exception 'Informe a observacao.';
  end if;

  select lead.owner_id into lead_owner_id
  from public.crm_leads as lead
  where lead.id = p_lead_id;

  if not found then
    raise exception 'Lead nao encontrado.';
  end if;

  if actor.role <> 'admin' and lead_owner_id <> actor.id then
    raise exception 'Voce so pode adicionar observacoes aos leads da sua carteira.';
  end if;

  display_author := case lower(trim(actor.email))
    when 'crmsoniaallyson@gmail.com' then 'Allyson'
    when 'unassigned-institutional@example.invalid' then 'SoniaLima'
    else coalesce(nullif(trim(actor.full_name), ''), actor.email)
  end;

  insert into public.crm_lead_activities (
    lead_id, stage, note, author_id, author_name
  ) values (
    p_lead_id, 'Observação', trim(p_note), actor.id, display_author
  )
  returning id into activity_id;

  return activity_id;
end;
$$;

revoke all on function public.add_administrative_lead_observation(uuid, text)
  from public, anon;
grant execute on function public.add_administrative_lead_observation(uuid, text)
  to authenticated;

-- A decisao passa a ser gravada nas notificacoes dos dois administradores.
-- Assim, ao recarregar ou abrir em outro dispositivo, Sim/Nao nao reaparecem.
create or replace function public.decide_agenda_companion_request(
  p_entry_id uuid,
  p_approved boolean
)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  entry public.crm_agenda_entries%rowtype;
  final_status text;
  decision_at timestamptz;
  decision_name text;
begin
  if not (public.is_allyson_admin() or public.is_restricted_admin()) then
    raise exception 'Somente Allyson ou SoniaLima podem decidir este pedido.';
  end if;

  select * into entry
  from public.crm_agenda_entries
  where id = p_entry_id
  for update;

  if not found then
    raise exception 'Pedido nao encontrado.';
  end if;

  if entry.companion_approval_status = 'pending' then
    final_status := case when p_approved then 'approved' else 'rejected' end;
    decision_at := now();

    if p_approved then
      insert into public.crm_agenda_entry_participants(entry_id, user_id, added_by)
      select p_entry_id, id, auth.uid()
      from unnest(entry.requested_companion_ids) as requested(id)
      on conflict do nothing;
    end if;

    update public.crm_agenda_entries
    set companion_approval_status = final_status,
        companion_decided_at = decision_at,
        companion_decided_by = auth.uid(),
        updated_at = now()
    where id = p_entry_id;

    if p_approved then
      insert into public.crm_notification_outbox(recipient_id, kind, title, body, url, payload)
      select recipient, 'agenda_new_demand', 'Demanda com acompanhante autorizada',
        entry.observation, '/agenda', jsonb_build_object('agendaId', p_entry_id)
      from (
        select entry.target_user_id as recipient
        union
        select unnest(entry.requested_companion_ids)
      ) as recipients;
    else
      insert into public.crm_notification_outbox(recipient_id, kind, title, body, url, payload)
      values (
        entry.created_by, 'agenda_companion_rejected', 'Acompanhante nao autorizado',
        entry.companion_reason, '/agenda', jsonb_build_object('agendaId', p_entry_id)
      );
    end if;
  else
    final_status := entry.companion_approval_status;
    decision_at := coalesce(entry.companion_decided_at, now());
  end if;

  select coalesce(nullif(trim(profile.full_name), ''), profile.email)
  into decision_name
  from public.profiles as profile
  where profile.id = coalesce(entry.companion_decided_by, auth.uid());

  update public.crm_notification_outbox
  set payload = coalesce(payload, '{}'::jsonb)
      || jsonb_build_object(
        'decisionStatus', final_status,
        'decisionBy', coalesce(entry.companion_decided_by, auth.uid()),
        'decisionByName', coalesce(decision_name, 'Administrador'),
        'decidedAt', decision_at
      ),
      read_at = coalesce(read_at, now())
  where kind = 'agenda_companion_approval'
    and payload ->> 'agendaId' = p_entry_id::text
    and coalesce(payload ->> 'decisionStatus', 'pending') = 'pending';

  return final_status;
end;
$$;

revoke all on function public.decide_agenda_companion_request(uuid, boolean)
  from public, anon;
grant execute on function public.decide_agenda_companion_request(uuid, boolean)
  to authenticated;

commit;

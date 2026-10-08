begin;

alter table public.crm_leads
  add column if not exists visit_executor_ids uuid[] not null default '{}'::uuid[];

update public.crm_leads
set visit_executor_ids = array[visit_executor_id]
where visit_executor_id is not null
  and cardinality(visit_executor_ids) = 0;

-- A criacao atomica de uma visita inicia o lead em "Em atendimento" para
-- reutilizar as regras de atribuicao existentes e, na mesma transacao, muda
-- para "Visita agendada". Essa transicao inicial nao representa uma
-- qualificacao comercial concluida. O GUC local abaixo e definido somente pela
-- RPC de criacao e e amarrado ao ID novo, portanto nao flexibiliza alteracoes
-- normais de etapas feitas pela interface.
create or replace function public.enforce_lead_commercial_qualification()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  old_stage text := public.crm_normalize_property_match_text(old.stage);
  new_stage text := public.crm_normalize_property_match_text(new.stage);
  is_initial_visit_creation boolean := coalesce(
    current_setting('crm.initial_visit_lead_id', true),
    ''
  ) = new.id::text;
  is_direct_user_change boolean := auth.uid() is not null
    and pg_trigger_depth() = 1
    and not is_initial_visit_creation;
begin
  if is_direct_user_change
     and new.commercial_qualification_required
     and old_stage = 'em atendimento'
     and new_stage <> 'em atendimento' then
    if new.has_property_to_sell is null
       or new.needs_financing is null
       or new.will_use_fgts is null
       or new.banking_correspondent_presented is null then
      raise exception 'Responda todas as perguntas da qualificacao comercial antes de sair de Em atendimento.';
    end if;

    if new.has_property_to_sell
       and (
         nullif(trim(new.property_to_sell_location), '') is null
         or new.property_to_sell_value is null
         or new.property_to_sell_value <= 0
       ) then
      raise exception 'Informe a localizacao e o valor do imovel que o lead pretende vender.';
    end if;
  end if;

  if is_direct_user_change
     and new.commercial_qualification_required
     and old_stage = 'visita realizada'
     and new_stage <> 'visita realizada'
     and new.visit_property_captured is null then
    raise exception 'Informe se o imovel do cliente foi captado antes de sair de Visita realizada.';
  end if;

  return new;
end;
$$;

revoke all on function public.enforce_lead_commercial_qualification()
  from public, anon, authenticated;

create or replace function public.validate_rental_visit_executor()
returns trigger language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  normalized_ids uuid[];
begin
  -- Mantem a ordem escolhida na interface e remove repeticoes sem deixar o
  -- executor primario variar conforme o plano de execucao do PostgreSQL.
  normalized_ids := array(
    select selected.executor_id
    from unnest(coalesce(new.visit_executor_ids, '{}'::uuid[]))
      with ordinality as selected(executor_id, position)
    where selected.executor_id is not null
    group by selected.executor_id
    order by min(selected.position)
  );

  if lower(trim(coalesce(new.lead_type::text, ''))) = 'aluguel'
     and new.stage = 'Visita agendada'
     and new.visit_scheduled_at is not null then
    if cardinality(normalized_ids) = 0 and new.visit_executor_id is not null then
      normalized_ids := array[new.visit_executor_id];
    end if;
    if cardinality(normalized_ids) = 0 then
      raise exception 'Selecione ao menos um corretor para a visita de aluguel.';
    end if;
    if exists (
      select 1 from unnest(normalized_ids) as selected(executor_id)
      left join public.profiles as profile on profile.id = selected.executor_id
      where profile.id is null or profile.role <> 'broker'
    ) then
      raise exception 'Todos os responsáveis pela visita devem ser corretores ativos.';
    end if;
    new.visit_executor_ids := normalized_ids;
    new.visit_executor_id := normalized_ids[1];
  elsif lower(trim(coalesce(new.lead_type::text, ''))) <> 'aluguel' then
    new.visit_executor_id := null;
    new.visit_executor_ids := '{}'::uuid[];
  end if;
  return new;
end;
$$;

drop trigger if exists crm_leads_validate_rental_visit_executor on public.crm_leads;
create trigger crm_leads_validate_rental_visit_executor
before insert or update of stage, visit_scheduled_at, visit_executor_id, visit_executor_ids, lead_type
on public.crm_leads for each row execute procedure public.validate_rental_visit_executor();

create or replace function public.sync_lead_visit_to_agenda()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  actor_id uuid;
  visit_description text;
  visit_target_id uuid;
  selected_executor_ids uuid[];
  previous_executor_ids uuid[] := '{}'::uuid[];
  agenda_entry_id uuid;
  should_create boolean := false;
begin
  selected_executor_ids := case
    when lower(trim(coalesce(new.lead_type::text, ''))) = 'aluguel'
      then coalesce(nullif(new.visit_executor_ids, '{}'::uuid[]), array[coalesce(new.visit_executor_id, new.owner_id)])
    else array[new.owner_id]
  end;

  -- A funcao de validacao normaliza updates, mas o espelhamento tambem pode
  -- ser chamado em inserts feitos por integracoes. Normalizamos novamente para
  -- que o primeiro corretor seja sempre o primeiro selecionado pelo usuario.
  selected_executor_ids := array(
    select selected.executor_id
    from unnest(coalesce(selected_executor_ids, '{}'::uuid[]))
      with ordinality as selected(executor_id, position)
    where selected.executor_id is not null
    group by selected.executor_id
    order by min(selected.position)
  );

  if tg_op = 'UPDATE'
     and lower(trim(coalesce(old.lead_type::text, ''))) = 'aluguel' then
    previous_executor_ids := coalesce(
      nullif(old.visit_executor_ids, '{}'::uuid[]),
      array_remove(array[old.visit_executor_id], null)
    );
  end if;

  visit_target_id := selected_executor_ids[1];

  if tg_op = 'UPDATE'
     and new.stage = 'Visita agendada'
     and new.visit_scheduled_at is not null
     and (
       old.owner_id is distinct from new.owner_id
       or old.visit_executor_id is distinct from new.visit_executor_id
       or old.visit_executor_ids is distinct from new.visit_executor_ids
       or old.lead_type is distinct from new.lead_type
     ) then
    update public.crm_agenda_entries
    set target_user_id = visit_target_id, updated_at = now()
    where source_kind = 'lead_visit'
      and source_lead_id = new.id
      and scheduled_at = new.visit_scheduled_at;
  end if;

  if new.stage <> 'Visita agendada' or new.visit_scheduled_at is null then return new; end if;
  if tg_op = 'INSERT' then
    should_create := true;
  elsif old.visit_scheduled_at is distinct from new.visit_scheduled_at
     or old.stage is distinct from new.stage
     or old.owner_id is distinct from new.owner_id
     or old.visit_executor_ids is distinct from new.visit_executor_ids
     or old.lead_type is distinct from new.lead_type then
    should_create := true;
  end if;
  if not should_create then return new; end if;

  actor_id := coalesce(auth.uid(), new.created_by, new.owner_id);
  visit_description := 'Visita agendada — ' || coalesce(nullif(trim(new.name), ''), 'Cliente sem nome');
  if nullif(trim(coalesce(new.property_interest, '')), '') is not null then
    visit_description := visit_description || E'\nImóvel: ' || trim(new.property_interest);
  end if;

  insert into public.crm_agenda_entries (
    category, scheduled_at, observation, target_user_id, created_by, source_kind, source_lead_id
  ) values (
    'observacao', new.visit_scheduled_at, visit_description, visit_target_id,
    actor_id, 'lead_visit', new.id
  )
  on conflict (source_lead_id, scheduled_at)
    where source_kind = 'lead_visit' and source_lead_id is not null
  do update set target_user_id = excluded.target_user_id,
    observation = excluded.observation, updated_at = now()
  returning id into agenda_entry_id;

  if lower(trim(coalesce(new.lead_type::text, ''))) = 'aluguel' then
    -- Remove somente participantes que pertenciam ao conjunto anterior de
    -- executores de aluguel. Participantes de outras origens (especialmente
    -- acompanhantes aprovados) permanecem associados ao compromisso.
    delete from public.crm_agenda_entry_participants as participant
    where participant.entry_id = agenda_entry_id
      and participant.user_id = any(previous_executor_ids)
      and not exists (
        select 1
        from unnest(selected_executor_ids) as selected(executor_id)
        where selected.executor_id = participant.user_id
          and selected.executor_id <> visit_target_id
      )
      and not exists (
        select 1
        from public.crm_agenda_entries as protected_entry
        where protected_entry.id = participant.entry_id
          and protected_entry.companion_approval_status = 'approved'
          and participant.user_id = any(
            coalesce(protected_entry.requested_companion_ids, '{}'::uuid[])
          )
      );

    insert into public.crm_agenda_entry_participants(entry_id, user_id, added_by)
    select agenda_entry_id, executor_id, actor_id
    from unnest(selected_executor_ids) as selected(executor_id)
    where executor_id <> visit_target_id
    on conflict do nothing;

    -- A sincronizacao do banco passa a ser a unica responsavel por avisar os
    -- executores. O NOT EXISTS torna a operacao segura em reagendamentos e
    -- substitui a chamada redundante a set_agenda_companions no frontend.
    insert into public.crm_notification_outbox(
      recipient_id, kind, title, body, url, payload
    )
    select
      selected.executor_id,
      'agenda_new_demand',
      case
        when selected.executor_id = visit_target_id then 'Nova demanda na Agenda'
        else 'Nova demanda compartilhada na Agenda'
      end,
      visit_description,
      '/agenda',
      jsonb_build_object('agendaId', agenda_entry_id)
    from unnest(selected_executor_ids) as selected(executor_id)
    where not exists (
      select 1
      from public.crm_notification_outbox as notification
      where notification.recipient_id = selected.executor_id
        and notification.kind = 'agenda_new_demand'
        and notification.payload ->> 'agendaId' = agenda_entry_id::text
    );
  end if;
  return new;
end;
$$;

drop trigger if exists crm_leads_sync_visit_to_agenda on public.crm_leads;
create trigger crm_leads_sync_visit_to_agenda
after insert or update of stage, visit_scheduled_at, owner_id, visit_executor_id, visit_executor_ids, lead_type
on public.crm_leads for each row execute procedure public.sync_lead_visit_to_agenda();

-- Cria o lead e agenda a visita na mesma transacao. Assim uma visita de
-- aluguel nunca fica salva sem todos os executores escolhidos, mesmo quando
-- o lead e criado diretamente pela tela de cadastro.
create or replace function public.create_scheduled_visit_lead_with_phones_and_executors(
  p_name text,
  p_phone text,
  p_additional_phones text[],
  p_email text,
  p_property_interest text,
  p_channel text,
  p_notes text,
  p_lead_type text,
  p_desired_property_value numeric,
  p_desired_location text,
  p_visit_scheduled_at timestamptz,
  p_visit_executor_ids uuid[],
  p_owner_id uuid,
  p_use_vitor_queue boolean
)
returns table (lead_id uuid, assigned_owner_id uuid, assigned_owner_name text)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  created_lead record;
  normalized_executor_ids uuid[];
  creator_name text;
begin
  if auth.uid() is null then
    raise exception 'Sessao nao encontrada.';
  end if;
  if p_visit_scheduled_at is null then
    raise exception 'Informe a data e a hora da visita.';
  end if;
  if p_owner_id is not null and coalesce(p_use_vitor_queue, false) then
    raise exception 'Escolha atribuicao direta ou fila, nao as duas opcoes.';
  end if;

  normalized_executor_ids := array(
    select selected.executor_id
    from unnest(coalesce(p_visit_executor_ids, '{}'::uuid[]))
      with ordinality as selected(executor_id, position)
    where selected.executor_id is not null
    group by selected.executor_id
    order by min(selected.position)
  );

  if lower(trim(coalesce(p_lead_type, ''))) = 'aluguel'
     and cardinality(normalized_executor_ids) = 0 then
    raise exception 'Selecione ao menos um corretor para a visita de aluguel.';
  end if;

  if p_owner_id is not null then
    select * into created_lead
    from public.create_allyson_assigned_lead_with_phones(
      p_name, p_phone, p_additional_phones, p_email, p_property_interest,
      'Em atendimento', p_channel, p_notes, p_lead_type,
      p_desired_property_value, p_desired_location, p_owner_id, null
    );
  elsif coalesce(p_use_vitor_queue, false) then
    select * into created_lead
    from public.create_vitor_distributed_lead_with_phones(
      p_name, p_phone, p_additional_phones, p_email, p_property_interest,
      'Em atendimento', p_channel, p_notes, p_lead_type,
      p_desired_property_value, p_desired_location, null
    );
  else
    select * into created_lead
    from public.create_lead_with_phones(
      p_name, p_phone, p_additional_phones, p_email, p_property_interest,
      'Em atendimento', p_channel, p_notes, p_lead_type,
      p_desired_property_value, p_desired_location, null
    );
  end if;

  if created_lead.lead_id is null then
    raise exception 'Nao foi possivel cadastrar o lead com a visita agendada.';
  end if;

  -- Permite exclusivamente a transicao inicial deste lead dentro desta mesma
  -- transacao. A configuracao e LOCAL e desaparece ao concluir ou reverter a
  -- RPC; ela nao pode liberar futuras alteracoes de etapa.
  perform set_config(
    'crm.initial_visit_lead_id',
    created_lead.lead_id::text,
    true
  );

  update public.crm_leads as lead
  set stage = 'Visita agendada',
      visit_scheduled_at = p_visit_scheduled_at,
      visit_executor_id = case
        when lower(trim(coalesce(p_lead_type, ''))) = 'aluguel'
          then normalized_executor_ids[1]
        else null
      end,
      visit_executor_ids = case
        when lower(trim(coalesce(p_lead_type, ''))) = 'aluguel'
          then normalized_executor_ids
        else '{}'::uuid[]
      end,
      assignment_status = 'accepted',
      assignment_available_at = null,
      assignment_deadline_at = null,
      assignment_reminder_sent_at = null,
      updated_at = now()
  where lead.id = created_lead.lead_id;

  delete from public.lead_assignment_attempts as attempt
  where attempt.lead_id = created_lead.lead_id;

  delete from public.crm_notification_outbox as notification
  where notification.kind in ('lead_assignment', 'lead_direct_assignment')
    and notification.payload ->> 'leadId' = created_lead.lead_id::text;

  select coalesce(nullif(profile.full_name, ''), profile.email, 'Usuario')
  into creator_name
  from public.profiles as profile
  where profile.id = auth.uid();

  insert into public.crm_lead_activities(
    lead_id, stage, note, author_id, author_name, scheduled_for
  ) values (
    created_lead.lead_id,
    'Visita agendada',
    nullif(trim(p_notes), ''),
    auth.uid(),
    coalesce(creator_name, 'Usuario'),
    p_visit_scheduled_at
  );

  insert into public.crm_notification_outbox(
    recipient_id, kind, title, body, url, payload
  )
  select
    created_lead.assigned_owner_id,
    'lead_visit_scheduled',
    'Nova visita agendada',
    'Visita com ' || trim(p_name) || ' em '
      || to_char(p_visit_scheduled_at at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || '.',
    '/agenda',
    jsonb_build_object(
      'leadId', created_lead.lead_id,
      'name', trim(p_name),
      'scheduledAt', p_visit_scheduled_at
    )
  where created_lead.assigned_owner_id is not null;

  return query
  select created_lead.lead_id,
         created_lead.assigned_owner_id,
         created_lead.assigned_owner_name;
end;
$$;

revoke all on function public.create_scheduled_visit_lead_with_phones_and_executors(
  text, text, text[], text, text, text, text, text, numeric, text,
  timestamptz, uuid[], uuid, boolean
) from public, anon;
grant execute on function public.create_scheduled_visit_lead_with_phones_and_executors(
  text, text, text[], text, text, text, text, text, numeric, text,
  timestamptz, uuid[], uuid, boolean
) to authenticated;

commit;

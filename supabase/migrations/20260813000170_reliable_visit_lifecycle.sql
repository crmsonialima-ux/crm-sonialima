begin;

-- A visita e um ciclo proprio. Uma atividade administrativa, uma qualificacao
-- ou o simples agendamento nunca podem concluir o compromisso na Agenda.
-- Somente os dois eventos finais explicitamente registrados abaixo alteram o
-- retorno da visita.
create or replace function public.sync_lead_activity_to_agenda()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  normalized_stage text := lower(trim(coalesce(new.stage, '')));
  linked_entry_id uuid;
  recent_stage_event boolean := false;
begin
  if normalized_stage not in ('visita realizada', 'proposta') then
    return new;
  end if;

  -- O RPC da Agenda atualiza diretamente o compromisso escolhido. Seus
  -- gatilhos nao devem tentar adivinhar outro compromisso do mesmo lead.
  if coalesce(current_setting('app.skip_visit_agenda_sync', true), '') = 'on' then
    return new;
  end if;

  select entry.id
  into linked_entry_id
  from public.crm_agenda_entries as entry
  where entry.source_kind = 'lead_visit'
    and entry.source_lead_id = new.lead_id
    -- Uma conclusao nunca e associada a uma visita que ainda nao comecou.
    and entry.scheduled_at <= least(new.created_at, clock_timestamp())
    and (
      entry.feedback_at is null
      or (
        -- A alteracao da etapa e a atividade sao gravadas em duas operacoes
        -- consecutivas pela tela de Leads. Neste caso, a atividade apenas
        -- enriquece o evento que o gatilho de etapa acabou de registrar.
        entry.feedback_at between new.created_at - interval '1 minute'
                              and new.created_at + interval '1 minute'
        and exists (
          select 1
          from jsonb_array_elements(coalesce(entry.feedback_history, '[]'::jsonb)) as history(item)
          where history.item ->> 'source' = 'lead_stage'
            and lower(trim(coalesce(history.item ->> 'stage', ''))) = normalized_stage
            and case
              when coalesce(history.item ->> 'at', '')
                   ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
                then (history.item ->> 'at')::timestamptz
              else null
            end between new.created_at - interval '1 minute'
                    and new.created_at + interval '1 minute'
        )
      )
    )
  order by entry.scheduled_at desc, entry.created_at desc, entry.id desc
  limit 1;

  if linked_entry_id is null then
    return new;
  end if;

  select exists (
    select 1
    from public.crm_agenda_entries as entry,
      lateral jsonb_array_elements(coalesce(entry.feedback_history, '[]'::jsonb)) as history(item)
    where entry.id = linked_entry_id
      and history.item ->> 'source' = 'lead_stage'
      and lower(trim(coalesce(history.item ->> 'stage', ''))) = normalized_stage
      and case
        when coalesce(history.item ->> 'at', '')
             ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
          then (history.item ->> 'at')::timestamptz
        else null
      end between new.created_at - interval '1 minute'
              and new.created_at + interval '1 minute'
  ) into recent_stage_event;

  update public.crm_agenda_entries as entry
  set feedback_at = case
        when recent_stage_event then entry.feedback_at
        else new.created_at
      end,
      feedback_note = coalesce(nullif(trim(new.note), ''), new.stage),
      feedback_by = coalesce(new.author_id, entry.feedback_by),
      feedback_history = case
        when exists (
          select 1
          from jsonb_array_elements(coalesce(entry.feedback_history, '[]'::jsonb)) as history(item)
          where history.item ->> 'activityId' = new.id::text
        ) then coalesce(entry.feedback_history, '[]'::jsonb)
        else coalesce(entry.feedback_history, '[]'::jsonb)
          || jsonb_build_array(jsonb_build_object(
            'at', new.created_at,
            'note', new.note,
            'stage', new.stage,
            'by', new.author_id,
            'source', 'lead_activity',
            'activityId', new.id
          ))
      end,
      updated_at = now()
  where entry.id = linked_entry_id;

  return new;
end;
$$;

revoke all on function public.sync_lead_activity_to_agenda()
  from public, anon, authenticated;

drop trigger if exists crm_lead_activities_sync_to_agenda
  on public.crm_lead_activities;
create trigger crm_lead_activities_sync_to_agenda
after insert on public.crm_lead_activities
for each row execute function public.sync_lead_activity_to_agenda();

-- A protecao tambem cobre uma escrita direta no historico de atividades. Sem
-- ela, um cliente poderia contornar a validacao de crm_leads e ainda acionar os
-- demais gatilhos de feedback com uma atividade final antecipada.
create or replace function public.enforce_reliable_visit_activity_time()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  normalized_stage text := lower(trim(coalesce(new.stage, '')));
  transition_at timestamptz := clock_timestamp();
begin
  if normalized_stage not in ('visita realizada', 'proposta') then
    return new;
  end if;

  if new.created_at > transition_at + interval '1 minute' then
    raise exception 'A data do retorno da visita nao pode estar no futuro.';
  end if;

  if not exists (
    select 1
    from public.crm_agenda_entries as entry
    where entry.source_kind = 'lead_visit'
      and entry.source_lead_id = new.lead_id
      and entry.scheduled_at <= transition_at
      and entry.feedback_at is null
  ) and exists (
    select 1
    from public.crm_agenda_entries as entry
    where entry.source_kind = 'lead_visit'
      and entry.source_lead_id = new.lead_id
      and entry.scheduled_at > transition_at
      and entry.feedback_at is null
  ) and not exists (
    -- Na tela de Leads, a transicao da etapa e gravada imediatamente antes
    -- da atividade. O primeiro gatilho ja concluiu a visita correta; esta
    -- atividade e o texto detalhado do mesmo evento e deve ser aceita.
    select 1
    from public.crm_agenda_entries as entry,
      lateral jsonb_array_elements(coalesce(entry.feedback_history, '[]'::jsonb)) as history(item)
    where entry.source_kind = 'lead_visit'
      and entry.source_lead_id = new.lead_id
      and entry.scheduled_at <= transition_at
      and history.item ->> 'source' = 'lead_stage'
      and lower(trim(coalesce(history.item ->> 'stage', ''))) = normalized_stage
      and case
        when coalesce(history.item ->> 'at', '')
             ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
          then (history.item ->> 'at')::timestamptz
        else null
      end between transition_at - interval '1 minute'
              and transition_at + interval '1 minute'
  ) then
    raise exception 'A visita ainda nao comecou. Aguarde o horario agendado para registrar o resultado.';
  end if;

  return new;
end;
$$;

revoke all on function public.enforce_reliable_visit_activity_time()
  from public, anon, authenticated;

drop trigger if exists crm_lead_activities_enforce_visit_time
  on public.crm_lead_activities;
create trigger crm_lead_activities_enforce_visit_time
before insert on public.crm_lead_activities
for each row execute function public.enforce_reliable_visit_activity_time();

-- Centraliza a abertura e a conclusao do ciclo. Em especial, sobrescreve um
-- visit_completed_at antigo quando a pessoa confirma uma nova visita e impede
-- que uma visita futura seja concluida pela aba Leads.
create or replace function public.enforce_reliable_lead_visit_lifecycle()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  old_stage text := lower(trim(coalesce(old.stage, '')));
  new_stage text := lower(trim(coalesce(new.stage, '')));
  transition_at timestamptz := clock_timestamp();
begin
  if new_stage = 'visita agendada'
     and (
       old_stage is distinct from new_stage
       or old.visit_scheduled_at is distinct from new.visit_scheduled_at
     ) then
    new.visit_completed_at := null;
    new.visit_feedback_at := null;
    new.visit_property_captured := null;
    new.visit_started_notified_at := null;
    new.visit_follow_up_notified_at := null;
    new.visit_feedback_reminder_sent_at := null;
    new.proposal_at := null;
  end if;

  if new_stage = 'visita realizada'
     and old_stage is distinct from new_stage then
    if new.visit_scheduled_at is not null
       and new.visit_scheduled_at > transition_at then
      raise exception 'A visita ainda nao comecou. Aguarde o horario agendado para registra-la como realizada.';
    end if;

    if exists (
      select 1
      from public.crm_agenda_entries as entry
      where entry.source_kind = 'lead_visit'
        and entry.source_lead_id = new.id
        and entry.scheduled_at > transition_at
        and entry.feedback_at is null
    ) and not exists (
      select 1
      from public.crm_agenda_entries as entry
      where entry.source_kind = 'lead_visit'
        and entry.source_lead_id = new.id
        and entry.scheduled_at <= transition_at
        and entry.feedback_at is null
    ) then
      raise exception 'A visita ainda nao comecou. Aguarde o horario agendado para registra-la como realizada.';
    end if;

    -- A transicao atual e a evidencia. Nunca reutiliza a data de uma visita
    -- anterior que permaneceu no registro resumido do lead.
    new.visit_completed_at := transition_at;
    new.visit_feedback_at := transition_at;
  end if;

  if new_stage = 'proposta'
     and old_stage is distinct from new_stage then
    if new.visit_scheduled_at is not null
       and new.visit_scheduled_at > transition_at then
      raise exception 'A visita ainda nao comecou. Aguarde o horario agendado para registrar uma proposta da visita.';
    end if;
    new.proposal_at := transition_at;
  end if;

  return new;
end;
$$;

revoke all on function public.enforce_reliable_lead_visit_lifecycle()
  from public, anon, authenticated;

drop trigger if exists crm_leads_enforce_reliable_visit_lifecycle
  on public.crm_leads;
create trigger crm_leads_enforce_reliable_visit_lifecycle
before update of stage, visit_scheduled_at on public.crm_leads
for each row execute function public.enforce_reliable_lead_visit_lifecycle();

-- A tela de Leads atualiza primeiro o lead e depois grava sua atividade. O
-- gatilho abaixo permite que a Agenda reaja imediatamente, mas apenas quando
-- a propria transicao criou o timestamp final. Um visit_completed_at antigo,
-- preservado de uma visita anterior, nunca e usado como evidencia.
create or replace function public.sync_lead_visit_stage_to_agenda()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  normalized_stage text := lower(trim(coalesce(new.stage, '')));
  event_at timestamptz;
  linked_entry_id uuid;
  event_key text;
begin
  if coalesce(current_setting('app.skip_visit_agenda_sync', true), '') = 'on' then
    return new;
  end if;

  if normalized_stage = 'visita realizada'
     and lower(trim(coalesce(old.stage, ''))) is distinct from normalized_stage
     and new.visit_completed_at is not null
     and new.visit_completed_at is distinct from old.visit_completed_at then
    event_at := new.visit_completed_at;
  elsif normalized_stage = 'proposta'
        and lower(trim(coalesce(old.stage, ''))) is distinct from normalized_stage
        and new.proposal_at is not null
        and new.proposal_at is distinct from old.proposal_at then
    event_at := new.proposal_at;
  else
    return new;
  end if;

  -- Rejeita relogios/timestamps futuros. O evento pode chegar alguns segundos
  -- depois da escrita do navegador, por isso existe uma tolerancia pequena.
  if event_at > clock_timestamp() + interval '1 minute' then
    return new;
  end if;

  select entry.id
  into linked_entry_id
  from public.crm_agenda_entries as entry
  where entry.source_kind = 'lead_visit'
    and entry.source_lead_id = new.id
    and entry.scheduled_at <= event_at
    and entry.feedback_at is null
  order by entry.scheduled_at desc, entry.created_at desc, entry.id desc
  limit 1;

  if linked_entry_id is null then
    return new;
  end if;

  event_key := 'lead-stage:' || new.id::text || ':'
    || normalized_stage || ':' || event_at::text;

  update public.crm_agenda_entries as entry
  set feedback_at = event_at,
      feedback_note = new.stage,
      feedback_by = coalesce(auth.uid(), new.owner_id),
      feedback_history = case
        when exists (
          select 1
          from jsonb_array_elements(coalesce(entry.feedback_history, '[]'::jsonb)) as history(item)
          where history.item ->> 'eventKey' = event_key
        ) then coalesce(entry.feedback_history, '[]'::jsonb)
        else coalesce(entry.feedback_history, '[]'::jsonb)
          || jsonb_build_array(jsonb_build_object(
            'at', event_at,
            'note', new.stage,
            'stage', new.stage,
            'by', coalesce(auth.uid(), new.owner_id),
            'source', 'lead_stage',
            'eventKey', event_key
          ))
      end,
      updated_at = now()
  where entry.id = linked_entry_id;

  return new;
end;
$$;

revoke all on function public.sync_lead_visit_stage_to_agenda()
  from public, anon, authenticated;

drop trigger if exists crm_leads_sync_visit_stage_to_agenda
  on public.crm_leads;
create trigger crm_leads_sync_visit_stage_to_agenda
after update of stage, visit_completed_at, proposal_at on public.crm_leads
for each row execute function public.sync_lead_visit_stage_to_agenda();

-- Quando a conclusao parte da Agenda, o proprio RPC conhece o compromisso
-- exato. Atualiza-lo diretamente evita que uma visita passada conclua uma nova
-- visita futura do mesmo lead.
drop function if exists public.register_agenda_lead_visit_progress(uuid, text, text, boolean);

create function public.register_agenda_lead_visit_progress(
  p_entry_id uuid,
  p_stage text,
  p_note text,
  p_visit_property_captured boolean default null
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  agenda_entry public.crm_agenda_entries;
  lead_record public.crm_leads;
  actor_name text;
  registered_at timestamptz := now();
  normalized_note text := nullif(trim(coalesce(p_note, '')), '');
  activity_note text;
  activity_id uuid;
  preserved_stage boolean;
begin
  if p_stage not in ('Visita realizada', 'Proposta') then
    raise exception 'Selecione Visita realizada ou Proposta.';
  end if;
  if normalized_note is null then
    raise exception 'Descreva o que aconteceu na visita.';
  end if;
  if p_stage = 'Visita realizada' and p_visit_property_captured is null then
    raise exception 'Informe se algum imovel do cliente foi captado durante a visita.';
  end if;

  select * into agenda_entry
  from public.crm_agenda_entries
  where id = p_entry_id
  for update;

  if not found then
    raise exception 'Compromisso nao encontrado.';
  end if;
  if agenda_entry.source_kind is distinct from 'lead_visit'
     or agenda_entry.source_lead_id is null then
    raise exception 'Este compromisso nao esta vinculado a uma visita de lead.';
  end if;
  if agenda_entry.scheduled_at > registered_at then
    raise exception 'A visita ainda nao comecou. Aguarde o horario agendado para registrar o resultado.';
  end if;
  if not public.is_admin()
     and agenda_entry.target_user_id is distinct from auth.uid()
     and not exists (
       select 1
       from public.crm_agenda_entry_participants as participant
       where participant.entry_id = agenda_entry.id
         and participant.user_id = auth.uid()
     ) then
    raise exception 'Somente os envolvidos na visita podem registrar o retorno.';
  end if;

  select * into lead_record
  from public.crm_leads
  where id = agenda_entry.source_lead_id
  for update;

  if not found then
    raise exception 'Lead vinculado nao encontrado.';
  end if;

  -- Impede os gatilhos genericos de escolherem outra visita desta pessoa. O
  -- valor e local a transacao PostgREST que executa este RPC.
  perform set_config('app.skip_visit_agenda_sync', 'on', true);

  preserved_stage := lower(trim(coalesce(lead_record.stage, ''))) in (
    'proposta', 'nao teve interesse', 'não teve interesse', 'standby'
  );

  update public.crm_leads
  set stage = case
        when p_stage = 'Visita realizada' and preserved_stage then lead_record.stage
        else p_stage
      end,
      assignment_deadline_at = null,
      visit_completed_at = registered_at,
      visit_feedback_at = registered_at,
      visit_property_captured = case
        when p_stage = 'Visita realizada' then p_visit_property_captured
        else visit_property_captured
      end,
      proposal_at = case
        when p_stage = 'Proposta' then registered_at
        else proposal_at
      end,
      updated_at = registered_at
  where id = lead_record.id;

  select coalesce(nullif(trim(profile.full_name), ''), profile.email, 'Usuario')
  into actor_name
  from public.profiles as profile
  where profile.id = auth.uid();

  activity_note := normalized_note;
  if p_stage = 'Visita realizada' then
    activity_note := activity_note || E'\nImovel do cliente captado durante a visita: '
      || case when p_visit_property_captured then 'Sim' else 'Nao' end || '.';
  end if;

  insert into public.crm_lead_activities(
    lead_id, stage, note, author_id, author_name
  ) values (
    lead_record.id,
    p_stage,
    activity_note,
    auth.uid(),
    coalesce(actor_name, 'Usuario')
  )
  returning id into activity_id;

  update public.crm_agenda_entries
  set feedback_at = registered_at,
      feedback_note = normalized_note,
      feedback_by = auth.uid(),
      feedback_history = coalesce(feedback_history, '[]'::jsonb)
        || jsonb_build_array(jsonb_build_object(
          'at', registered_at,
          'note', normalized_note,
          'stage', p_stage,
          'by', auth.uid(),
          'source', 'agenda',
          'activityId', activity_id
        )),
      updated_at = registered_at
  where id = agenda_entry.id;
end;
$$;

revoke all on function public.register_agenda_lead_visit_progress(uuid, text, text, boolean)
  from public, anon;
grant execute on function public.register_agenda_lead_visit_progress(uuid, text, text, boolean)
  to authenticated;

-- -------------------------------------------------------------------------
-- Saneamento dos dados atuais
-- -------------------------------------------------------------------------
-- Cada atividade final explicita e associada a ultima visita que ja havia
-- comecado naquele instante. Assim uma atividade antiga nunca cai sobre um
-- reagendamento futuro.
create temporary table crm_visit_explicit_final_events (
  entry_id uuid not null,
  event_at timestamptz not null,
  note text,
  stage text not null,
  actor_id uuid,
  source text not null,
  activity_id uuid
) on commit drop;

-- Preserva conclusoes antigas registradas diretamente pela Agenda (versoes
-- anteriores do RPC ainda nao gravavam source/activityId no JSON).
insert into crm_visit_explicit_final_events(
  entry_id, event_at, note, stage, actor_id, source, activity_id
)
select
  entry.id,
  (history.item ->> 'at')::timestamptz,
  nullif(history.item ->> 'note', ''),
  history.item ->> 'stage',
  case
    when coalesce(history.item ->> 'by', '')
         ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
      then (history.item ->> 'by')::uuid
    else null
  end,
  coalesce(nullif(history.item ->> 'source', ''), 'agenda_legacy'),
  null
from public.crm_agenda_entries as entry
cross join lateral jsonb_array_elements(coalesce(entry.feedback_history, '[]'::jsonb)) as history(item)
where entry.source_kind = 'lead_visit'
  and lower(trim(coalesce(history.item ->> 'stage', ''))) in ('visita realizada', 'proposta')
  and coalesce(history.item ->> 'source', '') not in (
    'lead', 'lead_activity', 'lead_stage', 'lead_backfill'
  )
  and coalesce(history.item ->> 'at', '')
      ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
  and (history.item ->> 'at')::timestamptz >= entry.scheduled_at
  and (history.item ->> 'at')::timestamptz <= now() + interval '1 minute';

-- Reconstrucao deterministica dos eventos vindos da aba Leads.
insert into crm_visit_explicit_final_events(
  entry_id, event_at, note, stage, actor_id, source, activity_id
)
select
  matched_entry.id,
  activity.created_at,
  nullif(trim(activity.note), ''),
  activity.stage,
  activity.author_id,
  'lead_activity',
  activity.id
from public.crm_lead_activities as activity
cross join lateral (
  select entry.id
  from public.crm_agenda_entries as entry
  where entry.source_kind = 'lead_visit'
    and entry.source_lead_id = activity.lead_id
    and entry.scheduled_at <= activity.created_at
  order by entry.scheduled_at desc, entry.created_at desc, entry.id desc
  limit 1
) as matched_entry
where lower(trim(coalesce(activity.stage, ''))) in ('visita realizada', 'proposta');

-- Remove somente os eventos de sincronizacoes antigas. Os eventos legitimos
-- da Agenda e demais itens de auditoria permanecem; os finais da aba Leads sao
-- recolocados abaixo a partir da tabela imutavel crm_lead_activities.
update public.crm_agenda_entries as entry
set feedback_history = coalesce((
      select jsonb_agg(history.item order by history.ordinality)
      from jsonb_array_elements(coalesce(entry.feedback_history, '[]'::jsonb))
        with ordinality as history(item, ordinality)
      where coalesce(history.item ->> 'source', '') not in (
        'lead', 'lead_activity', 'lead_stage', 'lead_backfill'
      )
    ), '[]'::jsonb),
    updated_at = now()
where entry.source_kind = 'lead_visit';

with rebuilt as (
  select
    final_event.entry_id,
    jsonb_agg(
      jsonb_build_object(
        'at', final_event.event_at,
        'note', final_event.note,
        'stage', final_event.stage,
        'by', final_event.actor_id,
        'source', final_event.source,
        'activityId', final_event.activity_id
      )
      order by final_event.event_at, final_event.activity_id
    ) filter (where final_event.source = 'lead_activity') as activity_history
  from crm_visit_explicit_final_events as final_event
  group by final_event.entry_id
)
update public.crm_agenda_entries as entry
set feedback_history = coalesce(entry.feedback_history, '[]'::jsonb)
      || coalesce(rebuilt.activity_history, '[]'::jsonb),
    updated_at = now()
from rebuilt
where entry.id = rebuilt.entry_id
  and rebuilt.activity_history is not null;

-- feedback_* passa a representar exclusivamente o ultimo evento final
-- explicito daquele compromisso.
with latest_final as (
  select distinct on (final_event.entry_id)
    final_event.entry_id,
    final_event.event_at,
    final_event.note,
    final_event.stage,
    final_event.actor_id
  from crm_visit_explicit_final_events as final_event
  order by final_event.entry_id, final_event.event_at desc,
    final_event.activity_id desc nulls last
)
update public.crm_agenda_entries as entry
set feedback_at = latest_final.event_at,
    feedback_note = coalesce(latest_final.note, latest_final.stage),
    feedback_by = latest_final.actor_id,
    updated_at = now()
from latest_final
where entry.id = latest_final.entry_id;

update public.crm_agenda_entries as entry
set feedback_at = null,
    feedback_note = null,
    feedback_by = null,
    updated_at = now()
where entry.source_kind = 'lead_visit'
  and not exists (
    select 1
    from crm_visit_explicit_final_events as final_event
    where final_event.entry_id = entry.id
  );

-- Os campos resumidos do lead representam o ciclo atual. Ao existir um novo
-- agendamento posterior a uma conclusao antiga, o timestamp antigo nao pode
-- voltar a concluir automaticamente a nova visita. O historico permanente
-- continua preservado em crm_lead_activities.
update public.crm_leads as lead
set visit_completed_at = null,
    visit_feedback_at = null,
    proposal_at = null,
    updated_at = now()
where lower(trim(coalesce(lead.stage, ''))) = 'visita agendada'
  and lead.visit_scheduled_at is not null
  and lead.visit_completed_at is not null
  and lead.visit_completed_at < lead.visit_scheduled_at;

-- Corrige leads que permaneceram em Visita realizada apesar de possuirem um
-- novo agendamento futuro sem nenhum evento final posterior a esse horario.
update public.crm_leads as lead
set stage = 'Visita agendada',
    visit_completed_at = null,
    visit_feedback_at = null,
    proposal_at = null,
    updated_at = now()
where lower(trim(coalesce(lead.stage, ''))) = 'visita realizada'
  and lead.visit_scheduled_at > now()
  and not exists (
    select 1
    from public.crm_lead_activities as activity
    where activity.lead_id = lead.id
      and lower(trim(coalesce(activity.stage, ''))) in ('visita realizada', 'proposta')
      and activity.created_at >= lead.visit_scheduled_at
  );

-- O mesmo reparo vale quando a falsa conclusao esta no passado: se o ciclo
-- atual do lead aponta para uma agenda sem qualquer evento final explicito,
-- restaura o estado agendado. Uma conclusao antiga real de outra visita fica
-- preservada em sua propria entrada e em crm_lead_activities.
update public.crm_leads as lead
set stage = 'Visita agendada',
    visit_completed_at = null,
    visit_feedback_at = null,
    proposal_at = null,
    updated_at = now()
where lower(trim(coalesce(lead.stage, ''))) in ('visita realizada', 'proposta')
  and lead.visit_scheduled_at is not null
  and exists (
    select 1
    from public.crm_agenda_entries as current_entry
    where current_entry.source_kind = 'lead_visit'
      and current_entry.source_lead_id = lead.id
      and current_entry.scheduled_at = lead.visit_scheduled_at
      and current_entry.feedback_at is null
  )
  and not exists (
    select 1
    from public.crm_lead_activities as activity
    where activity.lead_id = lead.id
      and lower(trim(coalesce(activity.stage, ''))) in ('visita realizada', 'proposta')
      and activity.created_at >= lead.visit_scheduled_at
  );

comment on function public.sync_lead_activity_to_agenda() is
  'Sincroniza apenas eventos finais explicitos e nunca conclui uma visita futura.';
comment on function public.sync_lead_visit_stage_to_agenda() is
  'Usa somente timestamp final novo da transicao; ignora conclusoes antigas de visitas anteriores.';

commit;

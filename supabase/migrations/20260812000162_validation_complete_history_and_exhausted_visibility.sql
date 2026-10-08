begin;

-- O histórico permanente deve incluir também ações do Allyson e rotinas do
-- sistema. Antes, a função saía sem registrar justamente nesses dois casos.
do $$
declare
  definition text;
begin
  select pg_get_functiondef('public.persist_crm_user_action_history()'::regprocedure)
  into definition;

  definition := replace(
    definition,
    'if current_actor_id is null or public.is_allyson_admin() then',
    'if false then'
  );
  definition := replace(
    definition,
    'actor_label := coalesce(actor_label, current_actor_id::text);',
    $replacement$actor_label := coalesce(
      actor_label,
      case when current_actor_id is null then 'Sistema' else current_actor_id::text end
    );$replacement$
  );

  if position('if false then' in definition) = 0
     or position($needle$then 'Sistema'$needle$ in definition) = 0 then
    raise exception 'Não foi possível ampliar o histórico permanente com segurança.';
  end if;
  execute definition;
end;
$$;

create or replace function public.search_crm_user_action_history(
  p_query text default null,
  p_area text default null,
  p_limit integer default 100,
  p_offset integer default 0
)
returns setof public.crm_user_action_history
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  normalized_query text := nullif(trim(p_query), '');
  normalized_area text := nullif(trim(p_area), '');
begin
  if not public.is_allyson_admin() then
    raise exception 'Somente Allyson pode consultar o histórico permanente.';
  end if;
  return query
  select history.*
  from public.crm_user_action_history as history
  where (normalized_area is null or history.area = normalized_area)
    and (
      normalized_query is null
      or history.actor_name ilike '%' || normalized_query || '%'
      or coalesce(history.actor_email, '') ilike '%' || normalized_query || '%'
      or coalesce(history.entity_label, '') ilike '%' || normalized_query || '%'
      or coalesce(history.entity_id, '') ilike '%' || normalized_query || '%'
      or history.source_table ilike '%' || normalized_query || '%'
      or history.before_data::text ilike '%' || normalized_query || '%'
      or history.after_data::text ilike '%' || normalized_query || '%'
      or history.changes::text ilike '%' || normalized_query || '%'
    )
  order by history.occurred_at desc, history.id desc
  limit least(greatest(coalesce(p_limit, 100), 1), 2000)
  offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

-- Preserva na própria trilha permanente todas as passagens já existentes da
-- esteira. Não duplica registros caso a migration seja reaplicada.
insert into public.crm_user_action_history (
  actor_id, actor_name, actor_email, operation, area, source_table,
  entity_id, entity_label, before_data, after_data, changes, occurred_at
)
select
  null,
  'Sistema',
  null,
  'insert',
  'lead',
  'lead_assignment_attempts',
  attempt.id::text,
  coalesce(lead.name, attempt.lead_id::text) || ' → '
    || coalesce(nullif(profile.full_name, ''), profile.email, attempt.broker_id::text),
  '{}'::jsonb,
  jsonb_build_object(
    'lead_id', attempt.lead_id,
    'lead_name', lead.name,
    'broker_id', attempt.broker_id,
    'broker_name', coalesce(nullif(profile.full_name, ''), profile.email),
    'attempt_number', attempt.attempt_number,
    'run_number', coalesce(attempt.run_number, 1),
    'round_number', coalesce(attempt.round_number, 1),
    'notified_at', attempt.notified_at,
    'deadline_at', attempt.deadline_at,
    'accepted_at', attempt.accepted_at,
    'expired_at', attempt.expired_at
  ),
  '{}'::jsonb,
  attempt.notified_at
from public.lead_assignment_attempts as attempt
left join public.crm_leads as lead on lead.id = attempt.lead_id
left join public.profiles as profile on profile.id = attempt.broker_id
where not exists (
  select 1 from public.crm_user_action_history as history
  where history.source_table = 'lead_assignment_attempts'
    and history.entity_id = attempt.id::text
    and history.operation = 'insert'
);

-- O painel recebe a execução e a rodada, evitando uma lista ambígua de
-- "tentativa 1, 2, 3" sem indicar por qual ciclo o lead passou.
do $$
declare
  definition text;
begin
  select pg_get_functiondef('public.get_validation_audit(uuid,integer)'::regprocedure)
  into definition;
  if position('attempt.run_number' in definition) = 0 then
    definition := replace(
      definition,
      'attempt.attempt_number,',
      'attempt.attempt_number, attempt.run_number, attempt.round_number,'
    );
  end if;
  execute definition;
end;
$$;

-- Depois de duas rodadas, o lead ainda precisa manter owner_id por integridade
-- referencial, mas deixa de ser visível para a carteira desse antigo corretor.
-- Enquanto estiver esgotado, somente Allyson consegue vê-lo e reiniciá-lo.
drop policy if exists "Admins read every lead; brokers read their own" on public.crm_leads;
create policy "Only Allyson sees exhausted leads; team sees active own leads"
on public.crm_leads for select to authenticated
using (
  public.is_allyson_admin()
  or (
    assignment_status <> 'exhausted'
    and (public.is_admin() or owner_id = auth.uid())
  )
);

commit;

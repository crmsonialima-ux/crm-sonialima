begin;

create or replace function public.normalize_lead_assignment_notification_schedule()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  linked_lead_id uuid;
  lead_available_at timestamptz;
  lead_deadline_at timestamptz;
  lead_run_number integer;
begin
  if new.kind is distinct from 'lead_assignment' then return new; end if;

  -- Liberacao manual do Allyson e uma excecao deliberada ao horario da esteira.
  if coalesce((new.payload ->> 'manualRelease')::boolean, false) then
    return new;
  end if;

  begin
    linked_lead_id := (new.payload ->> 'leadId')::uuid;
  exception when invalid_text_representation then return new;
  end;

  select lead.assignment_available_at, lead.assignment_deadline_at,
         lead.assignment_run_number
  into lead_available_at, lead_deadline_at, lead_run_number
  from public.crm_leads lead where lead.id = linked_lead_id;

  new.available_at := public.crm_next_lead_queue_moment(
    coalesce(lead_available_at, new.available_at, now())
  );
  if lead_deadline_at is not null then
    new.payload := jsonb_set(coalesce(new.payload, '{}'::jsonb),
      '{availableAt}', to_jsonb(new.available_at), true);
    new.payload := jsonb_set(new.payload,
      '{deadlineAt}', to_jsonb(lead_deadline_at), true);
    new.payload := jsonb_set(new.payload,
      '{runNumber}', to_jsonb(lead_run_number), true);
  end if;
  return new;
end;
$$;

create or replace function public.allyson_release_scheduled_lead(p_lead_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  lead_row public.crm_leads%rowtype;
  target_deadline timestamptz := now() + interval '20 minutes';
  actor_name text;
begin
  if not public.is_allyson_admin() then
    raise exception 'Apenas Allyson pode antecipar leads programados.';
  end if;

  select lead.* into lead_row from public.crm_leads lead
  where lead.id = p_lead_id for update;
  if not found then raise exception 'Lead nao encontrado.'; end if;
  if lead_row.assignment_available_at is null or lead_row.assignment_available_at <= now() then
    raise exception 'O lead nao esta programado para o futuro.';
  end if;

  select coalesce(nullif(profile.full_name, ''), profile.email)
  into actor_name from public.profiles profile where profile.id = auth.uid();

  update public.crm_leads
  set assignment_available_at = now(), assignment_deadline_at = target_deadline
  where id = p_lead_id;

  insert into public.crm_lead_activities (lead_id, stage, note, author_id, author_name)
  values (p_lead_id, lead_row.stage,
    'Liberou antecipadamente a distribuicao do lead programado.',
    auth.uid(), coalesce(actor_name, 'Allyson'));

  update public.lead_assignment_attempts
  set notified_at = now(), deadline_at = target_deadline
  where lead_id = p_lead_id and attempt_number = 1
    and run_number = lead_row.assignment_run_number;

  update public.crm_notification_outbox
  set available_at = now(),
      payload = jsonb_set(
        jsonb_set(
          jsonb_set(coalesce(payload, '{}'::jsonb),
            '{availableAt}', to_jsonb(now()::timestamptz), true),
          '{deadlineAt}', to_jsonb(target_deadline), true),
        '{manualRelease}', 'true'::jsonb, true)
  where kind = 'lead_assignment'
    and payload ->> 'leadId' = p_lead_id::text;
end;
$$;

revoke all on function public.allyson_release_scheduled_lead(uuid)
  from public, anon, authenticated;
grant execute on function public.allyson_release_scheduled_lead(uuid) to authenticated;

-- O destinatario pode aceitar uma liberacao manual mesmo fora das 09h-18h.
do $$
declare definition text; patched text;
begin
  select pg_get_functiondef('public.accept_lead_assignment(uuid)'::regprocedure)
  into definition;
  patched := replace(definition,
    'and public.crm_is_lead_queue_hours(now())',
    'and (public.crm_is_lead_queue_hours(now()) or exists (
      select 1 from public.crm_notification_outbox manual_notice
      where manual_notice.kind = ''lead_assignment''
        and manual_notice.recipient_id = auth.uid()
        and manual_notice.payload ->> ''leadId'' = lead.id::text
        and coalesce((manual_notice.payload ->> ''manualRelease'')::boolean, false)
    ))');
  if patched = definition then
    raise exception 'Validacao de horario do aceite nao encontrada.';
  end if;
  execute patched;
end;
$$;

-- Corrige liberacoes feitas hoje que foram normalizadas de volta para as 09h.
with released as (
  select distinct activity.lead_id
  from public.crm_lead_activities activity
  where activity.note = 'Liberou antecipadamente a distribuicao do lead programado.'
    and activity.created_at >= now() - interval '24 hours'
), repaired as (
  update public.crm_leads lead
  set assignment_available_at = now(),
      assignment_deadline_at = now() + interval '20 minutes',
      updated_at = now()
  from released
  where lead.id = released.lead_id
    and lead.assignment_status = 'pending'
  returning lead.id, lead.owner_id, lead.assignment_deadline_at
)
update public.crm_notification_outbox notification
set available_at = now(),
    payload = jsonb_set(
      jsonb_set(
        jsonb_set(coalesce(notification.payload, '{}'::jsonb),
          '{availableAt}', to_jsonb(now()::timestamptz), true),
        '{deadlineAt}', to_jsonb(repaired.assignment_deadline_at), true),
      '{manualRelease}', 'true'::jsonb, true)
from repaired
where notification.kind = 'lead_assignment'
  and notification.recipient_id = repaired.owner_id
  and notification.payload ->> 'leadId' = repaired.id::text;

commit;

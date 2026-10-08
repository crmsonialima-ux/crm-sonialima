-- Espelha cada visita agendada de um lead na Agenda compartilhada.
-- Reagendamentos geram um novo compromisso e preservam os horarios anteriores.

alter table public.crm_agenda_entries
  add column if not exists source_kind text,
  add column if not exists source_lead_id uuid;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'crm_agenda_entries_source_lead_id_fkey'
      and conrelid = 'public.crm_agenda_entries'::regclass
  ) then
    alter table public.crm_agenda_entries
      add constraint crm_agenda_entries_source_lead_id_fkey
      foreign key (source_lead_id)
      references public.crm_leads(id)
      on delete set null;
  end if;
end;
$$;

create index if not exists crm_agenda_entries_source_lead_idx
  on public.crm_agenda_entries(source_lead_id)
  where source_kind = 'lead_visit';

-- Um mesmo lead no mesmo horario representa um unico compromisso. Isso torna
-- a automacao segura contra repeticoes, sem impedir reagendamentos para outro horario.
create unique index if not exists crm_agenda_entries_lead_visit_unique_idx
  on public.crm_agenda_entries(source_lead_id, scheduled_at)
  where source_kind = 'lead_visit' and source_lead_id is not null;

create or replace function public.sync_lead_visit_to_agenda()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_id uuid;
  visit_description text;
  should_create boolean := false;
begin
  -- Se o corretor responsavel mudar, os compromissos futuros daquele lead
  -- acompanham o novo responsavel. Os compromissos passados ficam intactos.
  if tg_op = 'UPDATE'
     and old.owner_id is distinct from new.owner_id then
    update public.crm_agenda_entries
    set target_user_id = new.owner_id,
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
    category,
    scheduled_at,
    observation,
    target_user_id,
    created_by,
    source_kind,
    source_lead_id
  )
  values (
    'observacao',
    new.visit_scheduled_at,
    visit_description,
    new.owner_id,
    actor_id,
    'lead_visit',
    new.id
  )
  on conflict do nothing;

  return new;
end;
$$;

drop trigger if exists crm_leads_sync_visit_to_agenda on public.crm_leads;
create trigger crm_leads_sync_visit_to_agenda
after insert or update of stage, visit_scheduled_at, owner_id
on public.crm_leads
for each row
execute procedure public.sync_lead_visit_to_agenda();

-- Recupera todo o historico de agendamentos e reagendamentos que ja existe.
insert into public.crm_agenda_entries (
  category,
  scheduled_at,
  observation,
  target_user_id,
  created_by,
  source_kind,
  source_lead_id
)
select
  'observacao'::public.agenda_category,
  activity.scheduled_for,
  case
    when activity.stage = 'Visita reagendada' then 'Visita reagendada — '
    else 'Visita agendada — '
  end
    || coalesce(nullif(trim(lead_record.name), ''), 'Cliente sem nome')
    || case
      when nullif(trim(coalesce(lead_record.property_interest, '')), '') is not null
        then E'\nImóvel: ' || trim(lead_record.property_interest)
      else ''
    end,
  lead_record.owner_id,
  coalesce(activity.author_id, lead_record.created_by, lead_record.owner_id),
  'lead_visit',
  lead_record.id
from public.crm_lead_activities activity
join public.crm_leads lead_record on lead_record.id = activity.lead_id
where activity.stage in ('Visita agendada', 'Visita reagendada')
  and activity.scheduled_for is not null
on conflict do nothing;

-- Cobre eventuais visitas atuais antigas que nao possuam atividade historica.
insert into public.crm_agenda_entries (
  category,
  scheduled_at,
  observation,
  target_user_id,
  created_by,
  source_kind,
  source_lead_id
)
select
  'observacao'::public.agenda_category,
  lead_record.visit_scheduled_at,
  'Visita agendada — '
    || coalesce(nullif(trim(lead_record.name), ''), 'Cliente sem nome')
    || case
      when nullif(trim(coalesce(lead_record.property_interest, '')), '') is not null
        then E'\nImóvel: ' || trim(lead_record.property_interest)
      else ''
    end,
  lead_record.owner_id,
  coalesce(lead_record.created_by, lead_record.owner_id),
  'lead_visit',
  lead_record.id
from public.crm_leads lead_record
where lead_record.visit_scheduled_at is not null
on conflict do nothing;

-- Impede compromissos simultaneos ou separados por ate 20 minutos para a
-- mesma pessoa. A regra fica na tabela para cobrir Agenda, Leads e automacoes.

begin;

create extension if not exists btree_gist with schema extensions;

create index if not exists crm_agenda_entries_target_scheduled_idx
  on public.crm_agenda_entries(target_user_id, scheduled_at);

-- O PostgreSQL considera a soma de timestamptz com interval como STABLE por
-- causa de fusos/DST. Para a janela fixa de vinte minutos usada pela agenda,
-- este wrapper imutavel permite que a garantia seja mantida por um indice GiST.
create or replace function public.agenda_twenty_minute_window(value timestamptz)
returns tstzrange
language sql
immutable
strict
parallel safe
as $$
  select tstzrange(value, value + interval '20 minutes', '[]');
$$;

create or replace function public.enforce_agenda_twenty_minute_spacing()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  conflicting_entry record;
begin
  if tg_op = 'UPDATE'
     and new.target_user_id is not distinct from old.target_user_id
     and new.scheduled_at is not distinct from old.scheduled_at then
    return new;
  end if;

  -- O indice unico de visitas ja torna esta repeticao idempotente. Deixamos o
  -- INSERT prosseguir para que ON CONFLICT DO NOTHING cumpra essa funcao.
  if tg_op = 'INSERT'
     and new.source_kind = 'lead_visit'
     and new.source_lead_id is not null
     and exists (
       select 1
       from public.crm_agenda_entries as existing_visit
       where existing_visit.source_kind = 'lead_visit'
         and existing_visit.source_lead_id = new.source_lead_id
         and existing_visit.scheduled_at = new.scheduled_at
     ) then
    return new;
  end if;

  -- Serializa inclusoes concorrentes para o mesmo corretor. Assim, dois
  -- dispositivos nao conseguem gravar horarios conflitantes ao mesmo tempo.
  perform pg_advisory_xact_lock(
    hashtext('agenda-spacing:' || new.target_user_id::text)
  );

  select agenda.id, agenda.scheduled_at
  into conflicting_entry
  from public.crm_agenda_entries as agenda
  where agenda.target_user_id = new.target_user_id
    and agenda.id <> new.id
    and agenda.scheduled_at between
      new.scheduled_at - interval '20 minutes'
      and new.scheduled_at + interval '20 minutes'
  order by abs(extract(epoch from (agenda.scheduled_at - new.scheduled_at)))
  limit 1;

  if found then
    raise exception using
      errcode = '23P01',
      message = 'Ja existe um compromisso para esta pessoa em '
        || to_char(
          conflicting_entry.scheduled_at at time zone 'America/Sao_Paulo',
          'DD/MM/YYYY HH24:MI'
        )
        || '. Escolha um horario com mais de 20 minutos de intervalo.',
      detail = 'Conflito com o compromisso ' || conflicting_entry.id::text || '.';
  end if;

  return new;
end;
$$;

revoke all on function public.enforce_agenda_twenty_minute_spacing()
  from public, anon, authenticated;

drop trigger if exists crm_agenda_entries_twenty_minute_spacing
  on public.crm_agenda_entries;
create trigger crm_agenda_entries_twenty_minute_spacing
before insert or update of target_user_id, scheduled_at
on public.crm_agenda_entries
for each row
execute function public.enforce_agenda_twenty_minute_spacing();

-- O trigger fornece a mensagem amigavel. A exclusao GiST e a garantia final
-- contra duas gravacoes concorrentes iniciadas exatamente ao mesmo tempo.
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.crm_agenda_entries'::regclass
      and conname = 'crm_agenda_entries_twenty_minute_spacing_excl'
  ) then
    alter table public.crm_agenda_entries
      add constraint crm_agenda_entries_twenty_minute_spacing_excl
      exclude using gist (
        target_user_id with =,
        public.agenda_twenty_minute_window(scheduled_at) with &&
      );
  end if;
end;
$$;

commit;

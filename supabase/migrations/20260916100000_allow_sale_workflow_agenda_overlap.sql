-- Entregas e transferencias sao eventos obrigatorios; nao podem ser perdidos
-- porque o responsavel ja possui outro compromisso no mesmo horario.
begin;

drop trigger if exists crm_agenda_entries_twenty_minute_spacing on public.crm_agenda_entries;
create trigger crm_agenda_entries_twenty_minute_spacing
before insert or update of target_user_id, scheduled_at on public.crm_agenda_entries
for each row when (
  new.source_kind is distinct from 'sale_delivery'
  and new.source_kind is distinct from 'sale_transfer'
  and new.source_kind is distinct from 'sale_followup'
)
execute function public.enforce_agenda_twenty_minute_spacing();

alter table public.crm_agenda_entries
  drop constraint if exists crm_agenda_entries_twenty_minute_spacing_excl;
alter table public.crm_agenda_entries
  add constraint crm_agenda_entries_twenty_minute_spacing_excl
  exclude using gist (
    target_user_id with =,
    public.agenda_twenty_minute_window(scheduled_at) with &&
  ) where (
    source_kind is distinct from 'sale_delivery'
    and source_kind is distinct from 'sale_transfer'
    and source_kind is distinct from 'sale_followup'
  );

commit;

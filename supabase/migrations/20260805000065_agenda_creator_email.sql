-- Mantem na propria Agenda o e-mail de quem criou o compromisso.
-- Isso permite identificar o solicitante sem liberar a tabela completa de perfis.

alter table public.crm_agenda_entries
  add column if not exists created_by_email text;

update public.crm_agenda_entries as agenda
set created_by_email = lower(profile.email)
from public.profiles as profile
where profile.id = agenda.created_by
  and agenda.created_by_email is distinct from lower(profile.email);

create or replace function public.set_agenda_creator_email()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  select lower(profile.email)
  into new.created_by_email
  from public.profiles as profile
  where profile.id = new.created_by;

  if nullif(trim(coalesce(new.created_by_email, '')), '') is null then
    new.created_by_email := 'nao-identificado';
  end if;

  return new;
end;
$$;

drop trigger if exists crm_agenda_entries_set_creator_email
  on public.crm_agenda_entries;

create trigger crm_agenda_entries_set_creator_email
before insert or update of created_by
on public.crm_agenda_entries
for each row
execute procedure public.set_agenda_creator_email();

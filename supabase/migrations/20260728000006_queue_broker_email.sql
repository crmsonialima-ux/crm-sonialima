-- A fila exibe o e-mail do corretor sem depender da leitura da tabela profiles.
alter table public.lead_distribution_queue
  add column if not exists broker_email text not null default '';

update public.lead_distribution_queue as queue
set broker_email = profiles.email
from public.profiles as profiles
where profiles.id = queue.broker_id;

create or replace function public.sync_queue_broker_email()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.lead_distribution_queue
  set broker_email = coalesce(new.email, '')
  where broker_id = new.id;
  return new;
end;
$$;

drop trigger if exists profiles_sync_queue_broker_email on public.profiles;
create trigger profiles_sync_queue_broker_email
  after update of email on public.profiles
  for each row execute procedure public.sync_queue_broker_email();

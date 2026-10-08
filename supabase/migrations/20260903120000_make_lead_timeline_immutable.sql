begin;

create or replace function public.prevent_lead_timeline_mutation()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  raise exception 'A linha do tempo permanente dos leads não pode ser alterada nem apagada.';
end;
$$;

drop trigger if exists crm_lead_timeline_is_immutable
  on public.crm_lead_timeline_events;
create trigger crm_lead_timeline_is_immutable
before update or delete on public.crm_lead_timeline_events
for each row execute function public.prevent_lead_timeline_mutation();

revoke all on function public.prevent_lead_timeline_mutation()
  from public, anon, authenticated;
revoke update, delete, truncate on public.crm_lead_timeline_events
  from public, anon, authenticated, service_role;

comment on table public.crm_lead_timeline_events is
  'Linha do tempo imutável dos leads. Eventos nunca são atualizados ou apagados, mesmo após transferência ou exclusão do lead.';

commit;

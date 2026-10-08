begin;

create or replace function public.guard_qualification_activities()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if (old.stage like 'Qualificacao%' or old.stage = 'Lead aceito' or old.stage = 'Qualificacao expirada') and not public.is_allyson_admin() then
    raise exception 'Apenas a gestao pode editar ou excluir registros de qualificacao.';
  end if;
  return old;
end;
$$;

drop trigger if exists crm_lead_activities_guard_qualification on public.crm_lead_activities;
create trigger crm_lead_activities_guard_qualification
before update or delete on public.crm_lead_activities
for each row
execute function public.guard_qualification_activities();

commit;

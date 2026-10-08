begin;

create or replace function public.prevent_pending_qualification_stage_change()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if old.post_acceptance_qualification_deadline_at is not null
     and old.post_acceptance_qualification_completed_at is null
     and old.post_acceptance_qualification_expired_at is null
     and new.post_acceptance_qualification_completed_at is null
     and new.post_acceptance_qualification_expired_at is null
     and new.stage is distinct from old.stage
     and new.stage <> 'Em atendimento' then
    raise exception 'Conclua a qualificacao obrigatoria antes de alterar a etapa do lead.'
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

drop trigger if exists crm_leads_lock_pending_qualification_stage on public.crm_leads;
create trigger crm_leads_lock_pending_qualification_stage
before update of stage, post_acceptance_qualification_completed_at, post_acceptance_qualification_expired_at
on public.crm_leads
for each row execute function public.prevent_pending_qualification_stage_change();

commit;

begin;

-- Leads marked as "Corretor" are relationship records, not property seekers.
-- Cancel any outstanding suggestion while retaining its row for audit history.
create or replace function public.clear_inactive_matches_on_stage_change()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  norm_new text := public.crm_normalize_property_match_text(new.stage);
begin
  if norm_new in ('comprou', 'telefone nao existe', 'telefone nÃ£o existe', 'corretor') then
    update public.crm_property_match_notifications
    set dismissed_at = now()
    where lead_id = new.id
      and dismissed_at is null
      and offer_started_at is null;
  end if;
  return new;
end;
$$;

commit;

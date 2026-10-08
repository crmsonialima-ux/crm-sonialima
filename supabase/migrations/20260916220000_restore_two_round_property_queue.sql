begin;

-- A timeout must pass through both queue rounds before it can wait for Allyson.
-- The previous wrapper exhausted every pending lead on its first timeout.
create or replace function public.process_expired_lead_assignments()
returns void
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
begin
  perform public.process_expired_lead_qualifications();
  perform public.process_expired_lead_assignments_before_integrity();
end;
$$;

-- A queue lead normally skips the captador. When the captador is the only
-- selected and eligible broker for that property, it must remain with that
-- broker instead of being exhausted immediately. Apply this fallback in both
-- rounds of the timeout processor.
do $$
declare
  definition text;
  excluded_captador_condition constant text := $condition$
        and (
          not coalesce(lead_row.property_roulette_queue_lead, false)
          or lead_row.property_roulette_excluded_capturer_id is null
          or queue.broker_id <> lead_row.property_roulette_excluded_capturer_id
        )$condition$;
  eligible_fallback_condition constant text := $replacement$
        and (
          not coalesce(lead_row.property_roulette_queue_lead, false)
          or lead_row.property_roulette_excluded_capturer_id is null
          or queue.broker_id <> lead_row.property_roulette_excluded_capturer_id
          or not exists (
            select 1
            from public.crm_property_broker_access alternate_access
            join public.lead_distribution_queue alternate_queue
              on alternate_queue.broker_id=alternate_access.broker_id
             and alternate_queue.lead_type=lead_row.lead_type
            join public.profiles alternate_profile
              on alternate_profile.id=alternate_access.broker_id
            where alternate_access.property_id=lead_row.property_catalog_id
              and alternate_access.broker_id <> lead_row.property_roulette_excluded_capturer_id
              and alternate_profile.role='broker'
              and not coalesce(alternate_profile.lead_distribution_blocked,false)
              and (
                alternate_profile.lead_distribution_blocked_until is null
                or alternate_profile.lead_distribution_blocked_until <= now()
              )
          )
        )$replacement$;
begin
  select pg_get_functiondef('public.process_expired_lead_assignments_before_integrity()'::regprocedure)
    into definition;

  if position(excluded_captador_condition in definition)=0 then
    raise exception 'Unexpected lead queue timeout definition';
  end if;

  definition:=replace(definition,excluded_captador_condition,eligible_fallback_condition);
  execute definition;
end;
$$;

revoke all on function public.process_expired_lead_assignments() from public,anon,authenticated;
grant execute on function public.process_expired_lead_assignments() to service_role;

commit;

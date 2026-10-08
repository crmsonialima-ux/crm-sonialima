begin;

-- The manual restart ranked compatible brokers first but still allowed an
-- unrelated queue member when the capturer was the only property broker.
-- Property access is mandatory; capturer exclusion remains only a preference.
do $$
declare definition text;
begin
  select pg_get_functiondef('public.restart_exhausted_lead_queue(uuid)'::regprocedure)
  into definition;

  if position(
    'and not coalesce(profile.lead_distribution_manually_disabled, false)'
    in definition
  ) = 0 or position('lead_record.property_catalog_id is null' in definition) = 0 then
    raise exception 'Unexpected manual lead redistribution definition';
  end if;

  definition := replace(
    definition,
    'and not coalesce(profile.lead_distribution_manually_disabled, false)',
    $access$and not coalesce(profile.lead_distribution_manually_disabled, false)
    and (
      lead_record.property_catalog_id is null
      or exists (
        select 1 from public.crm_property_broker_access as property_access
        where property_access.property_id = lead_record.property_catalog_id
          and property_access.broker_id = queue.broker_id
      )
    )$access$
  );
  execute definition;
end $$;

commit;

begin;

do $$
declare definition text;
begin
  select pg_get_functiondef('public.create_distributed_lead(text,text,text,text,text,text,text,text,text,numeric,text)'::regprocedure) into definition;
  if position('and not coalesce(profile.lead_distribution_blocked, false)' in definition)=0 then raise exception 'Filtro da criacao nao encontrado.'; end if;
  definition:=replace(definition,
    'and not coalesce(profile.lead_distribution_blocked, false)',
    'and not coalesce(profile.lead_distribution_blocked, false)
    and (lower(trim(profile.email)) <> ''unassigned-institutional@example.invalid''
      or (selected_property_id is not null and exists (
        select 1 from public.crm_property_broker_access sonialima_access
        where sonialima_access.property_id = selected_property_id
          and sonialima_access.broker_id = queue.broker_id)))');
  execute definition;

  select pg_get_functiondef('public.process_expired_lead_assignments()'::regprocedure) into definition;
  if position('and not coalesce(profile.lead_distribution_blocked, false)' in definition)=0 then raise exception 'Filtro do processamento nao encontrado.'; end if;
  definition:=replace(definition,
    'and not coalesce(profile.lead_distribution_blocked, false)',
    'and not coalesce(profile.lead_distribution_blocked, false)
    and (lower(trim(profile.email)) <> ''unassigned-institutional@example.invalid''
      or (lead_row.property_catalog_id is not null and exists (
        select 1 from public.crm_property_broker_access sonialima_access
        where sonialima_access.property_id = lead_row.property_catalog_id
          and sonialima_access.broker_id = queue.broker_id)))');
  execute definition;

  select pg_get_functiondef('public.restart_exhausted_lead_queue(uuid)'::regprocedure) into definition;
  if position('and not coalesce(profile.lead_distribution_blocked, false)' in definition)=0 then raise exception 'Filtro do reinicio nao encontrado.'; end if;
  definition:=replace(definition,
    'and not coalesce(profile.lead_distribution_blocked, false)',
    'and not coalesce(profile.lead_distribution_blocked, false)
    and (lower(trim(profile.email)) <> ''unassigned-institutional@example.invalid''
      or (lead_record.property_catalog_id is not null and exists (
        select 1 from public.crm_property_broker_access sonialima_access
        where sonialima_access.property_id = lead_record.property_catalog_id
          and sonialima_access.broker_id = queue.broker_id)))');
  execute definition;
end $$;

commit;

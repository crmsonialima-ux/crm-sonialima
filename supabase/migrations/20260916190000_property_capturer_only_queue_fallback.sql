begin;

-- Preserve the existing two-to-one property roulette when another broker can
-- receive the lead. If the capturer is the only eligible property broker, the
-- queue turn must return the lead to that capturer instead of rejecting it.
do $$
declare definition text;
begin
  select pg_get_functiondef(
    'public.get_next_property_lead_broker(text,text)'::regprocedure
  ) into definition;

  if position(
    'raise exception ''Nao ha outro corretor elegivel na esteira deste imovel alem do captador.'';'
    in definition
  ) = 0 then
    raise exception 'Unexpected property lead roulette definition';
  end if;

  definition := replace(
    definition,
    'raise exception ''Nao ha outro corretor elegivel na esteira deste imovel alem do captador.'';',
    $fallback$
      select profile.id, profile.full_name, profile.email
      into selected_broker_id, selected_full_name, selected_email
      from public.profiles profile
      where profile.id = primary_capturer_id;

      update public.crm_property_lead_roulette
      set captador_round = true,
          captador_leads_delivered = 1,
          queue_leads_delivered = 0,
          updated_at = now()
      where property_id = normalized_property_id;

      return query
      select selected_broker_id, selected_full_name, selected_email;
      return;
    $fallback$
  );
  execute definition;
end $$;

commit;

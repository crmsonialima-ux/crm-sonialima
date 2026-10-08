begin;

-- Os imoveis similares continuam sendo avisados imediatamente quando
-- encontrados. Enquanto a oferta estiver pendente, o corretor recebe somente
-- um lembrete diario, na faixa das 09h, de segunda-feira a sabado.
create or replace function public.process_property_match_opportunities()
returns integer
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  item record;
  local_now timestamp:=now() at time zone 'America/Sao_Paulo';
  processed integer:=0;
begin
  for item in
    select
      m.lead_id,
      l.owner_id,
      l.name,
      min(m.expires_at) as expires_at,
      count(*)::integer as match_count,
      coalesce(bool_or(m.morning_reminder_on=local_now::date),false) as reminder_sent,
      jsonb_agg(m.property_external_id order by m.created_at) as property_ids
    from public.crm_property_match_notifications m
    join public.crm_leads l on l.id=m.lead_id
    where m.offer_started_at is null
      and m.expired_at is null
    group by m.lead_id,l.owner_id,l.name
  loop
    if item.expires_at<=now() then
      update public.crm_property_match_notifications
      set expired_at=now()
      where lead_id=item.lead_id
        and offer_started_at is null
        and expired_at is null;

      perform public.crm_restart_match_lead_queue(item.lead_id);
      processed:=processed+1;
    elsif extract(isodow from local_now)::integer<=6
      and local_now::time>=time '09:00'
      and local_now::time<time '10:00'
      and not item.reminder_sent then
      insert into public.crm_notification_outbox(
        recipient_id,kind,title,body,url,payload
      ) values(
        item.owner_id,
        'property_match_reminder',
        'Imovel similar aguardando oferta',
        case when item.match_count=1
          then 'Existe 1 imovel similar aguardando uma nova oferta para o lead '||item.name||'.'
          else 'Existem '||item.match_count||' imoveis similares aguardando uma nova oferta para o lead '||item.name||'.'
        end,
        '/leads?focusLeadId='||item.lead_id,
        jsonb_build_object(
          'leadId',item.lead_id,
          'propertyIds',item.property_ids,
          'expiresAt',item.expires_at
        )
      );

      update public.crm_property_match_notifications
      set morning_reminder_on=local_now::date
      where lead_id=item.lead_id
        and offer_started_at is null
        and expired_at is null;
      processed:=processed+1;
    end if;
  end loop;

  return processed;
end;
$$;

revoke all on function public.process_property_match_opportunities()
  from public,anon,authenticated;
grant execute on function public.process_property_match_opportunities()
  to service_role;

comment on function public.process_property_match_opportunities() is
  'Expira oportunidades e envia um unico lembrete de imovel similar as 09h, de segunda a sabado.';

commit;

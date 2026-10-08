-- Replace the former administrator name only in human-readable CRM content.
do $$
declare definition text;
        function_id oid;
begin
  update public.profiles set full_name='Administrador'
  where lower(trim(email))='crmsoniaallyson@gmail.com';
  update public.crm_leads set stage=replace(stage,'Allyson','Administrador') where stage like '%Allyson%';
  update public.crm_lead_activities set stage=replace(stage,'Allyson','Administrador'), note=replace(note,'Allyson','Administrador'), author_name=replace(author_name,'Allyson','Administrador')
  where stage like '%Allyson%' or note like '%Allyson%' or author_name like '%Allyson%';
  update public.crm_notification_outbox set title=replace(title,'Allyson','Administrador'), body=replace(body,'Allyson','Administrador'), payload=replace(payload::text,'Allyson','Administrador')::jsonb
  where title like '%Allyson%' or body like '%Allyson%' or payload::text like '%Allyson%';
  update public.crm_agenda_entries set observation=replace(observation,'Allyson','Administrador') where observation like '%Allyson%';
  update public.profiles set lead_distribution_blocked_reason=replace(lead_distribution_blocked_reason,'Allyson','Administrador') where lead_distribution_blocked_reason like '%Allyson%';

  for function_id in
    select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.prokind='f' and pg_get_functiondef(p.oid) like '%Allyson%'
  loop
    select replace(pg_get_functiondef(function_id),'Allyson','Administrador') into definition;
    execute definition;
  end loop;
end;
$$;



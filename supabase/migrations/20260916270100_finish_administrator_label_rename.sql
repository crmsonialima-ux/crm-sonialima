-- Finish replacing the prior administrator name in existing human-readable records.
-- The activity table prevents normal edits, so its user triggers are disabled only for this migration.
alter table public.crm_lead_activities disable trigger user;

do $$
begin
  update public.profiles
  set full_name = 'Administrador'
  where lower(trim(email)) = 'crmsoniaallyson@gmail.com';

  update public.crm_leads
  set stage = regexp_replace(stage, 'allyson', 'Administrador', 'gi')
  where stage ilike '%allyson%';

  update public.crm_lead_activities
  set
    stage = regexp_replace(stage, 'allyson', 'Administrador', 'gi'),
    note = regexp_replace(note, 'allyson', 'Administrador', 'gi'),
    author_name = case
      when lower(trim(author_name)) in ('allyson', 'crmallyson') then 'Administrador'
      when lower(trim(author_name)) = 'sistema (allyson)' then 'Sistema (Administrador)'
      else regexp_replace(author_name, 'allyson', 'Administrador', 'gi')
    end
  where coalesce(stage, '') ilike '%allyson%'
     or coalesce(note, '') ilike '%allyson%'
     or coalesce(author_name, '') ilike '%allyson%';

  update public.crm_notification_outbox
  set
    title = regexp_replace(title, 'allyson', 'Administrador', 'gi'),
    body = regexp_replace(body, 'allyson', 'Administrador', 'gi')
  where coalesce(title, '') ilike '%allyson%'
     or coalesce(body, '') ilike '%allyson%';

  update public.crm_agenda_entries
  set observation = regexp_replace(observation, 'allyson', 'Administrador', 'gi')
  where coalesce(observation, '') ilike '%allyson%';

  update public.profiles
  set lead_distribution_blocked_reason = regexp_replace(lead_distribution_blocked_reason, 'allyson', 'Administrador', 'gi')
  where coalesce(lead_distribution_blocked_reason, '') ilike '%allyson%';
end;
$$;

alter table public.crm_lead_activities enable trigger user;
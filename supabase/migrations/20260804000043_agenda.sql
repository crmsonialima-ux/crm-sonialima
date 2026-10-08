create type public.agenda_category as enum ('neo_energia','caesb','cartorio','observacao');
create table public.crm_agenda_entries (
 id uuid primary key default gen_random_uuid(), category public.agenda_category not null,
 scheduled_at timestamptz not null, observation text not null, target_user_id uuid not null references public.profiles(id),
 created_by uuid not null references public.profiles(id), feedback_at timestamptz, feedback_note text,
 feedback_by uuid references public.profiles(id), reminder_sent_at timestamptz, vitor_notified_at timestamptz,
 admin_notified_at timestamptz, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
alter table public.crm_agenda_entries enable row level security;
grant select on public.crm_agenda_entries to authenticated;
create policy "Everyone reads agenda" on public.crm_agenda_entries for select using (auth.uid() is not null);

create or replace function public.create_agenda_entry(p_category public.agenda_category,p_scheduled_at timestamptz,p_observation text,p_target_user_id uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare derley uuid; entry_id uuid;
begin
 select id into derley from profiles where lower(email)='unassigned-agenda@example.invalid' limit 1;
 if auth.uid() is null then raise exception 'Sessão não encontrada.'; end if;
 if not public.is_admin() and p_target_user_id <> auth.uid() and p_target_user_id <> derley then raise exception 'Você só pode adicionar compromissos para si ou para Derley.'; end if;
 if p_scheduled_at is null or nullif(trim(p_observation),'') is null then raise exception 'Informe data, hora e observação.'; end if;
 insert into crm_agenda_entries(category,scheduled_at,observation,target_user_id,created_by) values(p_category,p_scheduled_at,trim(p_observation),p_target_user_id,auth.uid()) returning id into entry_id;
 return entry_id;
end; $$;
create or replace function public.feedback_agenda_entry(p_id uuid,p_feedback_at timestamptz,p_note text)
returns void language plpgsql security definer set search_path=public as $$
declare derley uuid; vitor uuid;
begin
 select id into derley from profiles where lower(email)='unassigned-agenda@example.invalid' limit 1;
 select id into vitor from profiles where lower(email)='unassigned-operator@example.invalid' limit 1;
 if auth.uid() not in (derley,vitor) and not public.is_admin() then raise exception 'Somente Derley, Vitor ou admin podem registrar retorno.'; end if;
 update crm_agenda_entries set feedback_at=coalesce(p_feedback_at,now()),feedback_note=nullif(trim(p_note),''),feedback_by=auth.uid(),updated_at=now() where id=p_id;
end; $$;
create or replace function public.delete_agenda_entry(p_id uuid) returns void language plpgsql security definer set search_path=public as $$
begin if not public.is_admin() then raise exception 'Somente admin pode excluir.'; end if; delete from crm_agenda_entries where id=p_id; end; $$;
create or replace function public.process_agenda_notifications() returns void language plpgsql security definer set search_path=public as $$
declare e record; derley uuid; vitor uuid;
begin
 select id into derley from profiles where lower(email)='unassigned-agenda@example.invalid' limit 1;
 select id into vitor from profiles where lower(email)='unassigned-operator@example.invalid' limit 1;
 for e in select * from crm_agenda_entries where reminder_sent_at is null and scheduled_at between now() and now()+interval '30 minutes' loop
   insert into crm_notification_outbox(recipient_id,kind,title,body,url,payload) values(e.target_user_id,'agenda_reminder','Compromisso em 30 minutos',e.observation,'/agenda',jsonb_build_object('agendaId',e.id)); update crm_agenda_entries set reminder_sent_at=now() where id=e.id;
 end loop;
 for e in select * from crm_agenda_entries where category in ('neo_energia','caesb') and target_user_id=derley and feedback_at is null and scheduled_at+interval '3 hours'<=now() and vitor_notified_at is null loop
   if vitor is not null then insert into crm_notification_outbox(recipient_id,kind,title,body,url,payload) values(vitor,'agenda_escalation','Demanda sem retorno de Derley',e.observation,'/agenda',jsonb_build_object('agendaId',e.id)); end if; update crm_agenda_entries set vitor_notified_at=now() where id=e.id;
 end loop;
 for e in select * from crm_agenda_entries where category in ('neo_energia','caesb') and target_user_id=derley and feedback_at is null and scheduled_at+interval '5 hours'<=now() and admin_notified_at is null loop
   insert into crm_notification_outbox(recipient_id,kind,title,body,url,payload) select id,'agenda_escalation','Demanda sem retorno','Derley e Vitor ainda não registraram retorno: '||e.observation,'/agenda',jsonb_build_object('agendaId',e.id) from profiles where role='admin'; update crm_agenda_entries set admin_notified_at=now() where id=e.id;
 end loop;
end; $$;
grant execute on function public.create_agenda_entry(public.agenda_category,timestamptz,text,uuid), public.feedback_agenda_entry(uuid,timestamptz,text), public.delete_agenda_entry(uuid), public.process_agenda_notifications() to authenticated;
